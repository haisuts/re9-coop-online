/* Lua 5.4.3 (the one REFramework embeds) for checks outside the game.
   luacheck file.lua ...   syntax-check files
   luacheck --run test.lua  run a script (standard libraries only) */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(int argc, char** argv) {
    if (argc >= 3 && strcmp(argv[1], "--run") == 0) {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        int rc = luaL_dofile(L, argv[2]);
        if (rc != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return rc == LUA_OK ? 0 : 1;
    }
    int bad = 0;
    for (int i = 1; i < argc; ++i) {
        lua_State* L = luaL_newstate();
        if (luaL_loadfile(L, argv[i]) != LUA_OK) {
            fprintf(stderr, "%s\n", lua_tostring(L, -1));
            bad = 1;
        } else {
            printf("ok %s\n", argv[i]);
        }
        lua_close(L);
    }
    return bad;
}
