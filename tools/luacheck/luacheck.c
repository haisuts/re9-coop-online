/* Lua 5.4.3 (the one REFramework embeds) for checks outside the game.
   luacheck file.lua ...       syntax-check files
   luacheck --run test.lua     run a script (standard libraries only)
   luacheck --globals file.lua every global read / write, from the compiled code: "line get|set name" */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h"
#include "lstate.h"
#include "lopcodes.h"
#include "ldebug.h"

/* globals are table accesses on the _ENV upvalue: GETTABUP / SETTABUP with a string constant key */
static void list_globals(const Proto* f) {
    for (int pc = 0; pc < f->sizecode; ++pc) {
        Instruction i = f->code[pc];
        OpCode op = GET_OPCODE(i);
        int up, k, set;
        if (op == OP_GETTABUP) { up = GETARG_B(i); k = GETARG_C(i); set = 0; }
        else if (op == OP_SETTABUP) { up = GETARG_A(i); k = GETARG_B(i); set = 1; }
        else continue;
        TString* name = f->upvalues[up].name;
        if (name == NULL || strcmp(getstr(name), "_ENV") != 0 || !ttisstring(&f->k[k])) continue;
        printf("%d %s %s\n", luaG_getfuncline(f, pc), set ? "set" : "get", getstr(tsvalue(&f->k[k])));
    }
    for (int j = 0; j < f->sizep; ++j) list_globals(f->p[j]);
}

int main(int argc, char** argv) {
    if (argc >= 3 && strcmp(argv[1], "--globals") == 0) {
        lua_State* L = luaL_newstate();
        if (luaL_loadfile(L, argv[2]) != LUA_OK) {
            fprintf(stderr, "%s\n", lua_tostring(L, -1));
            return 1;
        }
        list_globals(clLvalue(s2v(L->top - 1))->p);
        lua_close(L);
        return 0;
    }
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
