/*
** When C libraries are closed: built twice, as unload1.so (-DN=1) and
** unload2.so (-DN=2), and loaded in that order by unload.lua. Each
** module's userdata has a finalizer in the module's code, and each
** library's destructor reports whether the other library is still
** loaded. The reference closes libraries with the state, after every
** finalizer and the last loaded first, so the output is "gc 2", "gc 1",
** "unload 2" with unload1 still loaded, then "unload 1" with unload2
** gone. Libraries left for the process's exit would all still be loaded.
** Messages go straight to stderr, unbuffered.
*/

#define _GNU_SOURCE

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

#define STR(x) #x
#define XSTR(x) STR(x)

/* The other library's path: this one's with its number swapped. */
static char other[4096];

static void say (const char *s) {
  ssize_t r = write(2, s, strlen(s));
  (void)r;
}

static int gc (lua_State *L) {
  (void)L;
  say("gc " XSTR(N) "\n");
  return 0;
}

__attribute__((destructor)) static void unload (void) {
  void *h;
  if (other[0] == '\0') return;
  h = dlopen(other, RTLD_LAZY | RTLD_NOLOAD);
  say("unload " XSTR(N) ": the other library is ");
  say(h != NULL ? "still loaded\n" : "gone\n");
}

#define OPEN(n) OPEN_(n)
#define OPEN_(n) luaopen_unload##n

int OPEN(N) (lua_State *L) {
  const char *path = luaL_checkstring(L, 2);
  char *digit;
  size_t len = strlen(path);
  if (len < sizeof(other)) {
    memcpy(other, path, len + 1);
    digit = strstr(other, "unload" XSTR(N) ".so");
    if (digit != NULL) digit[6] = (N == 1) ? '2' : '1';
  }
  lua_newuserdatauv(L, 1, 0);
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, gc);
  lua_setfield(L, -2, "__gc");
  lua_setmetatable(L, -2);
  return 1;
}
