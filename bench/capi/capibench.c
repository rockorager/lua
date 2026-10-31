/*
** C functions for `just bench-capi`, built against include/ and loaded by
** our C-API lua and by the reference alike.
*/

#include <stdint.h>

#include "lua.h"
#include "lauxlib.h"

/* The minimal C function. */
static int nop (lua_State *L) {
  (void)L;
  return 0;
}

/* A typical one: two checked integers in, one out. */
static int add (lua_State *L) {
  lua_pushinteger(L, luaL_checkinteger(L, 1) + luaL_checkinteger(L, 2));
  return 1;
}

/* C calling Lua: f() through lua_call. */
static int callback (lua_State *L) {
  lua_pushvalue(L, 1);
  lua_call(L, 0, 1);
  return 1;
}

/* The native stack pointer, roughly: for stack use per nested call. */
static int sp (lua_State *L) {
  volatile char here = 0;
  lua_pushinteger(L, (lua_Integer)(intptr_t)&here);
  return 1;
}

static const luaL_Reg funcs[] = {
  {"nop", nop},
  {"add", add},
  {"callback", callback},
  {"sp", sp},
  {NULL, NULL}
};

LUAMOD_API int luaopen_capibench (lua_State *L) {
  luaL_newlib(L, funcs);
  return 1;
}
