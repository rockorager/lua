/*
** io handles as C modules see them: luaL_Stream userdata with the
** "FILE*" metatable and a real FILE *, read and written by the module and
** by Lua on the same stream, and handles a module makes with its own
** close function, which io then reads, writes, and closes. Built by
** `just capi-test` and run by handles.lua on our lua and the reference.
*/

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

static int closes = 0;

static FILE *tofile (lua_State *L) {
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
  if (p->closef == NULL) luaL_error(L, "closed file");
  return p->f;
}

static int s_fileno (lua_State *L) {
  lua_pushinteger(L, fileno(tofile(L)));
  return 1;
}

/* Writes straight to the handle's FILE, through its buffer. */
static int s_write (lua_State *L) {
  FILE *f = tofile(L);
  size_t len;
  const char *s = luaL_checklstring(L, 2, &len);
  lua_pushinteger(L, (lua_Integer)fwrite(s, 1, len, f));
  return 1;
}

/* Reads straight from the handle's FILE, where Lua left it. */
static int s_read (lua_State *L) {
  FILE *f = tofile(L);
  char buf[256];
  size_t n = (size_t)luaL_checkinteger(L, 2);
  if (n > sizeof(buf)) n = sizeof(buf);
  n = fread(buf, 1, n, f);
  lua_pushlstring(L, buf, n);
  return 1;
}

static int s_tell (lua_State *L) {
  lua_pushinteger(L, (lua_Integer)ftell(tofile(L)));
  return 1;
}

/* luaposix's close function: closes the FILE once, then forgets it. */
static int s_fclose (lua_State *L) {
  luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, 1, LUA_FILEHANDLE);
  int res;
  closes++;
  if (p->f == NULL) return 0;
  res = fclose(p->f);
  p->f = NULL;
  return luaL_fileresult(L, res == 0, NULL);
}

/* A close function that raises after closing. */
static int s_badclose (lua_State *L) {
  s_fclose(L);
  return luaL_error(L, "close failed on purpose");
}

/* fdopen(fd, mode [, bad]): a handle around a FILE this module made. */
static int s_fdopen (lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  const char *mode = luaL_checkstring(L, 2);
  int bad = lua_toboolean(L, 3);
  luaL_Stream *p = (luaL_Stream *)lua_newuserdatauv(L, sizeof(luaL_Stream), 0);
  luaL_setmetatable(L, LUA_FILEHANDLE);
  p->closef = bad ? s_badclose : s_fclose;
  p->f = fdopen(fd, mode);
  if (p->f == NULL) return luaL_fileresult(L, 0, NULL);
  return 1;
}

static int s_pipe (lua_State *L) {
  int fds[2];
  if (pipe(fds) != 0) return luaL_fileresult(L, 0, NULL);
  lua_pushinteger(L, fds[0]);
  lua_pushinteger(L, fds[1]);
  return 2;
}

static int s_dup (lua_State *L) {
  lua_pushinteger(L, dup((int)luaL_checkinteger(L, 1)));
  return 1;
}

static int s_closes (lua_State *L) {
  lua_pushinteger(L, closes);
  return 1;
}

/* Whether the handle at 1 holds the process's stdout/stdin FILE. */
static int s_isstd (lua_State *L) {
  FILE *f = tofile(L);
  lua_pushboolean(L, f == stdout || f == stdin || f == stderr);
  return 1;
}

static const luaL_Reg funcs[] = {
  {"fileno", s_fileno},
  {"write", s_write},
  {"read", s_read},
  {"tell", s_tell},
  {"fdopen", s_fdopen},
  {"pipe", s_pipe},
  {"dup", s_dup},
  {"closes", s_closes},
  {"isstd", s_isstd},
  {NULL, NULL}
};

int luaopen_stream (lua_State *L) {
  luaL_newlib(L, funcs);
  return 1;
}
