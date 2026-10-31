/*
** capifuzz: a C module for the C-API fuzzers (test/fuzz/README.md).
**
** `run(ops)` interprets OPS, four bytes per operation (code, a, b, c),
** on eight registers that live as long as the module. Each operation
** makes one or a few C-API calls, in a protected call of its own, and
** notes what they returned; `run` returns the notes, one per line. An
** operation that raises notes the error and the next one runs. Running
** out of memory ends `run` with the error, so the allocation-failure
** sweep sees it. Every operation keeps to the manual's rules, so any
** byte string is a valid program, and the notes print no addresses.
*/

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#define REG lua_upvalueindex(1)
#define OUT lua_upvalueindex(2)
#define NREG 8
#define N(a) ((int)(sizeof(a) / sizeof((a)[0])))

static const lua_Integer ints[] = {0, 1, -1, 2, 42, LUA_MAXINTEGER, LUA_MININTEGER, 3, -7, 1000};
static const lua_Number floats[] = {0.5, -0.0, 1e308, 2.0, -3.25, 1e-310, 3.0, 1.0 / 3.0};
static const struct {
  const char *s;
  size_t len;
} strs[] = {
    {"", 0},     {"10", 2},     {"0x10", 4}, {" 3.5 ", 5}, {"abc", 3},   {"a\0b", 3},
    {"1e2", 3},  {"hello world", 11}, {"%d%s", 4}, {"-0", 2}, {"9223372036854775808", 19}, {"__index", 7},
};
static const char *const snippets[] = {
    "return ...",
    "error('boom')",
    "local a, b = ... return a + b",
    "return setmetatable({}, {__index = function(t, k) return k end, __add = function() return 'added' end,"
    " __len = function() return 7 end, __concat = function() return 'cat' end, __eq = function() return true end,"
    " __lt = function() return true end, __le = function() return false end, __call = function(self, x) return x end,"
    " __close = function() end, __name = 'Obj', __tostring = function() return 'obj!' end, __unm = function() return 'neg' end})",
    "local t = ... return #t, t[1]",
    "local r = coroutine.yield(...) return 'done', r",
    "error(setmetatable({}, {__tostring = function() return 'custom' end}))",
    "return tostring(...)",
    "error()",
    "local x = ... x.y = 1 return x",
    "return string.rep('ab', 3, ',')",
    "local function f(n) if n <= 0 then error('deep', 2) end return 1 + f(n - 1) end return f(...)",
};

/* Pushes OUT's next line: the formatted note, with long hex runs (an
** address in a message) masked. */
static void note(lua_State *L, int out, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  const char *s = lua_pushvfstring(L, fmt, ap);
  va_end(ap);
  const char *x = strstr(s, "0x");
  if (x != NULL && strspn(x + 2, "0123456789abcdef") >= 8) {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    while ((x = strstr(s, "0x")) != NULL) {
      size_t n = strspn(x + 2, "0123456789abcdef");
      luaL_addlstring(&b, s, (size_t)(x - s));
      if (n >= 8) luaL_addstring(&b, "ADDR");
      else luaL_addlstring(&b, x, n + 2);
      s = x + 2 + n;
    }
    luaL_addstring(&b, s);
    luaL_pushresult(&b);
    lua_remove(L, -2);
  }
  lua_rawseti(L, out, (lua_Integer)lua_rawlen(L, out) + 1);
}

/* Pushes a description of the value at IDX. */
static const char *describe(lua_State *L, int idx) {
  idx = lua_absindex(L, idx);
  switch (lua_type(L, idx)) {
    case LUA_TNIL: return lua_pushliteral(L, "nil");
    case LUA_TBOOLEAN: return lua_pushstring(L, lua_toboolean(L, idx) ? "true" : "false");
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) return lua_pushfstring(L, "i:%I", (LUAI_UACINT)lua_tointeger(L, idx));
      lua_pushvalue(L, idx);
      lua_pushfstring(L, "f:%s", lua_tostring(L, -1));
      lua_remove(L, -2);
      return lua_tostring(L, -1);
    case LUA_TSTRING: {
      size_t len, i;
      const char *s = lua_tolstring(L, idx, &len);
      luaL_Buffer b;
      luaL_buffinit(L, &b);
      luaL_addstring(&b, "s:");
      for (i = 0; i < len && i < 48; i++) {
        unsigned char c = (unsigned char)s[i];
        size_t hex = 0;
        if (c == '0' && i + 1 < len && s[i + 1] == 'x')  /* an address, as tostring gives one */
          while (i + 2 + hex < len && strchr("0123456789abcdef", s[i + 2 + hex]) && s[i + 2 + hex]) hex++;
        if (hex >= 6) {
          luaL_addstring(&b, "ADDR");
          i += 1 + hex;
        } else if (c >= 32 && c < 127 && c != '\\') luaL_addchar(&b, (char)c);
        else {
          char esc[8];
          snprintf(esc, sizeof esc, "\\%d", c);
          luaL_addstring(&b, esc);
        }
      }
      if (len > 48) luaL_addstring(&b, "...");
      luaL_pushresult(&b);
      return lua_tostring(L, -1);
    }
    case LUA_TTABLE: {
      int mt = lua_getmetatable(L, idx);
      if (mt) lua_pop(L, 1);
      return lua_pushfstring(L, "table#%d%s", (int)lua_rawlen(L, idx), mt ? "+mt" : "");
    }
    case LUA_TFUNCTION: return lua_pushstring(L, lua_iscfunction(L, idx) ? "cfunction" : "function");
    case LUA_TLIGHTUSERDATA: return lua_pushliteral(L, "light");
    case LUA_TUSERDATA: return lua_pushfstring(L, "userdata#%d", (int)lua_rawlen(L, idx));
    default: return lua_pushliteral(L, "thread");
  }
}

static void getreg(lua_State *L, int i) { lua_rawgeti(L, REG, i % NREG + 1); }

/* Pops the top into register I. */
static void setreg(lua_State *L, int i) { lua_rawseti(L, REG, i % NREG + 1); }

/* Notes WHAT and the value on top, which stays. */
static void noteval(lua_State *L, const char *what) {
  describe(L, -1);
  note(L, OUT, "%s %s", what, lua_tostring(L, -1));
  lua_pop(L, 1);
}

static int cfun_k(lua_State *L, int status, lua_KContext ctx) {
  lua_pushinteger(L, (lua_Integer)ctx + status);
  lua_pushvalue(L, lua_upvalueindex(2));
  return 3;
}

/* A C closure: counts its calls in upvalue 2, and calls its first
** argument, when a function, with upvalue 1, through lua_callk. */
static int cfun(lua_State *L) {
  lua_pushinteger(L, lua_tointeger(L, lua_upvalueindex(2)) + 1);
  lua_replace(L, lua_upvalueindex(2));
  if (lua_type(L, 1) == LUA_TFUNCTION) {
    lua_pushvalue(L, 1);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_callk(L, 1, 1, 7, cfun_k);
    return cfun_k(L, LUA_OK, 7);
  }
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_pushvalue(L, lua_upvalueindex(2));
  lua_pushinteger(L, lua_gettop(L) - 2);
  return 3;
}

static const char *const options[] = {"one", "two", NULL};

/* Argument checks on its first argument, by its upvalue. */
static int checker(lua_State *L) {
  switch (lua_tointeger(L, lua_upvalueindex(1)) % 8) {
    case 0: lua_pushinteger(L, luaL_checkinteger(L, 1)); break;
    case 1: lua_pushnumber(L, luaL_checknumber(L, 1)); break;
    case 2: {
      size_t len;
      luaL_checklstring(L, 1, &len);
      lua_pushinteger(L, (lua_Integer)len);
      break;
    }
    case 3: lua_pushinteger(L, luaL_optinteger(L, 1, 9)); break;
    case 4: lua_pushinteger(L, luaL_checkoption(L, 1, NULL, options)); break;
    case 5: luaL_checktype(L, 1, LUA_TTABLE); lua_pushboolean(L, 1); break;
    case 6: luaL_checkany(L, 1); lua_pushboolean(L, 1); break;
    default: luaL_argexpected(L, lua_isnoneornil(L, 1), 1, "nil"); lua_pushboolean(L, 1); break;
  }
  return 1;
}

static int cclose(lua_State *L) {
  describe(L, 2);
  note(L, lua_upvalueindex(1), "closed %s", lua_tostring(L, -1));
  return 0;
}

/* Marks its argument to be closed, then errors or closes the slot or
** returns, by its upvalue. */
static int closer(lua_State *L) {
  int how = (int)lua_tointeger(L, lua_upvalueindex(1)) % 4;
  lua_settop(L, 1);
  lua_toclose(L, 1);
  if (how == 1) return luaL_error(L, "after %s", "toclose");
  if (how == 2) lua_closeslot(L, 1);
  if (how == 3) lua_settop(L, 0);
  lua_pushinteger(L, how);
  return 1;
}

static int raiser(lua_State *L) {
  lua_settop(L, 1);
  if (lua_toboolean(L, lua_upvalueindex(1))) return luaL_error(L, "%s:%d", "raised", 5);
  return lua_error(L);
}

static void pushcfn(lua_State *L, lua_CFunction f, int up) {
  lua_pushinteger(L, up);
  if (f == cclose) lua_pushvalue(L, OUT);
  lua_pushcclosure(L, f, 1);
  if (f == cclose) lua_remove(L, -2);
}

/* Moves the results of a resume or a call, NRES values on CO's top, to
** registers from A, noting them; rethrows a memory error. */
static void results(lua_State *L, lua_State *co, int status, int nres, int a) {
  int i;
  note(L, OUT, "status %d nres %d", status, nres);
  if (status == LUA_ERRMEM) {
    lua_xmove(co, L, 1);
    lua_error(L);
  }
  luaL_checkstack(L, nres + 2, NULL);
  lua_xmove(co, L, nres);
  for (i = 0; i < nres; i++) {
    lua_pushvalue(L, -nres + i);
    noteval(L, "  r");
    if (i < 3) setreg(L, a + i);
    else lua_pop(L, 1);
  }
  lua_pop(L, nres);
}

static int doop(lua_State *L) {
  int op = (int)lua_tointeger(L, 1), a = (int)lua_tointeger(L, 2);
  int b = (int)lua_tointeger(L, 3), c = (int)lua_tointeger(L, 4);
  lua_settop(L, 0);
  luaL_checkstack(L, 24, NULL);
  switch (op % 44) {
    case 0: lua_pushinteger(L, ints[b % N(ints)]); setreg(L, a); break;
    case 1: lua_pushnumber(L, floats[b % N(floats)]); setreg(L, a); break;
    case 2: lua_pushlstring(L, strs[b % N(strs)].s, strs[b % N(strs)].len); setreg(L, a); break;
    case 3:
      if (b % 3 == 0) lua_pushnil(L);
      else lua_pushboolean(L, b % 3 == 1);
      setreg(L, a);
      break;
    case 4: lua_createtable(L, b % 4, c % 4); setreg(L, a); break;
    case 5:
      getreg(L, a), getreg(L, b), getreg(L, c);
      lua_settable(L, 1);
      break;
    case 6:
      getreg(L, a), getreg(L, b);
      note(L, OUT, "gettable %d", lua_gettable(L, 1));
      noteval(L, " =");
      setreg(L, c);
      break;
    case 7:
      getreg(L, a), getreg(L, c);
      lua_setfield(L, 1, strs[b % N(strs)].s);
      break;
    case 8:
      getreg(L, a);
      note(L, OUT, "getfield %d", lua_getfield(L, 1, strs[b % N(strs)].s));
      noteval(L, " =");
      setreg(L, c);
      break;
    case 9:
      getreg(L, a);
      if (!lua_istable(L, 1)) break;
      getreg(L, b);
      if (c % 2) {
        getreg(L, c);
        lua_rawset(L, 1);
      } else {
        note(L, OUT, "rawget %d", lua_rawget(L, 1));
        noteval(L, " =");
      }
      break;
    case 10:
      getreg(L, a);
      if (!lua_istable(L, 1)) break;
      if (c % 2) {
        getreg(L, c);
        lua_rawseti(L, 1, ints[b % N(ints)]);
      } else {
        note(L, OUT, "rawgeti %d", lua_rawgeti(L, 1, ints[b % N(ints)]));
        noteval(L, " =");
      }
      break;
    case 11:
      getreg(L, a);
      if (c % 2) {
        getreg(L, c);
        lua_seti(L, 1, ints[b % N(ints)]);
      } else {
        note(L, OUT, "geti %d", lua_geti(L, 1, ints[b % N(ints)]));
        noteval(L, " =");
      }
      break;
    case 12: {
      int o = c % 14;
      getreg(L, a);
      if (o != LUA_OPUNM && o != LUA_OPBNOT) getreg(L, b);
      lua_arith(L, o);
      note(L, OUT, "arith %d", o);
      noteval(L, " =");
      setreg(L, a);
      break;
    }
    case 13:
      getreg(L, a), getreg(L, b);
      note(L, OUT, "compare %d %d raw %d", c % 3, lua_compare(L, 1, 2, c % 3), lua_rawequal(L, 1, 2));
      break;
    case 14: {
      int n = c % 4;
      if (n > 0) getreg(L, a);
      if (n > 1) getreg(L, b);
      if (n > 2) getreg(L, a);
      if (lua_rawlen(L, 1) > 1000 || (n > 1 && lua_rawlen(L, 2) > 1000)) break;  /* no doubling forever */
      lua_concat(L, n);
      noteval(L, "concat");
      setreg(L, a);
      break;
    }
    case 15:
      getreg(L, a);
      note(L, OUT, "rawlen %d", (int)lua_rawlen(L, 1));
      lua_len(L, 1);
      noteval(L, "len");
      setreg(L, b);
      break;
    case 16: {
      int isnum, isint;
      lua_Number n;
      lua_Integer i;
      getreg(L, a);
      n = lua_tonumberx(L, 1, &isnum);
      i = lua_tointegerx(L, 1, &isint);
      note(L, OUT, "tonumber %d %f tointeger %d %I bool %d isint %d isnum %d isstr %d iscf %d isud %d type %s", isnum, n,
           isint, (LUAI_UACINT)i, lua_toboolean(L, 1), lua_isinteger(L, 1), lua_isnumber(L, 1), lua_isstring(L, 1),
           lua_iscfunction(L, 1), lua_isuserdata(L, 1), luaL_typename(L, 1));
      if (lua_type(L, 1) == LUA_TNUMBER) {
        lua_pushvalue(L, 1);
        note(L, OUT, "tolstring %s", lua_tostring(L, -1));
      }
      break;
    }
    case 17: {
      size_t r = lua_stringtonumber(L, strs[b % N(strs)].s);
      note(L, OUT, "stringtonumber %d", (int)r);
      if (r) noteval(L, " =");
      break;
    }
    case 18: {
      int status, base;
      getreg(L, b), getreg(L, c);
      base = lua_gettop(L) - 2;
      status = lua_pcall(L, 1, LUA_MULTRET, 0);
      results(L, L, status, lua_gettop(L) - base, a);
      break;
    }
    case 19: {
      const char *s = snippets[b % N(snippets)];
      int status = luaL_loadbufferx(L, s, strlen(s), "=snip", c % 2 ? "t" : "bt");
      note(L, OUT, "load %d", status);
      if (status == LUA_ERRMEM) lua_error(L);
      setreg(L, a);
      break;
    }
    case 20: {
      int nuv = b % 3;
      lua_newuserdatauv(L, c % 16, nuv);
      getreg(L, b);
      note(L, OUT, "setiuservalue %d", lua_setiuservalue(L, 1, 1));
      setreg(L, a);
      break;
    }
    case 21:
      getreg(L, a);
      if (lua_type(L, 1) != LUA_TUSERDATA) break;
      note(L, OUT, "getiuservalue %d", lua_getiuservalue(L, 1, b % 3));
      noteval(L, " =");
      setreg(L, c);
      break;
    case 22:
      getreg(L, a), getreg(L, b);
      /* Only on tables and userdata: a type's metatable would change
      ** how the harness prints. */
      if (!lua_istable(L, 1) && lua_type(L, 1) != LUA_TUSERDATA) break;
      if (!lua_istable(L, 2) && !lua_isnil(L, 2)) break;
      lua_setmetatable(L, 1);
      break;
    case 23:
      getreg(L, a);
      if (lua_getmetatable(L, 1)) noteval(L, "getmetatable");
      else lua_pushliteral(L, "none");
      setreg(L, b);
      break;
    case 24: {
      lua_State *co = lua_newthread(L);
      int nres = 0, status;
      getreg(L, b), getreg(L, c);
      lua_xmove(L, co, 2);
      status = lua_resume(co, L, 1, &nres);
      lua_pushvalue(L, 1);
      setreg(L, a);
      results(L, co, status, status <= LUA_YIELD ? nres : 1, a + 1);
      break;
    }
    case 25: {
      lua_State *co;
      int nres = 0, status;
      getreg(L, a);
      if (!lua_isthread(L, 1)) break;
      co = lua_tothread(L, 1);
      /* A thread an error killed keeps the stack below the error
      ** object, which differs (docs/slop/c-api.md); compare the top only
      ** while suspended. */
      note(L, OUT, "thread status %d top %d", lua_status(co), lua_status(co) == LUA_YIELD ? lua_gettop(co) : -1);
      if (lua_status(co) == LUA_YIELD) lua_pop(co, lua_gettop(co));
      else if (lua_status(co) == LUA_OK && lua_gettop(co) > 0) break;  /* a running thread */
      if (!lua_checkstack(co, 2)) break;
      getreg(L, b);
      lua_xmove(L, co, 1);
      status = lua_resume(co, L, 1, &nres);
      results(L, co, status, status <= LUA_YIELD ? nres : 1, a + 1);
      break;
    }
    case 26:
      getreg(L, b), getreg(L, c);
      lua_pushcclosure(L, cfun, 2);
      setreg(L, a);
      break;
    case 27: {
      luaL_Buffer buf;
      int i;
      getreg(L, a), getreg(L, b);
      if (lua_rawlen(L, 1) > 1000 || lua_rawlen(L, 2) > 1000) break;
      luaL_buffinit(L, &buf);
      for (i = 1; i <= 2; i++) {
        if (lua_type(L, i) == LUA_TSTRING || lua_type(L, i) == LUA_TNUMBER) {
          luaL_tolstring(L, i, NULL);
          luaL_addvalue(&buf);
        } else luaL_addstring(&buf, luaL_typename(L, i));
        luaL_addchar(&buf, '|');
      }
      luaL_addgsub(&buf, "abcabc", "b", "XY");
      luaL_buffsub(&buf, 1);
      if (c % 2) {
        size_t n = 100 + (size_t)c * 37;
        memset(luaL_prepbuffsize(&buf, n), 'z', n);
        luaL_addsize(&buf, n);
      }
      note(L, OUT, "bufflen %d", (int)luaL_bufflen(&buf));
      luaL_pushresult(&buf);
      noteval(L, "buffer");
      setreg(L, a);
      break;
    }
    case 28:
      if (strs[c % N(strs)].s[0] == '\0') break;  /* an empty pattern loops forever */
      luaL_gsub(L, strs[b % N(strs)].s, strs[c % N(strs)].s, "<>");
      noteval(L, "gsub");
      break;
    case 29: {
      int n = 0;
      getreg(L, a);
      if (!lua_istable(L, 1)) break;
      lua_pushnil(L);
      while (lua_next(L, 1)) {
        n++;
        lua_pop(L, 1);
      }
      note(L, OUT, "pairs %d", n);
      break;
    }
    case 30: {
      int r;
      getreg(L, a);
      r = luaL_ref(L, LUA_REGISTRYINDEX);
      note(L, OUT, "ref nil %d", r == LUA_REFNIL);
      if (r != LUA_REFNIL) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, r);
        getreg(L, a);
        note(L, OUT, "ref same %d", lua_rawequal(L, -1, -2));
        luaL_unref(L, LUA_REGISTRYINDEX, r);
      }
      break;
    }
    case 31: {
      int i;
      getreg(L, a), getreg(L, b), getreg(L, c);
      switch (op / 44 % 6) {
        case 0: lua_rotate(L, 1, 1); break;
        case 1: lua_rotate(L, -3, -1); break;
        case 2: lua_insert(L, 2); lua_pushnil(L); break;
        case 3: lua_copy(L, -1, 1); break;
        case 4: lua_replace(L, 1); lua_pushboolean(L, 0); break;
        default: lua_remove(L, 2); lua_pushvalue(L, -1); break;
      }
      note(L, OUT, "top %d abs %d", lua_gettop(L), lua_absindex(L, -2));
      for (i = 2; i >= 0; i--) setreg(L, i == 0 ? a : i == 1 ? b : c);
      break;
    }
    case 32:
      pushcfn(L, checker, c);
      getreg(L, b);
      lua_call(L, 1, 1);
      noteval(L, "checked");
      setreg(L, a);
      break;
    case 33:
      lua_pushfstring(L, "%d|%s|%f|%c|%%|%I|%U|%p", (int)ints[b % N(ints)], strs[c % N(strs)].s,
                                 floats[b % N(floats)], 'A' + c % 26, (LUAI_UACINT)ints[c % N(ints)],
                                 (long)(c * 997 + b), (void *)NULL);
      noteval(L, "fstring");
      break;
    case 34:
      pushcfn(L, closer, c);
      getreg(L, b);
      lua_call(L, 1, 1);
      noteval(L, "closer");
      break;
    case 35:
      lua_newtable(L);
      lua_createtable(L, 0, 2);
      pushcfn(L, cclose, 0);
      lua_setfield(L, -2, "__close");
      lua_pushliteral(L, "Closer");
      lua_setfield(L, -2, "__name");
      lua_setmetatable(L, -2);
      setreg(L, a);
      break;
    case 36:
      pushcfn(L, raiser, c % 2);
      getreg(L, b);
      lua_call(L, 1, 0);
      break;
    case 37:
      lua_gc(L, b % 2 ? LUA_GCCOLLECT : LUA_GCSTEP, 0);
      note(L, OUT, "gc running %d", lua_gc(L, LUA_GCISRUNNING));
      break;
    case 38: {
      int ismain = lua_pushthread(L);
      lua_State *co = lua_newthread(L);
      getreg(L, a);
      lua_xmove(L, co, 1);
      lua_xmove(co, L, 1);
      note(L, OUT, "main %d moved %s", ismain, luaL_typename(L, -1));
      break;
    }
    case 39:
      lua_pushglobaltable(L);
      getreg(L, c);
      lua_setglobal(L, strs[b % N(strs)].s);
      note(L, OUT, "getglobal %d", lua_getglobal(L, strs[b % N(strs)].s));
      setreg(L, a);
      break;
    case 40:
      getreg(L, a);
      note(L, OUT, "auxlen %I", (LUAI_UACINT)luaL_len(L, 1));
      break;
    case 41:
      getreg(L, a);
      if (lua_type(L, 1) == LUA_TTABLE || lua_type(L, 1) == LUA_TUSERDATA) break;
      luaL_tolstring(L, 1, NULL);
      noteval(L, "tolstring");
      setreg(L, b);
      break;
    case 42: {
      lua_Debug ar;
      getreg(L, a);
      if (!lua_isfunction(L, 1)) break;
      lua_pushvalue(L, 1);
      lua_getinfo(L, ">Su", &ar);
      note(L, OUT, "getinfo %s %s %d %d nups %d nparams %d vararg %d", ar.what, ar.short_src, ar.linedefined,
           ar.lastlinedefined, ar.nups, ar.nparams, ar.isvararg);
      break;
    }
    default: {
      const char *name;
      int n = b % 3 + 1;
      getreg(L, a);
      if (!lua_isfunction(L, 1)) break;
      name = lua_getupvalue(L, 1, n);
      note(L, OUT, "getupvalue %d %s", n, name ? name : "(none)");
      if (name == NULL) break;
      note(L, OUT, "upvalueid %d", lua_upvalueid(L, 1, n) != NULL);
      noteval(L, " =");
      if (c % 2) {
        getreg(L, c);
        note(L, OUT, "setupvalue %s", lua_setupvalue(L, 1, n));
      }
      break;
    }
  }
  return 0;
}

static int run(lua_State *L) {
  size_t len, i;
  int n, j;
  const char *ops = luaL_checklstring(L, 1, &len);
  luaL_Buffer b;
  for (i = 0; i + 4 <= len; i += 4) {
    int k, status;
    lua_pushvalue(L, lua_upvalueindex(1));
    for (k = 0; k < 4; k++) lua_pushinteger(L, (unsigned char)ops[i + k]);
    status = lua_pcall(L, 4, 0, 0);
    if (status == LUA_ERRMEM) return lua_error(L);
    if (status != LUA_OK) {
      describe(L, -1);
      note(L, OUT, "error %d %s", status, lua_tostring(L, -1));
      lua_pop(L, 2);
    }
  }
  n = (int)lua_rawlen(L, OUT);
  luaL_buffinit(L, &b);
  for (j = 1; j <= n; j++) {
    lua_rawgeti(L, OUT, j);
    luaL_addvalue(&b);
    if (j < n) luaL_addchar(&b, '\n');
  }
  luaL_pushresult(&b);
  for (j = 1; j <= n; j++) {
    lua_pushnil(L);
    lua_rawseti(L, OUT, j);
  }
  return 1;
}

int luaopen_capifuzz(lua_State *L) {
  lua_newtable(L);           /* the module */
  lua_createtable(L, NREG, 0);  /* registers */
  lua_newtable(L);           /* notes */
  lua_pushvalue(L, -2);
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, doop, 2);
  lua_insert(L, -2);
  lua_pushcclosure(L, run, 2);
  lua_setfield(L, -3, "run");
  lua_pop(L, 1);
  return 1;
}
