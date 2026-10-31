/*
** A C host that embeds liblua: states with the host's allocator, the
** libraries, hooks and the rest of the debug interface, to-be-closed
** slots, dumps, warnings, the collector's options, and lauxlib's
** results of system calls. `just capi-test` builds it against our
** liblua.so, our liblua.a, and the reference's liblua.so, and compares
** what each prints, addresses masked. Every case prints only what both
** must agree on: no addresses, counts of allocations, or hash orders.
*/

#include <errno.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static void section (const char *name) {
  printf("-- %s\n", name);
}

/* Runs chunk `code` protected and prints how it ended. */
static int run (lua_State *L, const char *code) {
  int st = luaL_loadstring(L, code);
  if (st == LUA_OK)
    st = lua_pcall(L, 0, 0, 0);
  if (st != LUA_OK) {
    const char *msg = lua_tostring(L, -1);
    printf("  status %d: %s\n", st, msg ? msg : "(not a string)");
    lua_pop(L, 1);
  }
  fflush(stdout);
  fflush(stderr);
  return st;
}

static lua_State *newstate (void) {
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  return L;
}

/* ---------------------------------------------------------------------
** Allocators
** ------------------------------------------------------------------- */

typedef struct {
  long live;    /* bytes held */
  long calls;   /* calls made */
  int fail;     /* refuse every allocation that grows */
  long limit;   /* refuse growing past this many bytes, if > 0 */
  lua_Alloc next;  /* when set, pass calls on to it */
  void *next_ud;
} Counter;

static void *counting (void *ud, void *ptr, size_t osize, size_t nsize) {
  Counter *c = (Counter *)ud;
  size_t old = ptr ? osize : 0;
  void *p;
  c->calls++;
  if (nsize > old && (c->fail || (c->limit > 0 && c->live + (long)(nsize - old) > c->limit)))
    return NULL;
  if (c->next)
    p = c->next(c->next_ud, ptr, osize, nsize);
  else if (nsize == 0) {
    free(ptr);
    p = NULL;
  }
  else
    p = realloc(ptr, nsize);
  if (p != NULL || nsize == 0)
    c->live += (long)nsize - (long)old;
  return p;
}

static void t_alloc (void) {
  Counter c = {0}, c2 = {0};
  lua_State *L;
  void *ud;
  section("lua_newstate, lua_getallocf, lua_setallocf, lua_close");
  L = lua_newstate(counting, &c, 42);
  printf("  state: %s, holds memory: %s\n", L ? "yes" : "no", c.live > 0 ? "yes" : "no");
  printf("  getallocf: %s\n", lua_getallocf(L, &ud) == counting && ud == &c ? "same" : "other");
  luaL_openselectedlibs(L, ~0, 0);
  run(L, "local t = {} for i = 1, 1000 do t[i] = tostring(i) .. 'x' end assert(#t == 1000)");
  /* A second allocator that passes everything on to the first. */
  c2.next = counting;
  c2.next_ud = &c;
  lua_setallocf(L, counting, &c2);
  printf("  getallocf after setallocf: %s\n", lua_getallocf(L, &ud) == counting && ud == &c2 ? "new" : "old");
  run(L, "local t = {} for i = 1, 1000 do t[i] = {i} end collectgarbage()");
  printf("  new allocator called: %s\n", c2.calls > 0 ? "yes" : "no");
  /* Allocation failure: errors are LUA_ERRMEM, and the state goes on. */
  c.fail = 1;
  run(L, "local t = {} for i = 1, 100000 do t[i] = {} end");
  printf("  loadstring when failing: %d\n", luaL_loadstring(L, "return 1 + 1"));
  lua_pop(L, 1);
  c.fail = 0;
  run(L, "print('  after the failure:', 6 * 7)");
  lua_close(L);
  printf("  freed everything at close: %s\n", c.live == 0 ? "yes" : "no");
  c.fail = 1;
  printf("  lua_newstate without memory: %s\n", lua_newstate(counting, &c, 0) == NULL ? "NULL" : "a state");
  c.fail = 0;
  /* A limit: the libraries load, then a big table cannot. */
  c.limit = 400000;
  L = lua_newstate(counting, &c, 0);
  luaL_openselectedlibs(L, ~0, 0);
  run(L, "local t = {} for i = 1, 1e6 do t[i] = i end");
  run(L, "print('  under the limit:', #string.rep('x', 100))");
  lua_close(L);
  printf("  freed everything with a limit: %s\n", c.live == 0 ? "yes" : "no");
}

/* ---------------------------------------------------------------------
** States and libraries
** ------------------------------------------------------------------- */

static jmp_buf panic_jmp;

static int panicked (lua_State *L) {
  printf("  panic: %s\n", lua_tostring(L, -1));
  fflush(stdout);
  longjmp(panic_jmp, 1);
  return 0;
}

static void t_states (void) {
  lua_State *L, *L1;
  section("luaL_newstate, luaL_openselectedlibs, luaopen_*");
  L = luaL_newstate();
  printf("  version: %d\n", (int)lua_version(L));
  luaL_openselectedlibs(L, LUA_GLIBK | LUA_STRLIBK | LUA_LOADLIBK, LUA_TABLIBK | LUA_MATHLIBK);
  run(L, "print('  globals:', type(string), type(table), type(math), type(io), type(require))");
  run(L, "print('  preloaded:', type(package.preload.table), type(package.preload.math), type(package.preload.io))");
  run(L, "print('  required:', require('table').concat({1, 2}, '+'), type(table), package.loaded.table == require 'table')");
  /* luaopen_ functions set no global; luaL_requiref does when told. */
  luaL_requiref(L, "m2", luaopen_math, 0);
  {
    int pi = lua_getfield(L, -1, "pi");
    int glb = lua_getglobal(L, "m2");
    printf("  luaopen_math: %s, global m2: %d\n", pi == LUA_TNUMBER ? "pi" : "?", glb);
  }
  lua_pop(L, 3);
  luaL_requiref(L, "u8", luaopen_utf8, 1);
  lua_pop(L, 1);
  run(L, "print('  luaopen_utf8 with glb:', u8.char(72, 105), type(utf8), package.loaded.u8 == u8)");
  luaL_requiref(L, "_G", luaopen_base, 1);
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  printf("  luaopen_base returns _G: %s\n", lua_rawequal(L, -1, -2) ? "yes" : "no");
  lua_settop(L, 0);
  luaL_requiref(L, "io", luaopen_io, 1);
  luaL_requiref(L, "os", luaopen_os, 1);
  luaL_requiref(L, "coroutine", luaopen_coroutine, 1);
  luaL_requiref(L, "debug", luaopen_debug, 1);
  luaL_requiref(L, "table", luaopen_table, 1);
  luaL_requiref(L, "string", luaopen_string, 1);
  luaL_requiref(L, "package", luaopen_package, 1);
  lua_settop(L, 0);
  run(L, "print('  all open:', type(io.write), type(os.time), type(coroutine.wrap), type(debug.getinfo), type(package.searchers))");
  run(L, "io.write('  io.write to stdout\\n') io.stdout:flush()");
  /* The extra space: a new thread starts with a copy of the main one's. */
  *(int *)lua_getextraspace(L) = 1234;
  L1 = lua_newthread(L);
  printf("  extra space copied: %d\n", *(int *)lua_getextraspace(L1));
  *(int *)lua_getextraspace(L1) = 99;
  printf("  main extra space kept: %d\n", *(int *)lua_getextraspace(L));
  lua_pop(L, 1);
  /* Panic functions: luaL_newstate's, and one that jumps out. */
  printf("  luaL_newstate has a panic function: %s\n", lua_atpanic(L, panicked) != NULL ? "yes" : "no");
  printf("  the new one: %s\n", lua_atpanic(L, panicked) == panicked ? "yes" : "no");
  if (setjmp(panic_jmp) == 0) {
    lua_pushstring(L, "unprotected");
    lua_error(L);
    printf("  not reached\n");
  }
  lua_close(L);
  L = lua_newstate(counting, &(Counter){0}, 0);
  printf("  lua_newstate has no panic function: %s\n", lua_atpanic(L, NULL) == NULL ? "yes" : "no");
  lua_close(L);
}

/* ---------------------------------------------------------------------
** Hooks
** ------------------------------------------------------------------- */

static char events[4096];

static void record (const char *fmt, const char *a, int b) {
  size_t n = strlen(events);
  if (n < sizeof(events) - 100)
    snprintf(events + n, sizeof(events) - n, fmt, a, b);
}

static const char *const event_names[] = {"call", "return", "line", "count", "tail call"};

static void hook (lua_State *L, lua_Debug *ar) {
  lua_getinfo(L, "nSlr", ar);
  record(" %s", event_names[ar->event], 0);
  if (ar->event == LUA_HOOKLINE)
    record(":%s%d", "", ar->currentline);
  else if (ar->event != LUA_HOOKCOUNT) {
    record("(%s", ar->name ? ar->name : "?", 0);
    record(" %s", ar->what, 0);
    record(" %s%d", "t", ar->ntransfer);
    record(")%s", "", 0);
  }
}

static int counted = 0;

static void counthook (lua_State *L, lua_Debug *ar) {
  (void)L;
  if (ar->event == LUA_HOOKCOUNT)
    counted++;
}

/* A line hook that reads and writes the locals of the running function. */
static void localhook (lua_State *L, lua_Debug *ar) {
  lua_Debug top;
  const char *name;
  int i;
  if (!lua_getstack(L, 0, &top))
    return;
  lua_getinfo(L, "Sl", &top);
  if (strcmp(top.what, "Lua") != 0)
    return;
  for (i = 1; (name = lua_getlocal(L, &top, i)) != NULL; i++) {
    if (strcmp(name, "secret") == 0 && lua_isinteger(L, -1) && lua_tointeger(L, -1) == 1) {
      lua_pushinteger(L, 42);
      record(" set %s=42", lua_setlocal(L, &top, i), 0);
    }
    lua_pop(L, 1);
  }
  (void)ar;
}

static void errhook (lua_State *L, lua_Debug *ar) {
  if (ar->event == LUA_HOOKCALL) {
    lua_getinfo(L, "n", ar);
    if (ar->name && strcmp(ar->name, "forbidden") == 0)
      luaL_error(L, "hook refused '%s'", ar->name);
  }
}

static void yieldhook (lua_State *L, lua_Debug *ar) {
  (void)ar;
  lua_yield(L, 0);
}

static void t_hooks (void) {
  lua_State *L = newstate();
  section("lua_sethook, lua_gethook, lua_gethookmask, lua_gethookcount");
  run(L, "function f(a, b) local c = a + b\n return c end\n function g() return f(1, 2) end");
  events[0] = 0;
  lua_sethook(L, hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKLINE, 0);
  printf("  gethook: %s, mask %d, count %d\n", lua_gethook(L) == hook ? "hook" : "other",
         lua_gethookmask(L), lua_gethookcount(L));
  run(L, "g()");
  lua_sethook(L, NULL, 0, 0);
  printf("  events:%s\n", events);
  printf("  after turning off: %s, mask %d\n", lua_gethook(L) == NULL ? "none" : "some", lua_gethookmask(L));
  lua_sethook(L, counthook, LUA_MASKCOUNT, 7);
  printf("  count hook: mask %d, count %d\n", lua_gethookmask(L), lua_gethookcount(L));
  run(L, "local x = 0 for i = 1, 100 do x = x + i end");
  lua_sethook(L, NULL, 0, 0);
  printf("  count events: %s\n", counted > 10 ? "many" : "few");
  /* debug.gethook sees a C hook as external; lua_gethook sees the
  ** debug library's as a function that runs it again. */
  lua_sethook(L, hook, LUA_MASKLINE, 0);
  run(L, "local h, m, c = debug.gethook() print('  debug.gethook:', h, m, c)");
  lua_sethook(L, NULL, 0, 0);
  run(L, "lines = {} debug.sethook(function(e, l) lines[#lines + 1] = l end, 'l')");
  {
    lua_Hook h = lua_gethook(L);
    int mask = lua_gethookmask(L), count = lua_gethookcount(L);
    printf("  debug.sethook's hook: %s, mask %d\n", h != NULL ? "a function" : "none", mask);
    lua_sethook(L, NULL, 0, 0);
    run(L, "local a = 1");
    lua_sethook(L, h, mask, count);
    run(L, "local a = 1\nlocal b = 2\ndebug.sethook() print('  restored:', #lines > 0, select(2, debug.gethook()))");
  }
  /* A hook that changes a local. */
  events[0] = 0;
  lua_sethook(L, localhook, LUA_MASKLINE, 0);
  run(L, "local function f()\n local secret = 1\n local other = 2\n print('  secret:', secret)\nend\nf()");
  lua_sethook(L, NULL, 0, 0);
  printf("  local hook:%s\n", events);
  /* An error from a hook unwinds to the protected call. */
  lua_sethook(L, errhook, LUA_MASKCALL, 0);
  run(L, "function forbidden() end print('  before') forbidden() print('not reached')");
  run(L, "print('  pcall in Lua:', pcall(forbidden))");
  lua_sethook(L, NULL, 0, 0);
  /* Coroutines start with their creator's hook. */
  lua_sethook(L, counthook, LUA_MASKCOUNT, 1);
  run(L, "co = coroutine.create(function () end)");
  lua_sethook(L, NULL, 0, 0);
  run(L, "print('  coroutine inherits:', debug.gethook(co))");
  lua_close(L);
  (void)yieldhook;
}

/* ---------------------------------------------------------------------
** The debug interface
** ------------------------------------------------------------------- */

/* where(): the caller's locals, its info, and its active lines. */
static int c_inspect (lua_State *L) {
  lua_Debug ar;
  const char *name;
  int i;
  if (!lua_getstack(L, 1, &ar))
    return luaL_error(L, "no caller");
  lua_getinfo(L, "nSltu", &ar);
  printf("  caller: %s %s %s line %d defined %d-%d nups %d nparams %d vararg %d tail %d\n",
         ar.name ? ar.name : "?", ar.namewhat, ar.short_src, ar.currentline, ar.linedefined,
         ar.lastlinedefined, ar.nups, ar.nparams, ar.isvararg, ar.istailcall);
  for (i = 1; (name = lua_getlocal(L, &ar, i)) != NULL; i++) {
    printf("  local %d %s = %s\n", i, name, luaL_tolstring(L, -1, NULL));
    lua_pop(L, 2);
  }
  for (i = -1; (name = lua_getlocal(L, &ar, i)) != NULL; i--) {
    printf("  vararg %d %s = %s\n", i, name, luaL_tolstring(L, -1, NULL));
    lua_pop(L, 2);
  }
  /* The C function's own temporaries. */
  lua_pushinteger(L, 5);
  if (lua_getstack(L, 0, &ar) && (name = lua_getlocal(L, &ar, lua_gettop(L))) != NULL) {
    printf("  own slot: %s = %d\n", name, (int)lua_tointeger(L, -1));
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  /* 'f' then 'L', whatever their order. */
  lua_getstack(L, 1, &ar);
  lua_getinfo(L, "Lf", &ar);
  printf("  getinfo Lf: %s %s\n", luaL_typename(L, -2), luaL_typename(L, -1));
  lua_pushnil(L);
  {
    int lines = 0, max = 0;
    while (lua_next(L, -2)) {
      int l = (int)lua_tointeger(L, -2);
      lines++;
      if (l > max)
        max = l;
      lua_pop(L, 1);
    }
    printf("  active lines: %d, last %d\n", lines, max);
  }
  lua_pop(L, 2);
  printf("  getinfo of a C level 0: ");
  lua_getstack(L, 0, &ar);
  lua_getinfo(L, "SL", &ar);
  printf("%s %s %s\n", ar.what, ar.short_src, luaL_typename(L, -1));
  lua_pop(L, 1);
  return 0;
}

static int c_params (lua_State *L) {
  const char *name;
  int i;
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_settop(L, 1);
  for (i = 1; (name = lua_getlocal(L, NULL, i)) != NULL; i++)
    printf("  parameter %d: %s\n", i, name);
  printf("  stack kept: %d\n", lua_gettop(L));
  lua_pushvalue(L, 1);
  lua_Debug ar;
  lua_getinfo(L, ">Su", &ar);
  printf("  getinfo '>': %s %d-%d nparams %d, top %d\n", ar.what, ar.linedefined, ar.lastlinedefined, ar.nparams, lua_gettop(L));
  return 0;
}

static int c_upvalues (lua_State *L) {
  /* 1, 2: closures sharing an upvalue; 3: one with its own. */
  int same = lua_upvalueid(L, 1, 1) == lua_upvalueid(L, 2, 1);
  int other = lua_upvalueid(L, 1, 1) == lua_upvalueid(L, 3, 1);
  printf("  upvalueid: shared %d, own %d, out of range %s\n", same, other,
         lua_upvalueid(L, 1, 5) == NULL ? "NULL" : "?");
  lua_upvaluejoin(L, 3, 1, 1, 1);
  printf("  after upvaluejoin: %d\n", lua_upvalueid(L, 1, 1) == lua_upvalueid(L, 3, 1));
  lua_pushcfunction(L, c_upvalues);
  printf("  light C function: %s\n", lua_upvalueid(L, -1, 1) == NULL ? "NULL" : "?");
  lua_pushinteger(L, 1);
  lua_pushcclosure(L, c_upvalues, 1);
  printf("  C closure: %s\n", lua_upvalueid(L, -1, 1) != NULL && lua_upvalueid(L, -1, 2) == NULL ? "ok" : "?");
  lua_pop(L, 2);
  return 0;
}

static void t_debug (void) {
  lua_State *L = newstate();
  section("lua_getlocal, lua_setlocal, lua_getinfo, lua_upvalueid, lua_upvaluejoin");
  lua_register(L, "inspect", c_inspect);
  lua_register(L, "params", c_params);
  lua_register(L, "upvalues", c_upvalues);
  run(L, "local function probe(a, b, ...)\n  local c = a .. b\n  do local d = 1 end\n  inspect()\n  return c\nend\nprobe('x', 'y', 10, 20)");
  run(L, "params(function (alpha, beta, ...) local gamma end)");
  run(L, "local n = 0 local function a() n = n + 1 return n end local function b() n = n + 10 return n end\n"
         "local m = 100 local function c() m = m + 1 return m end\n"
         "upvalues(a, b, c) print('  joined:', a(), c(), b(), c())");
  lua_close(L);
}

/* ---------------------------------------------------------------------
** To-be-closed slots
** ------------------------------------------------------------------- */

/* newobj(name): a value whose __close prints its name and the error. */
static int c_toclose (lua_State *L) {
  int mode = (int)luaL_checkinteger(L, 1);
  lua_settop(L, 1);
  lua_getglobal(L, "newobj");
  lua_pushliteral(L, "first");
  lua_call(L, 1, 1);
  lua_toclose(L, 2);
  lua_getglobal(L, "newobj");
  lua_pushliteral(L, "second");
  lua_call(L, 1, 1);
  lua_toclose(L, 3);
  lua_pushboolean(L, 0);
  lua_toclose(L, 4);  /* false needs no closing */
  switch (mode) {
    case 1:  /* return: both close, results stay */
      lua_pushliteral(L, "result");
      return 1;
    case 2:  /* lua_closeslot closes one and sets it nil */
      lua_closeslot(L, 3);
      printf("  slot after closeslot: %s\n", luaL_typename(L, 3));
      lua_pushliteral(L, "after closeslot");
      return 1;
    case 3:  /* lua_settop below a marked slot closes it */
      lua_settop(L, 2);
      printf("  after settop: %d\n", lua_gettop(L));
      return 0;
    case 4:  /* an error closes them with the error object */
      return luaL_error(L, "failed in C");
    default:  /* a value without __close */
      lua_newtable(L);
      lua_toclose(L, -1);
      return 0;
  }
}

static void t_toclose (void) {
  lua_State *L = newstate();
  section("lua_toclose, lua_closeslot");
  lua_register(L, "toclose", c_toclose);
  run(L, "function newobj(name) return setmetatable({}, {__close = function (_, e) print('  close', name, e) end}) end");
  run(L, "print('  returned:', toclose(1))");
  run(L, "print('  returned:', toclose(2))");
  run(L, "print('  returned:', toclose(3))");
  run(L, "print('  pcall:', pcall(toclose, 4))");
  run(L, "print('  pcall:', pcall(toclose, 5))");
  lua_close(L);
}

/* ---------------------------------------------------------------------
** lua_dump
** ------------------------------------------------------------------- */

typedef struct {
  char buf[8192];
  size_t n;
  int ended;     /* the writer saw the end (NULL, 0) */
  int fail_at;   /* return an error once this many bytes are in */
} Sink;

static int writer (lua_State *L, const void *p, size_t sz, void *ud) {
  Sink *s = (Sink *)ud;
  (void)L;
  if (p == NULL) {
    s->ended = 1;
    return 0;
  }
  if (s->fail_at > 0 && s->n + sz >= (size_t)s->fail_at)
    return 77;
  memcpy(s->buf + s->n, p, sz);
  s->n += sz;
  return 0;
}

static int raising_writer (lua_State *L, const void *p, size_t sz, void *ud) {
  (void)p; (void)sz; (void)ud;
  return luaL_error(L, "writer raised");
}

static unsigned long checksum (const char *b, size_t n) {
  unsigned long h = 5381;
  size_t i;
  for (i = 0; i < n; i++)
    h = h * 33 + (unsigned char)b[i];
  return h;
}

static int c_dumpraise (lua_State *L) {
  lua_dump(L, raising_writer, NULL, 0);
  printf("not reached\n");
  return 0;
}

static void t_dump (void) {
  lua_State *L = newstate();
  Sink s;
  int st, top;
  section("lua_dump");
  luaL_loadstring(L, "local a, b = ... return a * b + 1, 'dumped'");
  top = lua_gettop(L);
  memset(&s, 0, sizeof s);
  st = lua_dump(L, writer, &s, 0);
  printf("  status %d, %d bytes, checksum %lu, ended %d, top kept %d\n", st, (int)s.n,
         checksum(s.buf, s.n), s.ended, lua_gettop(L) == top);
  st = luaL_loadbuffer(L, s.buf, s.n, "=dumped");
  lua_pushinteger(L, 6);
  lua_pushinteger(L, 7);
  lua_call(L, 2, 2);
  printf("  loaded back (%d): %d %s\n", st, (int)lua_tointeger(L, -2), lua_tostring(L, -1));
  lua_pop(L, 2);
  memset(&s, 0, sizeof s);
  st = lua_dump(L, writer, &s, 1);
  printf("  stripped: status %d, %d bytes, checksum %lu\n", st, (int)s.n, checksum(s.buf, s.n));
  memset(&s, 0, sizeof s);
  s.fail_at = 20;
  st = lua_dump(L, writer, &s, 0);
  printf("  writer error: status %d, ended %d\n", st, s.ended);
  lua_pop(L, 1);
  lua_pushcfunction(L, c_dumpraise);
  luaL_loadstring(L, "return 1");
  st = lua_pcall(L, 1, 0, 0);
  printf("  raising writer: %d %s\n", st, lua_tostring(L, -1));
  lua_pop(L, 1);
  lua_close(L);
}

/* ---------------------------------------------------------------------
** Warnings
** ------------------------------------------------------------------- */

static char warnings[1024];

static void warnf (void *ud, const char *msg, int tocont) {
  size_t n = strlen(warnings);
  snprintf(warnings + n, sizeof(warnings) - n, "[%s%s%s]", (const char *)ud, msg, tocont ? "..." : "");
}

static void t_warn (void) {
  lua_State *L = newstate();
  section("lua_setwarnf, lua_warning");
  /* luaL_newstate's warnings are on, to stderr. */
  run(L, "warn('default ', 'on')");
  run(L, "warn('@off') warn('hidden') warn('@on') warn('shown')");
  lua_setwarnf(L, warnf, "u:");
  run(L, "warn('a', 'b', 'c') warn('@on')");
  lua_warning(L, "from C", 0);
  run(L, "setmetatable({}, {__gc = function () error('in gc') end}) collectgarbage()");
  printf("  collected: %s\n", warnings);
  lua_setwarnf(L, NULL, NULL);
  run(L, "warn('nobody hears')");
  lua_warning(L, "nor this", 0);
  lua_close(L);
  /* lua_newstate has no warning function. */
  L = lua_newstate(counting, &(Counter){0}, 0);
  luaL_openselectedlibs(L, ~0, 0);
  run(L, "warn('@on') warn('silent')");
  lua_close(L);
}

/* ---------------------------------------------------------------------
** lauxlib's results
** ------------------------------------------------------------------- */

static int c_execresult (lua_State *L) {
  int n;
  errno = 0;
  n = luaL_execresult(L, system(luaL_checkstring(L, 1)));
  return n;
}

static int c_fileresult (lua_State *L) {
  int en = (int)luaL_checkinteger(L, 1);
  errno = en;
  return luaL_fileresult(L, lua_toboolean(L, 2), luaL_optstring(L, 3, NULL));
}

static void t_results (void) {
  lua_State *L = newstate();
  section("luaL_execresult, luaL_fileresult");
  lua_register(L, "execresult", c_execresult);
  lua_register(L, "fileresult", c_fileresult);
  run(L, "print('  exit 0:', execresult('exit 0'))");
  run(L, "print('  exit 3:', execresult('exit 3'))");
  run(L, "print('  signal:', execresult('kill -9 $$'))");
  run(L, "print('  ok:', fileresult(0, true))");
  run(L, "print('  ENOENT:', fileresult(2, false, 'some/file'))");
  run(L, "print('  no name:', fileresult(13, false))");
  run(L, "print('  no errno:', fileresult(0, false, 'x'))");
  run(L, "local r, m, e = fileresult(2, false, ('d/'):rep(400) .. 'f') print('  long name:', r, #m, m:sub(-32), e)");
  lua_close(L);
}

/* ---------------------------------------------------------------------
** The collector
** ------------------------------------------------------------------- */

static void t_gc (void) {
  lua_State *L = newstate();
  int k, b, i;
  section("lua_gc");
  printf("  isrunning %d\n", lua_gc(L, LUA_GCISRUNNING));
  printf("  stop %d", lua_gc(L, LUA_GCSTOP));
  printf(", isrunning %d\n", lua_gc(L, LUA_GCISRUNNING));
  printf("  restart %d", lua_gc(L, LUA_GCRESTART));
  printf(", isrunning %d\n", lua_gc(L, LUA_GCISRUNNING));
  printf("  collect %d\n", lua_gc(L, LUA_GCCOLLECT));
  k = lua_gc(L, LUA_GCCOUNT);
  b = lua_gc(L, LUA_GCCOUNTB);
  printf("  count in range: %d, countb in range: %d\n", k > 5 && k < 200, b >= 0 && b < 1024);
  run(L, "garbage = {} for i = 1, 1000 do garbage[i] = {} end garbage = nil");
  for (i = 0; i < 1000 && lua_gc(L, LUA_GCSTEP, (size_t)0) == 0; i++)
    ;
  printf("  basic steps end a cycle: %s\n", i < 1000 ? "yes" : "no");
  printf("  step of 1 MB ends a cycle: %d\n", lua_gc(L, LUA_GCSTEP, (size_t)1 << 20));
  printf("  gen from %d\n", lua_gc(L, LUA_GCGEN));
  printf("  gen again from %d\n", lua_gc(L, LUA_GCGEN));
  run(L, "print('  collectgarbage sees:', collectgarbage('incremental'))");
  printf("  inc from %d\n", lua_gc(L, LUA_GCINC));
  for (i = 0; i < LUA_GCPN; i++)
    printf("  param %d: %d", i, lua_gc(L, LUA_GCPARAM, i, -1));
  printf("\n");
  printf("  set pause: old %d", lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, 150));
  printf(", now %d\n", lua_gc(L, LUA_GCPARAM, LUA_GCPPAUSE, -1));
  run(L, "print('  collectgarbage param:', collectgarbage('param', 'pause'), collectgarbage('param', 'stepmul', 300), collectgarbage('param', 'stepmul'))");
  printf("  invalid option %d\n", lua_gc(L, 99));
  run(L, "setmetatable({}, {__gc = function () print('  in finalizer:', collectgarbage('step')) end}) collectgarbage()");
  lua_close(L);
}

/* ---------------------------------------------------------------------
** Threads from the host
** ------------------------------------------------------------------- */

static void t_threads (void) {
  lua_State *L = newstate(), *co;
  int nres, st;
  section("lua_newthread, lua_resume, lua_closethread from a host");
  co = lua_newthread(L);
  luaL_loadstring(co, "local a = ... local b = coroutine.yield(a + 1) local x <close> = setmetatable({}, {__close = function () print('  closed') end}) coroutine.yield(b * 2) return 'end'");
  lua_pushinteger(co, 10);
  st = lua_resume(co, L, 1, &nres);
  printf("  resume %d: %d results, %d\n", st, nres, (int)lua_tointeger(co, -1));
  lua_pop(co, nres);
  lua_pushinteger(co, 5);
  st = lua_resume(co, L, 1, &nres);
  printf("  resume %d: %d\n", st, (int)lua_tointeger(co, -1));
  lua_pop(co, nres);
  printf("  status %d\n", lua_status(co));
  st = lua_closethread(co, L);
  printf("  closethread %d, status %d\n", st, lua_status(co));
  lua_pop(L, 1);
  luaL_traceback(L, L, "host traceback", 0);
  printf("  %s\n", lua_tostring(L, -1));
  lua_pop(L, 1);
  if (luaL_dostring(L, "return 'dostring', 2"))
    printf("  dostring failed\n");
  printf("  %s %d, top %d\n", lua_tostring(L, -2), (int)lua_tointeger(L, -1), lua_gettop(L));
  lua_close(L);
}

int main (void) {
  /* Lua's output and ours in order, whichever writes it. */
  setvbuf(stdout, NULL, _IONBF, 0);
  t_alloc();
  t_states();
  t_hooks();
  t_debug();
  t_toclose();
  t_dump();
  t_warn();
  t_results();
  t_gc();
  t_threads();
  printf("OK\n");
  return 0;
}
