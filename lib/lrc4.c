#include <stdint.h>

#include "lua.h"
#include "lauxlib.h"

#include "rc4.h"

#define RC4_METATABLE "rc4_metatable"
#define RC4_BUFSIZE (4079)  /* after wrap in lua string, is 4096 */

static int
lrc4(lua_State * L) {
  size_t len;
  const char * key = luaL_checklstring(L, 1, &len);

  struct rc4_state * rc4 = (struct rc4_state *)lua_newuserdata(L, sizeof(*rc4));
  luaL_getmetatable(L, RC4_METATABLE);
  lua_setmetatable(L, -2);

  rc4_init(rc4, (uint8_t*)key, len);

  return 1;
}

static int
lcrypt(lua_State * L) {
  uint8_t buf[RC4_BUFSIZE];
  struct rc4_state * rc4 = (struct rc4_state *)luaL_checkudata(L, 1, RC4_METATABLE);

  size_t len;
  const char * data = luaL_checklstring(L, 2, &len);

  int n = 0;
  size_t offset = 0;
  for(offset = 0; offset < len; ++n) {
    size_t sz = len - offset;
    sz = (sz <= RC4_BUFSIZE) ? sz : RC4_BUFSIZE;
    rc4_crypt(rc4, (const uint8_t*)data+offset, buf, sz);
    offset += sz;
    lua_pushlstring(L, (const char*)&buf[0], sz);
  }
  lua_concat(L, n);
  return 1;
}

int
luaopen_rc4_c(lua_State *L) {
  luaL_checkversion(L);

  if(luaL_newmetatable(L, RC4_METATABLE)) {
    luaL_Reg rc4_mt[] = {
      { "crypt", lcrypt },
      { NULL, NULL },
    };
    luaL_newlib(L,rc4_mt);
    lua_setfield(L, -2, "__index");
  }
  lua_pop(L, 1);

  luaL_Reg l[] = {
    { "rc4", lrc4 },
    { NULL, NULL },
  };
  luaL_newlib(L, l);

  lua_pushinteger(L, 2);
  lua_setfield(L, -2, "VERSION");

  return 1;
}

