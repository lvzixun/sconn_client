#include <stdint.h>
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"

#include "rc4.h"

#include <stdlib.h>

#define RC4_METATABLE "rc4_metatable"
#define RC4_BUFSIZE (4096)  /* after wrap in lua string, is 4096 */

static int
lrc4(lua_State * L) {
  size_t len;
  const char * key = luaL_checklstring(L, 1, &len);

  struct rc4_state * rc4 = (struct rc4_state *)lua_newuserdata(L, sizeof(*rc4));
  lua_pushvalue(L, 1);
  lua_setuservalue(L, -2);

  luaL_getmetatable(L, RC4_METATABLE);
  lua_setmetatable(L, -2);

  librc4_init(rc4, (uint8_t*)key, (int)len);

  return 1;
}

static int
lreset(lua_State* L) {
  size_t len;
  struct rc4_state * rc4 = (struct rc4_state *)luaL_checkudata(L, 1, RC4_METATABLE);
  lua_getuservalue(L, 1);
  const char* key = luaL_checklstring(L, -1, &len);
  librc4_init(rc4, (uint8_t*)key, (int)len);
  return 0;
}


static int
lcrypt(lua_State * L) {
  struct rc4_state * rc4 = (struct rc4_state *)luaL_checkudata(L, 1, RC4_METATABLE);

  size_t len;
  const char * data = luaL_checklstring(L, 2, &len);

  uint8_t *buffer = (uint8_t *)malloc(len);
  if(buffer) {
    librc4_crypt(rc4, (const uint8_t*)data, buffer, (int)len);
    lua_pushlstring(L, (const char*)buffer, len);
    free(buffer);
    return 1;
  }

  return 0;
}

int
luaopen_rc4_c(lua_State *L) {
  luaL_checkversion(L);

  if(luaL_newmetatable(L, RC4_METATABLE)) {
    luaL_Reg rc4_mt[] = {
      { "crypt", lcrypt },
      { "reset", lreset},
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

