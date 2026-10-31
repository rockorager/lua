/*
** A C module that exercises the C API's error unwinding, continuations,
** and the parts of lauxlib modules lean on. test/capi/errors.lua drives
** it; `just capi-test` runs that on our C-API lua and on the reference,
** which load this same library built against include/, and compares.
*/

#include <string.h>

#include "lua.h"
#include "lauxlib.h"

/* How many times C code ran past a call that failed: must stay 0. */
static int leaked = 0;

static int t_leaked (lua_State *L) {
  lua_pushinteger(L, leaked);
  return 1;
}

/* call(f, ...): lua_call, then return every result. */
static int t_call (lua_State *L) {
  int n = lua_gettop(L);
  lua_call(L, n - 1, LUA_MULTRET);
  /* reached only when the call returned */
  lua_pushinteger(L, lua_gettop(L));
  lua_insert(L, 1);
  return lua_gettop(L);
}

/* fail_after(f, ...): lua_call, and code after it that must not run. */
static int t_fail_after (lua_State *L) {
  lua_call(L, lua_gettop(L) - 1, 0);
  leaked++;
  return 0;
}

/* pcall(f, ...): status, then results or the error object. */
static int t_pcall (lua_State *L) {
  int n = lua_gettop(L);
  int st = lua_pcall(L, n - 1, LUA_MULTRET, 0);
  lua_pushinteger(L, st);
  lua_insert(L, 1);
  return lua_gettop(L);
}

/* pcallh(h, f, ...): pcall with message handler h. */
static int t_pcallh (lua_State *L) {
  int n = lua_gettop(L);
  int st = lua_pcall(L, n - 2, LUA_MULTRET, 1);
  lua_pushinteger(L, st);
  lua_replace(L, 1);
  return lua_gettop(L);
}

static int t_error (lua_State *L) {
  lua_settop(L, 1);
  return lua_error(L);
}

static int t_lerror (lua_State *L) {
  return luaL_error(L, "boom %d %s %f %I %c%% %p", 42, luaL_optstring(L, 1, "x"),
                    2.5, (lua_Integer)-7, 'z', (void *)NULL);
}

static int t_memerr (lua_State *L) {
  lua_pushliteral(L, "not enough memory");
  return lua_error(L);
}

static int t_checkint (lua_State *L) {
  lua_pushinteger(L, luaL_checkinteger(L, 1) * 2);
  return 1;
}

static int t_checknum (lua_State *L) {
  lua_pushnumber(L, luaL_checknumber(L, 1) + luaL_optnumber(L, 2, 0.5));
  return 1;
}

static int t_checkopt (lua_State *L) {
  static const char *const opts[] = {"one", "two", NULL};
  lua_pushinteger(L, luaL_checkoption(L, 1, "two", opts));
  return 1;
}

static int t_gettable (lua_State *L) {
  lua_settop(L, 2);
  lua_gettable(L, 1);
  return 1;
}

static int t_settable (lua_State *L) {
  lua_settop(L, 3);
  lua_settable(L, 1);
  return 0;
}

static int t_arith (lua_State *L) {
  lua_settop(L, 2);
  lua_arith(L, LUA_OPADD);
  return 1;
}

static int t_unm (lua_State *L) {
  lua_settop(L, 1);
  lua_arith(L, LUA_OPUNM);
  lua_pushinteger(L, lua_gettop(L));
  return 2;
}

static int t_compare (lua_State *L) {
  lua_pushboolean(L, lua_compare(L, 1, 2, LUA_OPLT));
  return 1;
}

static int t_concat (lua_State *L) {
  lua_concat(L, lua_gettop(L));
  return 1;
}

static int t_len (lua_State *L) {
  lua_pushinteger(L, luaL_len(L, 1));
  return 1;
}

static int t_tostring (lua_State *L) {
  luaL_tolstring(L, 1, NULL);
  return 1;
}

/* A __add written in C that fails, called from Lua code. */
static int t_badadd (lua_State *L) {
  return luaL_error(L, "no adding %s", luaL_typename(L, 2));
}

/* yield(...): suspend with the arguments; resume returns its values. */
static int t_yield (lua_State *L) {
  return lua_yield(L, lua_gettop(L));
}

static int finishyield (lua_State *L, int status, lua_KContext ctx) {
  lua_pushstring(L, "k");
  lua_pushinteger(L, status);
  lua_pushinteger(L, (lua_Integer)ctx);
  lua_rotate(L, 1, 3);
  return lua_gettop(L);
}

/* yieldk(...): yield with a continuation, context 42. */
static int t_yieldk (lua_State *L) {
  return lua_yieldk(L, lua_gettop(L), 42, finishyield);
}

static int finishcall (lua_State *L, int status, lua_KContext ctx) {
  lua_pushstring(L, "callk");
  lua_pushinteger(L, status);
  lua_pushinteger(L, (lua_Integer)ctx);
  lua_rotate(L, 1, 3);
  return lua_gettop(L);
}

/* callk(f, ...): lua_callk with a continuation, context 7. */
static int t_callk (lua_State *L) {
  lua_callk(L, lua_gettop(L) - 1, LUA_MULTRET, 7, finishcall);
  return finishcall(L, LUA_OK, 7);
}

static int finishpcall (lua_State *L, int status, lua_KContext ctx) {
  lua_pushstring(L, "pcallk");
  lua_pushinteger(L, status);
  lua_pushinteger(L, (lua_Integer)ctx);
  lua_rotate(L, 1, 3);
  return lua_gettop(L);
}

/* pcallk(f, ...): lua_pcallk with a continuation, context 9. */
static int t_pcallk (lua_State *L) {
  int st = lua_pcallk(L, lua_gettop(L) - 1, LUA_MULTRET, 0, 9, finishpcall);
  return finishpcall(L, st, 9);
}

/* resume(co, ...): lua_resume from C; status, then the values. */
static int t_resume (lua_State *L) {
  lua_State *co = lua_tothread(L, 1);
  int n = lua_gettop(L) - 1;
  int nres, st;
  luaL_checkstack(co, n, "too many arguments");
  lua_xmove(L, co, n);
  st = lua_resume(co, L, n, &nres);
  lua_pushinteger(L, st);
  if (st == LUA_OK || st == LUA_YIELD) {
    luaL_checkstack(L, nres, "too many results");
    lua_xmove(co, L, nres);
    return nres + 1;
  }
  lua_xmove(co, L, 1);
  return 2;
}

/* spawn(f, ...): a new thread from C running f; status and values. */
static int t_spawn (lua_State *L) {
  int n = lua_gettop(L);
  lua_State *co = lua_newthread(L);
  int nres, st;
  lua_insert(L, 1);
  lua_xmove(L, co, n);
  st = lua_resume(co, L, n - 1, &nres);
  lua_pushinteger(L, st);
  lua_pushinteger(L, lua_status(co));
  lua_xmove(co, L, st <= LUA_YIELD ? nres : 1);
  return lua_gettop(L) - 1;
}

/* deep(n, f): C -> Lua f(n - 1) -> deep ... ; fails at the bottom. */
static int t_deep (lua_State *L) {
  lua_Integer n = luaL_checkinteger(L, 1);
  if (n == 0)
    return luaL_error(L, "bottom");
  lua_pushvalue(L, 2);
  lua_pushinteger(L, n - 1);
  lua_pushvalue(L, 2);
  lua_call(L, 2, 1);
  leaked++;
  return 1;
}

/* counter(): a closure counting in its upvalue. */
static int countup (lua_State *L) {
  lua_Integer c = lua_tointeger(L, lua_upvalueindex(1)) + 1;
  lua_pushinteger(L, c);
  lua_copy(L, -1, lua_upvalueindex(1));
  lua_pushvalue(L, lua_upvalueindex(2));
  return 2;
}

static int t_counter (lua_State *L) {
  lua_pushinteger(L, 0);
  lua_pushstring(L, "tag");
  lua_pushcclosure(L, countup, 2);
  return 1;
}

/* buffer(n, s): n 'x's, then s, through a luaL_Buffer. */
static int t_buffer (lua_State *L) {
  luaL_Buffer b;
  lua_Integer i, n = luaL_checkinteger(L, 1);
  luaL_buffinit(L, &b);
  for (i = 0; i < n; i++)
    luaL_addchar(&b, 'x');
  lua_pushvalue(L, 2);
  luaL_addvalue(&b);
  luaL_addstring(&b, "!");
  luaL_pushresult(&b);
  lua_pushinteger(L, (lua_Integer)luaL_bufflen(&b));
  return 2;
}

/* buffail(n): a big buffer abandoned by an error. */
static int t_buffail (lua_State *L) {
  luaL_Buffer b;
  char *p = luaL_buffinitsize(L, &b, (size_t)luaL_checkinteger(L, 1));
  memset(p, 'y', 10);
  luaL_addsize(&b, 10);
  return luaL_error(L, "abandoned");
}

#define TNAME "capitest.T"

static int t_newT (lua_State *L) {
  lua_Integer *p = (lua_Integer *)lua_newuserdatauv(L, sizeof(lua_Integer), 1);
  *p = luaL_optinteger(L, 1, 0);
  luaL_setmetatable(L, TNAME);
  lua_pushstring(L, "uv");
  lua_setiuservalue(L, -2, 1);
  return 1;
}

static int T_get (lua_State *L) {
  lua_Integer *p = (lua_Integer *)luaL_checkudata(L, 1, TNAME);
  lua_pushinteger(L, *p);
  lua_getiuservalue(L, 1, 1);
  return 2;
}

static int T_gc (lua_State *L) {
  lua_Integer *p = (lua_Integer *)luaL_checkudata(L, 1, TNAME);
  if (*p < 0)
    return luaL_error(L, "finalizer of %d failed", (int)*p);
  return 0;
}

static int t_ref (lua_State *L) {
  int r1, r2, r3;
  lua_settop(L, 1);
  lua_pushvalue(L, 1);
  r1 = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushstring(L, "second");
  r2 = luaL_ref(L, LUA_REGISTRYINDEX);
  luaL_unref(L, LUA_REGISTRYINDEX, r1);
  lua_pushstring(L, "third");
  r3 = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_rawgeti(L, LUA_REGISTRYINDEX, r2);
  lua_rawgeti(L, LUA_REGISTRYINDEX, r3);
  lua_pushboolean(L, r3 == r1);
  lua_pushnil(L);
  lua_pushinteger(L, luaL_ref(L, LUA_REGISTRYINDEX));
  luaL_unref(L, LUA_REGISTRYINDEX, r2);
  luaL_unref(L, LUA_REGISTRYINDEX, r3);
  return 4;
}

/* The registry's fixed slots, as lua.h numbers them. */
static int t_registry (lua_State *L) {
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  lua_pushboolean(L, lua_rawequal(L, -1, 1));
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
  lua_pushboolean(L, lua_pushthread(L) && lua_rawequal(L, -1, -2));
  lua_pushboolean(L, lua_tothread(L, -3) != NULL);
  return 3;
}

static int t_stack (lua_State *L) {
  int i;
  luaL_checkstack(L, 5000, "big");
  for (i = 0; i < 5000; i++)
    lua_pushinteger(L, i);
  lua_pushinteger(L, lua_gettop(L));
  lua_replace(L, 1);
  lua_settop(L, 1);
  lua_pushboolean(L, lua_checkstack(L, 2000000));
  return 2;
}

static int t_types (lua_State *L) {
  int i, n = lua_gettop(L);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (i = 1; i <= n + 1; i++) {
    luaL_addstring(&b, luaL_typename(L, i));
    luaL_addchar(&b, lua_isnumber(L, i) ? 'N' : '-');
    luaL_addchar(&b, lua_isstring(L, i) ? 'S' : '-');
    luaL_addchar(&b, lua_isinteger(L, i) ? 'I' : '-');
    luaL_addchar(&b, lua_iscfunction(L, i) ? 'C' : '-');
    luaL_addchar(&b, ' ');
  }
  luaL_pushresult(&b);
  return 1;
}

static int t_tonumber (lua_State *L) {
  int isnum;
  lua_Number d = lua_tonumberx(L, 1, &isnum);
  lua_Integer i;
  lua_pushnumber(L, d);
  lua_pushboolean(L, isnum);
  i = lua_tointegerx(L, 1, &isnum);
  lua_pushinteger(L, i);
  lua_pushboolean(L, isnum);
  return 4;
}

static int t_next (lua_State *L) {
  lua_Integer sum = 0;
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_pushnil(L);
  while (lua_next(L, 1)) {
    sum += lua_tointeger(L, -1);
    lua_pop(L, 1);
  }
  lua_pushinteger(L, sum);
  return 1;
}

static int t_loadstring (lua_State *L) {
  int st = luaL_loadstring(L, luaL_checkstring(L, 1));
  lua_pushinteger(L, st);
  lua_insert(L, -2);
  return 2;
}

static int t_traceback (lua_State *L) {
  luaL_traceback(L, L, luaL_optstring(L, 1, NULL), 1);
  return 1;
}

static int t_where (lua_State *L) {
  luaL_where(L, 1);
  return 1;
}

static int t_gsub (lua_State *L) {
  luaL_gsub(L, luaL_checkstring(L, 1), luaL_checkstring(L, 2), luaL_checkstring(L, 3));
  return 1;
}

static int t_fstring (lua_State *L) {
  lua_pushfstring(L, "%s|%d|%I|%f|%c|%U|%%|%q", "str", -3, (lua_Integer)1 << 40, 0.1, 'A', 0x20AC);
  return 1;
}

static int t_sameptr (lua_State *L) {
  lua_pushcfunction(L, t_leaked);
  lua_pushcfunction(L, t_leaked);
  lua_pushboolean(L, lua_rawequal(L, -1, -2));
  lua_pushboolean(L, lua_tocfunction(L, -2) == t_leaked);
  return 2;
}

static const luaL_Reg T_methods[] = {
  {"get", T_get},
  {NULL, NULL}
};

static const luaL_Reg funcs[] = {
  {"leaked", t_leaked},
  {"call", t_call},
  {"fail_after", t_fail_after},
  {"pcall", t_pcall},
  {"pcallh", t_pcallh},
  {"error", t_error},
  {"lerror", t_lerror},
  {"memerr", t_memerr},
  {"checkint", t_checkint},
  {"checknum", t_checknum},
  {"checkopt", t_checkopt},
  {"gettable", t_gettable},
  {"settable", t_settable},
  {"arith", t_arith},
  {"unm", t_unm},
  {"compare", t_compare},
  {"concat", t_concat},
  {"len", t_len},
  {"tostring", t_tostring},
  {"badadd", t_badadd},
  {"yield", t_yield},
  {"yieldk", t_yieldk},
  {"callk", t_callk},
  {"pcallk", t_pcallk},
  {"resume", t_resume},
  {"spawn", t_spawn},
  {"deep", t_deep},
  {"counter", t_counter},
  {"buffer", t_buffer},
  {"buffail", t_buffail},
  {"newT", t_newT},
  {"ref", t_ref},
  {"registry", t_registry},
  {"stack", t_stack},
  {"types", t_types},
  {"tonumber", t_tonumber},
  {"next", t_next},
  {"loadstring", t_loadstring},
  {"traceback", t_traceback},
  {"where", t_where},
  {"gsub", t_gsub},
  {"fstring", t_fstring},
  {"sameptr", t_sameptr},
  {"placeholder", NULL},
  {NULL, NULL}
};

LUAMOD_API int luaopen_capitest (lua_State *L) {
  luaL_checkversion(L);
  if (luaL_newmetatable(L, TNAME)) {
    luaL_newlib(L, T_methods);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, T_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
  luaL_newlib(L, funcs);
  return 1;
}
