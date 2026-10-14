// Steam lobby + P2P session layer for the RE9 co-op mod.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace net {

enum class State { Idle, Creating, Joining, InLobby, Error };

struct Member {
    std::uint64_t id;
    std::string name;
};

struct Packet {
    std::uint64_t from;
    std::string data;
};

struct FriendLobby {
    std::uint64_t id;
    std::string name;
    std::uint64_t lobby; // 0 when the friend plays RE9 but isn't in a joinable lobby
};

struct Status {
    State state{State::Idle};
    std::uint64_t lobby{0};
    std::uint64_t owner{0};
    std::uint64_t me{0};
    bool is_host{false};
    bool loopback{false};
    bool steam{false};
    std::string error;
    std::vector<Member> members;
};

constexpr int kMaxChannels = 4;

// All functions are thread safe. Call tick() once per game frame.
bool init();                 // resolves steam_api64.dll; false if Steam isn't available
void tick();                 // polls call results, refreshes members, pumps loopback
void shutdown();

bool host(int max_members, int lobby_type); // 1 friends-only, 2 public (anyone with the ID)
bool join(std::uint64_t lobby);
void leave();
bool invite_overlay();
std::vector<FriendLobby> friends_in_game();

Status status();
std::string my_name();
std::uint64_t take_pending_join(); // lobby picked from a Steam invite / "Join game", 0 if none

// to == 0: every other lobby member. Returns how many peers it was queued for.
int send(const std::string& data, bool reliable, int channel, std::uint64_t to);
std::vector<Packet> recv(int channel, int max);

// One-PC testing: every send is also delivered back to ourselves after delay_ms,
// coming from the fake peer id kLoopbackPeer.
void set_loopback(bool enabled, int delay_ms);
constexpr std::uint64_t kLoopbackPeer = 1;

const char* state_name(State s);

} // namespace net
