// re9coop_net.dll: REFramework plugin that gives the RE9 co-op Lua script Steam lobbies and P2P
// messaging through the game's own steam_api64.dll.
//
// Lua: a global table `re9coop_net` (see register_lua). Every function returns plain values and
// never raises a Lua error (our Lua copy and REFramework's must not unwind each other's frames).

#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include "reframework/API.h"

#include "net.hpp"

#define RE9COOP_NET_VERSION "0.3.1"

namespace {

const REFrameworkPluginInitializeParam* g_param = nullptr;

std::string id_str(std::uint64_t id) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%llu", (unsigned long long)id);
    return buf;
}

std::uint64_t arg_id(lua_State* L, int idx) {
    if (lua_type(L, idx) == LUA_TNUMBER) {
        int isnum = 0;
        auto v = lua_tointegerx(L, idx, &isnum);
        return isnum ? (std::uint64_t)v : 0;
    }
    if (lua_type(L, idx) == LUA_TSTRING) {
        return std::strtoull(lua_tostring(L, idx), nullptr, 10);
    }
    return 0;
}

int arg_int(lua_State* L, int idx, int def) {
    int isnum = 0;
    auto v = lua_tointegerx(L, idx, &isnum);
    return isnum ? (int)v : def;
}

void set_str(lua_State* L, const char* k, const std::string& v) {
    lua_pushlstring(L, v.data(), v.size());
    lua_setfield(L, -2, k);
}

void set_bool(lua_State* L, const char* k, bool v) {
    lua_pushboolean(L, v);
    lua_setfield(L, -2, k);
}

int l_version(lua_State* L) {
    lua_pushstring(L, RE9COOP_NET_VERSION);
    return 1;
}

int l_available(lua_State* L) {
    lua_pushboolean(L, net::init());
    return 1;
}

int l_my_name(lua_State* L) {
    const auto n = net::my_name();
    lua_pushlstring(L, n.data(), n.size());
    return 1;
}

int l_host(lua_State* L) {
    lua_pushboolean(L, net::host(arg_int(L, 1, 2), arg_int(L, 2, 1)));
    return 1;
}

int l_join(lua_State* L) {
    lua_pushboolean(L, net::join(arg_id(L, 1)));
    return 1;
}

int l_leave(lua_State*) {
    net::leave();
    return 0;
}

int l_invite(lua_State* L) {
    lua_pushboolean(L, net::invite_overlay());
    return 1;
}

int l_friends(lua_State* L) {
    const auto list = net::friends_in_game();
    lua_createtable(L, (int)list.size(), 0);
    int i = 0;
    for (auto& f : list) {
        lua_createtable(L, 0, 3);
        set_str(L, "id", id_str(f.id));
        set_str(L, "name", f.name);
        set_str(L, "lobby", f.lobby ? id_str(f.lobby) : "");
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}

int l_status(lua_State* L) {
    const auto s = net::status();
    lua_createtable(L, 0, 10);
    set_str(L, "state", net::state_name(s.state));
    set_str(L, "lobby", s.lobby ? id_str(s.lobby) : "");
    set_str(L, "owner", s.owner ? id_str(s.owner) : "");
    set_str(L, "me", s.me ? id_str(s.me) : "");
    set_bool(L, "is_host", s.is_host);
    set_bool(L, "loopback", s.loopback);
    set_bool(L, "steam", s.steam);
    set_str(L, "error", s.error);
    lua_createtable(L, (int)s.members.size(), 0);
    int i = 0;
    for (auto& m : s.members) {
        lua_createtable(L, 0, 2);
        set_str(L, "id", id_str(m.id));
        set_str(L, "name", m.name);
        lua_rawseti(L, -2, ++i);
    }
    lua_setfield(L, -2, "members");
    return 1;
}

// send(data, reliable, channel, to)
int l_send(lua_State* L) {
    size_t len = 0;
    const char* data = lua_tolstring(L, 1, &len);
    if (data == nullptr) {
        lua_pushinteger(L, 0);
        return 1;
    }
    const bool reliable = lua_toboolean(L, 2);
    const int channel = arg_int(L, 3, 0);
    const auto to = arg_id(L, 4);
    lua_pushinteger(L, net::send(std::string(data, len), reliable, channel, to));
    return 1;
}

// recv(channel, max) -> { {from=..., data=...}, ... }
int l_recv(lua_State* L) {
    const auto list = net::recv(arg_int(L, 1, 0), arg_int(L, 2, 256));
    lua_createtable(L, (int)list.size(), 0);
    int i = 0;
    for (auto& p : list) {
        lua_createtable(L, 0, 2);
        set_str(L, "from", id_str(p.from));
        set_str(L, "data", p.data);
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}

int l_set_loopback(lua_State* L) {
    net::set_loopback(lua_toboolean(L, 1), arg_int(L, 2, 0));
    return 0;
}

int l_pending_join(lua_State* L) {
    const auto id = net::take_pending_join();
    if (id == 0) {
        lua_pushnil(L);
    } else {
        const auto s = id_str(id);
        lua_pushlstring(L, s.data(), s.size());
    }
    return 1;
}

// --- dev helpers: the Lua API has no way to enumerate the type database ---

std::string type_name(const REFrameworkTDBTypeDefinition* td, REFrameworkTypeDefinitionHandle t) {
    char buf[1024];
    unsigned int len = 0;
    if (t == nullptr || td->get_full_name(t, buf, sizeof(buf), &len) != REFRAMEWORK_ERROR_NONE) return "";
    return std::string(buf, len);
}

// dev_dump_types(relative_path_under_reframework_data) -> count or nil
int l_dev_dump_types(lua_State* L) {
    const char* rel = lua_tostring(L, 1);
    if (g_param == nullptr || rel == nullptr || std::string(rel).find("..") != std::string::npos) {
        lua_pushnil(L);
        return 1;
    }
    const auto sdk = g_param->sdk;
    auto tdb = sdk->functions->get_tdb();
    const auto n = sdk->tdb->get_num_types(tdb);
    char exe[MAX_PATH];
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    const auto path = std::filesystem::path(exe).parent_path() / "reframework" / "data" / rel;
    std::filesystem::create_directories(path.parent_path());
    std::ofstream f(path);
    unsigned int count = 0;
    for (unsigned int i = 0; i < n; ++i) {
        const auto name = type_name(sdk->type_definition, sdk->tdb->get_type(tdb, i));
        if (!name.empty()) {
            f << name << '\n';
            ++count;
        }
    }
    lua_pushinteger(L, count);
    return 1;
}

int l_dev_singletons(lua_State* L) {
    lua_newtable(L);
    if (g_param == nullptr) return 1;
    const auto sdk = g_param->sdk;
    std::vector<REFrameworkManagedSingleton> buf(4096);
    unsigned int count = 0;
    if (sdk->functions->get_managed_singletons(buf.data(), (unsigned int)(buf.size() * sizeof(buf[0])), &count)
        != REFRAMEWORK_ERROR_NONE) {
        return 1;
    }
    for (unsigned int i = 0; i < count; ++i) {
        const auto name = type_name(sdk->type_definition, buf[i].t);
        lua_pushlstring(L, name.data(), name.size());
        lua_rawseti(L, -2, (lua_Integer)i + 1);
    }
    return 1;
}

void register_lua(lua_State* L) {
    static const luaL_Reg fns[] = {
        {"version", l_version},
        {"available", l_available},
        {"my_name", l_my_name},
        {"host", l_host},
        {"join", l_join},
        {"leave", l_leave},
        {"invite", l_invite},
        {"friends", l_friends},
        {"status", l_status},
        {"send", l_send},
        {"recv", l_recv},
        {"set_loopback", l_set_loopback},
        {"pending_join", l_pending_join},
        {"dev_dump_types", l_dev_dump_types},
        {"dev_singletons", l_dev_singletons},
        {nullptr, nullptr},
    };
    lua_createtable(L, 0, (int)(sizeof(fns) / sizeof(fns[0])));
    for (const luaL_Reg* r = fns; r->name != nullptr; ++r) {
        lua_pushcclosure(L, r->func, 0);
        lua_setfield(L, -2, r->name);
    }
    lua_setglobal(L, "re9coop_net");
}

void on_lua_state_created(lua_State* L) {
    g_param->functions->lock_lua();
    register_lua(L);
    g_param->functions->unlock_lua();
}

void on_lua_state_destroyed(lua_State*) {}

void on_update() {
    net::tick();
}

} // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
    version->game_name = "RE9";
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    g_param = param;
    const auto fns = param->functions;
    fns->on_lua_state_created(on_lua_state_created);
    fns->on_lua_state_destroyed(on_lua_state_destroyed);
    fns->on_pre_application_entry("UpdateBehavior", on_update);
    fns->log_info("[re9coop_net] %s loaded", RE9COOP_NET_VERSION);
    return true;
}
