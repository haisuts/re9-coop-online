#include "net.hpp"
#include "steam_flat.hpp"

#include <winsock2.h>
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace steam {

template <typename T>
static bool get_proc(HMODULE mod, const char* name, T& out, const char** missing) {
    out = reinterpret_cast<T>(GetProcAddress(mod, name));
    if (out == nullptr && missing != nullptr && *missing == nullptr) {
        *missing = name;
    }
    return out != nullptr;
}

bool load_api(Api& a, const char** missing) {
    HMODULE m = GetModuleHandleA("steam_api64.dll");
    if (m == nullptr) {
        if (missing) *missing = "steam_api64.dll";
        return false;
    }
    bool ok = true;
    ok &= get_proc(m, "SteamAPI_SteamMatchmaking_v009", a.SteamMatchmaking, missing);
    ok &= get_proc(m, "SteamAPI_SteamFriends_v017", a.SteamFriends, missing);
    ok &= get_proc(m, "SteamAPI_SteamUser_v021", a.SteamUser, missing);
    ok &= get_proc(m, "SteamAPI_SteamUtils_v010", a.SteamUtils, missing);
    ok &= get_proc(m, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002", a.SteamNetworkingMessages, missing);
    ok &= get_proc(m, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004", a.SteamNetworkingUtils, missing);
    ok &= get_proc(m, "SteamAPI_RegisterCallback", a.RegisterCallback, missing);
    ok &= get_proc(m, "SteamAPI_UnregisterCallback", a.UnregisterCallback, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_CreateLobby", a.CreateLobby, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_JoinLobby", a.JoinLobby, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_LeaveLobby", a.LeaveLobby, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers", a.GetNumLobbyMembers, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex", a.GetLobbyMemberByIndex, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_GetLobbyOwner", a.GetLobbyOwner, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_SetLobbyData", a.SetLobbyData, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_GetLobbyData", a.GetLobbyData, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_SetLobbyJoinable", a.SetLobbyJoinable, missing);
    ok &= get_proc(m, "SteamAPI_ISteamMatchmaking_InviteUserToLobby", a.InviteUserToLobby, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_GetPersonaName", a.GetPersonaName, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_GetFriendCount", a.GetFriendCount, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_GetFriendByIndex", a.GetFriendByIndex, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_GetFriendPersonaName", a.GetFriendPersonaName, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_GetFriendGamePlayed", a.GetFriendGamePlayed, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog", a.ActivateGameOverlayInviteDialog, missing);
    ok &= get_proc(m, "SteamAPI_ISteamFriends_SetRichPresence", a.SetRichPresence, missing);
    ok &= get_proc(m, "SteamAPI_ISteamUser_GetSteamID", a.GetSteamID, missing);
    ok &= get_proc(m, "SteamAPI_ISteamUtils_IsAPICallCompleted", a.IsAPICallCompleted, missing);
    ok &= get_proc(m, "SteamAPI_ISteamUtils_GetAPICallResult", a.GetAPICallResult, missing);
    ok &= get_proc(m, "SteamAPI_ISteamUtils_GetAppID", a.GetAppID, missing);
    ok &= get_proc(m, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser", a.SendMessageToUser, missing);
    ok &= get_proc(m, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", a.ReceiveMessagesOnChannel, missing);
    ok &= get_proc(m, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", a.AcceptSessionWithUser, missing);
    ok &= get_proc(m, "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", a.CloseSessionWithUser, missing);
    ok &= get_proc(m, "SteamAPI_SteamNetworkingMessage_t_Release", a.MessageRelease, missing);
    ok &= get_proc(m, "SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", a.InitRelayNetworkAccess, missing);
    get_proc(m, "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32", a.SetGlobalConfigValueInt32, nullptr);
    a.loaded = ok;
    return ok;
}

} // namespace steam

namespace net {
namespace {

constexpr int kInternalChannel = 7;      // hellos / keepalives, never shown to Lua
constexpr const char* kLobbyTag = "re9coop";
constexpr const char* kProtocol = "1";   // bumped when the Lua wire format changes

enum class Pending { None, Create, Join };

struct LoopPacket {
    ULONGLONG due;
    int channel;
    std::string data;
};

std::recursive_mutex g_mx;
steam::Api g_api{};
bool g_inited{false};
Status g_st{};
Pending g_pending{Pending::None};
steam::SteamAPICall_t g_call{steam::k_uAPICallInvalid};
ULONGLONG g_next_refresh{0};
std::unordered_map<std::uint64_t, ULONGLONG> g_next_hello; // member -> next hello time
std::unordered_set<std::uint64_t> g_heard;                 // members we've received from
std::uint64_t g_pending_join{0};
int g_loop_delay{0};
std::deque<LoopPacket> g_loop;

// --- LAN test transport: two games on one PC (tools/stand.py), both on the same Steam account, so
// Steam can't connect them. With reframework/data/re9coop_bridge/lan.txt next to the game, the
// lobby is local: datagrams on 127.0.0.1 between the two ports named there, nothing goes to Steam.
// Datagram: [kind: 0 hello, 1 data, 2 a piece of a bigger message][channel][payload]; a hello's payload:
// [in lobby][hosting][name]; a piece's: [message id u32][index u16][count u16][part] (a sync-check
// answer is bigger than one datagram in some chapters).
constexpr std::uint64_t kLanLobby = 4242;
struct Lan {
    bool on{false};
    SOCKET sock{INVALID_SOCKET};
    sockaddr_in peer{};
    std::uint64_t me{0}, peer_id{0};
    std::string name{"me"}, peer_name{"partner"};
    ULONGLONG peer_seen{0}, next_hello{0};
    bool peer_in_lobby{false}, peer_hosting{false};
    std::deque<std::string> in[kMaxChannels];
    std::uint32_t next_id{1};
    struct Partial {
        int channel{0};
        std::uint16_t count{0}, got{0};
        std::vector<std::string> parts;
        ULONGLONG t{0};
    };
    std::unordered_map<std::uint32_t, Partial> partial;
};
Lan g_lan;
constexpr size_t kLanPiece = 60000;

bool lan_config() {
    char exe[MAX_PATH];
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string path(exe);
    path = path.substr(0, path.find_last_of("\\/") + 1) + "reframework\\data\\re9coop_bridge\\lan.txt";
    std::ifstream f(path);
    if (!f) return false;
    int port = 0, peer = 0;
    std::string line;
    while (std::getline(f, line)) {
        const auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        const auto k = line.substr(0, eq);
        auto v = line.substr(eq + 1);
        while (!v.empty() && (v.back() == '\r' || v.back() == ' ')) v.pop_back();
        if (k == "port") port = std::atoi(v.c_str());
        else if (k == "peer") peer = std::atoi(v.c_str());
        else if (k == "me") g_lan.me = std::strtoull(v.c_str(), nullptr, 10);
        else if (k == "peer_id") g_lan.peer_id = std::strtoull(v.c_str(), nullptr, 10);
        else if (k == "name") g_lan.name = v;
    }
    if (port <= 0 || peer <= 0 || g_lan.me == 0 || g_lan.peer_id == 0) return false;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
    g_lan.sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_lan.sock == INVALID_SOCKET) return false;
    int buf = 8 << 20;
    setsockopt(g_lan.sock, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&buf), sizeof(buf));
    setsockopt(g_lan.sock, SOL_SOCKET, SO_SNDBUF, reinterpret_cast<const char*>(&buf), sizeof(buf));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(static_cast<u_short>(port));
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(g_lan.sock, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
        closesocket(g_lan.sock);
        g_lan.sock = INVALID_SOCKET;
        return false;
    }
    u_long nb = 1;
    ioctlsocket(g_lan.sock, FIONBIO, &nb);
    g_lan.peer = a;
    g_lan.peer.sin_port = htons(static_cast<u_short>(peer));
    g_lan.on = true;
    return true;
}

void lan_send_raw(char kind, int channel, const char* data, size_t len) {
    std::string d;
    d.reserve(len + 2);
    d.push_back(kind);
    d.push_back(static_cast<char>(channel));
    d.append(data, len);
    sendto(g_lan.sock, d.data(), static_cast<int>(d.size()), 0, reinterpret_cast<const sockaddr*>(&g_lan.peer), sizeof(g_lan.peer));
}

bool lan_peer_member() {
    if (g_st.state != State::InLobby || !g_lan.peer_in_lobby) return false;
    if (GetTickCount64() - g_lan.peer_seen > 3000) return false;
    return g_lan.peer_hosting != g_st.is_host; // one host, one guest
}

void lan_pump() {
    static char buf[70000];
    for (;;) {
        const int n = recvfrom(g_lan.sock, buf, sizeof(buf), 0, nullptr, nullptr);
        if (n < 2) break;
        const int ch = static_cast<unsigned char>(buf[1]);
        if (buf[0] == 0 && n >= 4) {
            g_lan.peer_seen = GetTickCount64();
            g_lan.peer_in_lobby = buf[2] != 0;
            g_lan.peer_hosting = buf[3] != 0;
            g_lan.peer_name.assign(buf + 4, n - 4);
        } else if (buf[0] == 1 && ch < kMaxChannels && g_st.state == State::InLobby && g_lan.in[ch].size() < 4096) {
            g_lan.in[ch].emplace_back(buf + 2, n - 2);
        } else if (buf[0] == 2 && ch < kMaxChannels && g_st.state == State::InLobby && n >= 10) {
            std::uint32_t id;
            std::uint16_t index, count;
            std::memcpy(&id, buf + 2, 4);
            std::memcpy(&index, buf + 6, 2);
            std::memcpy(&count, buf + 8, 2);
            if (count == 0 || index >= count || count > 256) continue;
            auto& pt = g_lan.partial[id];
            if (pt.count == 0) {
                pt.channel = ch;
                pt.count = count;
                pt.parts.assign(count, std::string());
            }
            pt.t = GetTickCount64();
            if (pt.parts[index].empty()) {
                pt.parts[index].assign(buf + 10, n - 10);
                ++pt.got;
            }
            if (pt.got == pt.count) {
                std::string whole;
                for (auto& part : pt.parts) whole += part;
                if (g_lan.in[pt.channel].size() < 4096) g_lan.in[pt.channel].push_back(std::move(whole));
                g_lan.partial.erase(id);
            }
        }
    }
    // pieces of a message that never completed
    const auto now = GetTickCount64();
    for (auto it = g_lan.partial.begin(); it != g_lan.partial.end();) {
        if (now - it->second.t > 10000) it = g_lan.partial.erase(it);
        else ++it;
    }
}

void lan_send_big(int channel, const std::string& data) {
    const std::uint32_t id = g_lan.next_id++;
    const auto count = static_cast<std::uint16_t>((data.size() + kLanPiece - 1) / kLanPiece);
    for (std::uint16_t i = 0; i < count; ++i) {
        std::string piece(8, '\0');
        std::memcpy(&piece[0], &id, 4);
        std::memcpy(&piece[4], &i, 2);
        std::memcpy(&piece[6], &count, 2);
        piece.append(data, static_cast<size_t>(i) * kLanPiece, kLanPiece);
        lan_send_raw(2, channel, piece.data(), piece.size());
    }
}

void lan_tick() {
    lan_pump();
    const auto now = GetTickCount64();
    if (now >= g_lan.next_hello) {
        g_lan.next_hello = now + 500;
        std::string h;
        h.push_back(g_st.state == State::InLobby ? 1 : 0);
        h.push_back(g_st.is_host ? 1 : 0);
        h += g_lan.name;
        lan_send_raw(0, 0, h.data(), h.size());
    }
    if (g_st.state != State::InLobby) return;
    std::vector<Member> list{{g_lan.me, g_lan.name}};
    if (lan_peer_member()) list.push_back({g_lan.peer_id, g_lan.peer_name});
    g_st.members = std::move(list);
    g_st.owner = g_st.is_host ? g_lan.me : g_lan.peer_id;
}

void lan_enter(bool hosting) {
    g_st.state = State::InLobby;
    g_st.is_host = hosting;
    g_st.lobby = kLanLobby;
    g_st.error.clear();
    for (auto& q : g_lan.in) q.clear();
    lan_tick();
}

void* mm() { return g_api.SteamMatchmaking(); }
void* fr() { return g_api.SteamFriends(); }
void* ut() { return g_api.SteamUtils(); }
void* nm() { return g_api.SteamNetworkingMessages(); }

steam::SteamNetworkingIdentity ident(std::uint64_t id) {
    steam::SteamNetworkingIdentity i{};
    i.set_steam_id(id);
    return i;
}

bool is_member(std::uint64_t id) {
    for (auto& m : g_st.members) {
        if (m.id == id) return true;
    }
    return false;
}

void set_error(const std::string& e) {
    g_st.state = State::Error;
    g_st.error = e;
}

void clear_lobby() {
    if (g_api.loaded) {
        for (auto& m : g_st.members) {
            if (m.id != g_st.me) {
                auto i = ident(m.id);
                g_api.CloseSessionWithUser(nm(), &i);
            }
        }
        g_api.SetRichPresence(fr(), "connect", "");
    }
    g_st.lobby = 0;
    g_st.owner = 0;
    g_st.is_host = false;
    g_st.members.clear();
    g_next_hello.clear();
    g_heard.clear();
}

void refresh_members() {
    std::vector<Member> list;
    const int n = g_api.GetNumLobbyMembers(mm(), g_st.lobby);
    for (int i = 0; i < n; ++i) {
        const auto id = g_api.GetLobbyMemberByIndex(mm(), g_st.lobby, i);
        const char* name = g_api.GetFriendPersonaName(fr(), id);
        list.push_back({id, name ? name : ""});
    }
    g_st.owner = g_api.GetLobbyOwner(mm(), g_st.lobby);
    g_st.is_host = g_st.owner == g_st.me;
    // new members: open the session from our side (sending implicitly accepts theirs)
    for (auto& m : list) {
        if (m.id != g_st.me && g_next_hello.find(m.id) == g_next_hello.end()) {
            auto i = ident(m.id);
            g_api.AcceptSessionWithUser(nm(), &i);
            g_next_hello[m.id] = 0;
        }
    }
    for (auto it = g_next_hello.begin(); it != g_next_hello.end();) {
        const auto id = it->first;
        const bool still = std::any_of(list.begin(), list.end(), [id](const Member& m) { return m.id == id; });
        if (!still) {
            auto i = ident(id);
            g_api.CloseSessionWithUser(nm(), &i);
            g_heard.erase(id);
            it = g_next_hello.erase(it);
        } else {
            ++it;
        }
    }
    g_st.members = std::move(list);
}

void send_hellos(ULONGLONG now) {
    for (auto& [id, next] : g_next_hello) {
        if (now < next) continue;
        // keep saying hello until we've heard back, then every 5 s as a keepalive
        next = now + (g_heard.count(id) ? 5000 : 1000);
        auto i = ident(id);
        static const char hello[] = "re9coop-hello";
        g_api.SendMessageToUser(nm(), &i, hello, sizeof(hello) - 1,
            steam::k_nSteamNetworkingSend_Unreliable | steam::k_nSteamNetworkingSend_AutoRestartBrokenSession,
            kInternalChannel);
    }
}

void drain_internal() {
    steam::SteamNetworkingMessage_t* msgs[32];
    int n;
    while ((n = g_api.ReceiveMessagesOnChannel(nm(), kInternalChannel, msgs, 32)) > 0) {
        for (int i = 0; i < n; ++i) {
            g_heard.insert(msgs[i]->m_identityPeer.steam_id());
            g_api.MessageRelease(msgs[i]);
        }
    }
}

void poll_call() {
    if (g_call == steam::k_uAPICallInvalid) return;
    bool failed = false;
    if (!g_api.IsAPICallCompleted(ut(), g_call, &failed)) return;
    const auto call = g_call;
    const auto kind = g_pending;
    g_call = steam::k_uAPICallInvalid;
    g_pending = Pending::None;

    if (kind == Pending::Create) {
        steam::LobbyCreated_t r{};
        if (!g_api.GetAPICallResult(ut(), call, &r, sizeof(r), r.k_iCallback, &failed) || failed) {
            return set_error("lobby create: call failed");
        }
        if (r.m_eResult != steam::k_EResultOK) {
            return set_error("lobby create: EResult " + std::to_string(r.m_eResult));
        }
        g_st.lobby = r.m_ulSteamIDLobby;
        g_st.state = State::InLobby;
        g_api.SetLobbyData(mm(), g_st.lobby, kLobbyTag, kProtocol);
        char connect[64];
        std::snprintf(connect, sizeof(connect), "+connect_lobby %llu", (unsigned long long)g_st.lobby);
        g_api.SetRichPresence(fr(), "connect", connect);
        refresh_members();
    } else if (kind == Pending::Join) {
        steam::LobbyEnter_t r{};
        if (!g_api.GetAPICallResult(ut(), call, &r, sizeof(r), r.k_iCallback, &failed) || failed) {
            return set_error("lobby join: call failed");
        }
        if (r.m_EChatRoomEnterResponse != steam::k_EChatRoomEnterResponseSuccess) {
            return set_error("lobby join: response " + std::to_string(r.m_EChatRoomEnterResponse));
        }
        g_st.lobby = r.m_ulSteamIDLobby;
        const char* tag = g_api.GetLobbyData(mm(), g_st.lobby, kLobbyTag);
        if (tag == nullptr || std::strcmp(tag, kProtocol) != 0) {
            g_api.LeaveLobby(mm(), g_st.lobby);
            g_st.lobby = 0;
            return set_error(tag && *tag ? "host runs another mod version" : "not a RE9 co-op lobby");
        }
        g_st.state = State::InLobby;
        refresh_members();
    }
}

// --- Steam callbacks (only fire if the game dispatches callbacks the usual way) ---

template <typename T, void (*Fn)(T*)>
class Callback : public steam::CCallbackBase {
public:
    Callback() { m_iCallback = T::k_iCallback; }
    void Run(void* p) override { Fn(static_cast<T*>(p)); }
    void Run(void* p, bool, steam::SteamAPICall_t) override { Fn(static_cast<T*>(p)); }
    int GetCallbackSizeBytes() override { return sizeof(T); }
};

std::uint64_t parse_connect(const char* s) {
    const char* p = std::strstr(s, "+connect_lobby");
    if (p == nullptr) return 0;
    p += std::strlen("+connect_lobby");
    while (*p == ' ' || *p == '"') ++p;
    return std::strtoull(p, nullptr, 10);
}

void on_lobby_join_requested(steam::GameLobbyJoinRequested_t* p) {
    std::lock_guard _{g_mx};
    g_pending_join = p->m_steamIDLobby;
}

void on_rich_presence_join(steam::GameRichPresenceJoinRequested_t* p) {
    std::lock_guard _{g_mx};
    char buf[257]{};
    std::memcpy(buf, p->m_rgchConnect, 256);
    if (auto id = parse_connect(buf)) g_pending_join = id;
}

void on_session_request(steam::SteamNetworkingMessagesSessionRequest_t* p) {
    std::lock_guard _{g_mx};
    const auto id = p->m_identityRemote.steam_id();
    if (g_st.state == State::InLobby && is_member(id)) {
        g_api.AcceptSessionWithUser(nm(), &p->m_identityRemote);
    }
}

Callback<steam::GameLobbyJoinRequested_t, on_lobby_join_requested> g_cb_join;
Callback<steam::GameRichPresenceJoinRequested_t, on_rich_presence_join> g_cb_rp;
Callback<steam::SteamNetworkingMessagesSessionRequest_t, on_session_request> g_cb_session;

} // namespace

const char* state_name(State s) {
    switch (s) {
    case State::Idle: return "idle";
    case State::Creating: return "creating";
    case State::Joining: return "joining";
    case State::InLobby: return "in_lobby";
    case State::Error: return "error";
    }
    return "?";
}

bool init() {
    std::lock_guard _{g_mx};
    if (g_inited) return g_api.loaded || g_lan.on;
    if (lan_config()) {
        g_inited = true;
        g_st.steam = true;
        g_st.me = g_lan.me;
        g_st.error.clear();
        return true;
    }
    const char* missing = nullptr;
    if (!steam::load_api(g_api, &missing)) {
        // steam_api64.dll may not be initialised yet; try again on the next call
        g_st.error = std::string("steam api missing: ") + (missing ? missing : "?");
        return false;
    }
    if (g_api.SteamUser() == nullptr || nm() == nullptr) {
        g_api.loaded = false;
        g_st.error = "steam not initialised yet";
        return false;
    }
    g_inited = true;
    g_st.steam = true;
    g_st.me = g_api.GetSteamID(g_api.SteamUser());
    g_api.InitRelayNetworkAccess(g_api.SteamNetworkingUtils());
    // the host's world (~0.7 MB) goes out at once: room for it in the send queue (Steam's default 512 KB)
    if (g_api.SetGlobalConfigValueInt32) {
        g_api.SetGlobalConfigValueInt32(g_api.SteamNetworkingUtils(), steam::k_ESteamNetworkingConfig_SendBufferSize, 16 * 1024 * 1024);
    }
    g_api.RegisterCallback(&g_cb_join, g_cb_join.GetICallback());
    g_api.RegisterCallback(&g_cb_rp, g_cb_rp.GetICallback());
    g_api.RegisterCallback(&g_cb_session, g_cb_session.GetICallback());
    // launched by Steam from an invite while the game wasn't running
    g_pending_join = parse_connect(GetCommandLineA());
    g_st.error.clear();
    return true;
}

void shutdown() {
    std::lock_guard _{g_mx};
    if (!g_inited) return;
    leave();
    g_api.UnregisterCallback(&g_cb_join);
    g_api.UnregisterCallback(&g_cb_rp);
    g_api.UnregisterCallback(&g_cb_session);
    g_inited = false;
}

void tick() {
    std::lock_guard _{g_mx};
    if (!g_inited && !init()) return;
    if (g_lan.on) return lan_tick();
    poll_call();
    if (g_st.state != State::InLobby) return;
    const auto now = GetTickCount64();
    if (now >= g_next_refresh) {
        g_next_refresh = now + 500;
        refresh_members();
        if (!is_member(g_st.me)) { // kicked, or the lobby is gone
            clear_lobby();
            set_error("lost the lobby");
            return;
        }
    }
    drain_internal();
    send_hellos(now);
}

bool host(int max_members, int lobby_type) {
    std::lock_guard _{g_mx};
    if (!g_inited && !init()) return false;
    if (g_lan.on) {
        lan_enter(true);
        return true;
    }
    if (g_st.state == State::InLobby) leave();
    if (g_pending != Pending::None) return false;
    g_st.error.clear();
    const auto type = lobby_type == 2 ? steam::k_ELobbyTypePublic : steam::k_ELobbyTypeFriendsOnly;
    g_call = g_api.CreateLobby(mm(), type, std::clamp(max_members, 2, 4));
    if (g_call == steam::k_uAPICallInvalid) {
        set_error("CreateLobby refused");
        return false;
    }
    g_pending = Pending::Create;
    g_st.state = State::Creating;
    return true;
}

bool join(std::uint64_t lobby) {
    std::lock_guard _{g_mx};
    if (!g_inited && !init()) return false;
    if (lobby == 0) return false;
    if (g_lan.on) {
        lan_enter(false);
        return true;
    }
    if (g_st.state == State::InLobby) leave();
    if (g_pending != Pending::None) return false;
    g_st.error.clear();
    g_call = g_api.JoinLobby(mm(), lobby);
    if (g_call == steam::k_uAPICallInvalid) {
        set_error("JoinLobby refused");
        return false;
    }
    g_pending = Pending::Join;
    g_st.state = State::Joining;
    return true;
}

void leave() {
    std::lock_guard _{g_mx};
    if (!g_inited) return;
    if (g_lan.on) {
        g_st.state = State::Idle;
        g_st.is_host = false;
        g_st.lobby = g_st.owner = 0;
        g_st.members.clear();
        return;
    }
    if (g_st.lobby != 0) g_api.LeaveLobby(mm(), g_st.lobby);
    clear_lobby();
    g_call = steam::k_uAPICallInvalid;
    g_pending = Pending::None;
    g_st.state = State::Idle;
    g_st.error.clear();
}

bool invite_overlay() {
    std::lock_guard _{g_mx};
    if (!g_inited || g_st.state != State::InLobby || g_lan.on) return false;
    g_api.ActivateGameOverlayInviteDialog(fr(), g_st.lobby);
    return true;
}

std::vector<FriendLobby> friends_in_game() {
    std::lock_guard _{g_mx};
    std::vector<FriendLobby> out;
    if (!g_inited && !init()) return out;
    if (g_lan.on) {
        if (GetTickCount64() - g_lan.peer_seen < 3000) {
            out.push_back({g_lan.peer_id, g_lan.peer_name, g_lan.peer_in_lobby && g_lan.peer_hosting ? kLanLobby : 0});
        }
        return out;
    }
    const auto app = g_api.GetAppID(ut());
    const int n = g_api.GetFriendCount(fr(), steam::k_EFriendFlagImmediate);
    for (int i = 0; i < n; ++i) {
        const auto id = g_api.GetFriendByIndex(fr(), i, steam::k_EFriendFlagImmediate);
        steam::FriendGameInfo_t gi{};
        if (!g_api.GetFriendGamePlayed(fr(), id, &gi)) continue;
        if ((gi.m_gameID & 0xFFFFFF) != app) continue;
        const char* name = g_api.GetFriendPersonaName(fr(), id);
        out.push_back({id, name ? name : "", gi.m_steamIDLobby});
    }
    return out;
}

Status status() {
    std::lock_guard _{g_mx};
    if (!g_inited) init();
    return g_st;
}

std::string my_name() {
    std::lock_guard _{g_mx};
    if (!g_inited && !init()) return "";
    if (g_lan.on) return g_lan.name;
    const char* n = g_api.GetPersonaName(fr());
    return n ? n : "";
}

std::uint64_t take_pending_join() {
    std::lock_guard _{g_mx};
    const auto id = g_pending_join;
    g_pending_join = 0;
    return id;
}

int send(const std::string& data, bool reliable, int channel, std::uint64_t to) {
    std::lock_guard _{g_mx};
    if (channel < 0 || channel >= kMaxChannels) return 0;
    int count = 0;
    if (g_st.loopback && (to == 0 || to == kLoopbackPeer)) {
        g_loop.push_back({GetTickCount64() + (ULONGLONG)g_loop_delay, channel, data});
        ++count;
    }
    if (!g_inited || g_st.state != State::InLobby) return count;
    if (g_lan.on) {
        // one datagram each, or pieces for a bigger one (at most 256 x 60 KB)
        if (lan_peer_member() && (to == 0 || to == g_lan.peer_id)) {
            if (data.size() <= 65000) {
                lan_send_raw(1, channel, data.data(), data.size());
                ++count;
            } else if (data.size() <= kLanPiece * 256) {
                lan_send_big(channel, data);
                ++count;
            }
        }
        return count;
    }
    const int flags = (reliable ? steam::k_nSteamNetworkingSend_Reliable
                                : steam::k_nSteamNetworkingSend_Unreliable | steam::k_nSteamNetworkingSend_NoNagle)
        | steam::k_nSteamNetworkingSend_AutoRestartBrokenSession;
    for (auto& m : g_st.members) {
        if (m.id == g_st.me || (to != 0 && to != m.id)) continue;
        auto i = ident(m.id);
        if (g_api.SendMessageToUser(nm(), &i, data.data(), (std::uint32_t)data.size(), flags, channel) == steam::k_EResultOK) {
            ++count;
        } else {
            ++g_st.send_fail;
        }
    }
    return count;
}

std::vector<Packet> recv(int channel, int max) {
    std::lock_guard _{g_mx};
    std::vector<Packet> out;
    if (channel < 0 || channel >= kMaxChannels) return out;
    const auto now = GetTickCount64();
    for (auto it = g_loop.begin(); it != g_loop.end() && (int)out.size() < max;) {
        if (it->channel == channel && it->due <= now) {
            out.push_back({kLoopbackPeer, std::move(it->data)});
            it = g_loop.erase(it);
        } else {
            ++it;
        }
    }
    if (!g_inited || g_st.state != State::InLobby) return out;
    if (g_lan.on) {
        lan_pump();
        auto& q = g_lan.in[channel];
        while (!q.empty() && (int)out.size() < max) {
            out.push_back({g_lan.peer_id, std::move(q.front())});
            q.pop_front();
        }
        return out;
    }
    steam::SteamNetworkingMessage_t* msgs[64];
    while ((int)out.size() < max) {
        const int want = std::min(64, max - (int)out.size());
        const int n = g_api.ReceiveMessagesOnChannel(nm(), channel, msgs, want);
        if (n <= 0) break;
        for (int i = 0; i < n; ++i) {
            const auto from = msgs[i]->m_identityPeer.steam_id();
            if (is_member(from)) { // never accept data from anyone outside our lobby
                g_heard.insert(from);
                out.push_back({from, std::string(static_cast<const char*>(msgs[i]->m_pData), msgs[i]->m_cbSize)});
            }
            g_api.MessageRelease(msgs[i]);
        }
    }
    return out;
}

void set_loopback(bool enabled, int delay_ms) {
    std::lock_guard _{g_mx};
    g_st.loopback = enabled;
    g_loop_delay = std::max(0, delay_ms);
    if (!enabled) g_loop.clear();
}

} // namespace net
