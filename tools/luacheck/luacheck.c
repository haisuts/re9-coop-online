/* Syntax-checks Lua files with the same Lua 5.4.3 REFramework embeds. Usage: luacheck file.lua ... */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"

int main(int argc, char** argv) {
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
