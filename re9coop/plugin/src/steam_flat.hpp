// Minimal declarations for the Steamworks flat API exported by the game's own steam_api64.dll.
// Written by hand for this mod (no SDK headers are shipped). Layouts follow the public
// Steamworks / GameNetworkingSockets documentation; Windows packs callback structs to 8.
#pragma once

#include <cstdint>

namespace steam {

using uint64 = std::uint64_t;
using int64 = std::int64_t;
using SteamAPICall_t = uint64;
using HSteamNetConnection = std::uint32_t;

constexpr SteamAPICall_t k_uAPICallInvalid = 0;

enum ELobbyType : int {
    k_ELobbyTypePrivate = 0,
    k_ELobbyTypeFriendsOnly = 1,
    k_ELobbyTypePublic = 2,
    k_ELobbyTypeInvisible = 3,
};

constexpr int k_EResultOK = 1;
constexpr std::uint32_t k_EChatRoomEnterResponseSuccess = 1;
constexpr int k_EFriendFlagImmediate = 0x04;

constexpr int k_nSteamNetworkingSend_Unreliable = 0;
constexpr int k_nSteamNetworkingSend_NoNagle = 1;
constexpr int k_nSteamNetworkingSend_Reliable = 8;
constexpr int k_nSteamNetworkingSend_AutoRestartBrokenSession = 32;

constexpr int k_ESteamNetworkingIdentityType_SteamID = 16;

#pragma pack(push, 1)
struct SteamNetworkingIdentity {
    int m_eType;
    int m_cbSize;
    union {
        uint64 m_steamID64;
        char m_raw[128];
    };

    void set_steam_id(uint64 id) {
        m_eType = k_ESteamNetworkingIdentityType_SteamID;
        m_cbSize = sizeof(m_steamID64);
        m_steamID64 = id;
    }
    uint64 steam_id() const { return m_eType == k_ESteamNetworkingIdentityType_SteamID ? m_steamID64 : 0; }
};
#pragma pack(pop)
static_assert(sizeof(SteamNetworkingIdentity) == 136);

#pragma pack(push, 8)
struct SteamNetworkingMessage_t {
    void* m_pData;
    int m_cbSize;
    HSteamNetConnection m_conn;
    SteamNetworkingIdentity m_identityPeer;
    int64 m_nConnUserData;
    int64 m_usecTimeReceived;
    int64 m_nMessageNumber;
    void (*m_pfnFreeData)(SteamNetworkingMessage_t*);
    void (*m_pfnRelease)(SteamNetworkingMessage_t*);
    int m_nChannel;
    int m_nFlags;
    int64 m_nUserData;
    std::uint16_t m_idxLane;
    std::uint16_t _pad1;
};

struct LobbyCreated_t {
    enum { k_iCallback = 513 };
    int m_eResult;
    uint64 m_ulSteamIDLobby;
};
static_assert(sizeof(LobbyCreated_t) == 16);

struct LobbyEnter_t {
    enum { k_iCallback = 504 };
    uint64 m_ulSteamIDLobby;
    std::uint32_t m_rgfChatPermissions;
    bool m_bLocked;
    std::uint32_t m_EChatRoomEnterResponse;
};
static_assert(sizeof(LobbyEnter_t) == 24);

struct GameLobbyJoinRequested_t {
    enum { k_iCallback = 333 };
    uint64 m_steamIDLobby;
    uint64 m_steamIDFriend;
};

struct GameRichPresenceJoinRequested_t {
    enum { k_iCallback = 337 };
    uint64 m_steamIDFriend;
    char m_rgchConnect[256];
};

struct FriendGameInfo_t {
    uint64 m_gameID;
    std::uint32_t m_unGameIP;
    std::uint16_t m_usGamePort;
    std::uint16_t m_usQueryPort;
    uint64 m_steamIDLobby;
};
static_assert(sizeof(FriendGameInfo_t) == 24);
#pragma pack(pop)

#pragma pack(push, 1)
struct SteamNetworkingMessagesSessionRequest_t {
    enum { k_iCallback = 1251 };
    SteamNetworkingIdentity m_identityRemote;
};
#pragma pack(pop)

// Same declaration order as the SDK's CCallbackBase so MSVC lays the vtable out identically
// (MSVC groups overloads in reverse order; declaring them the same way reproduces it).
class CCallbackBase {
public:
    CCallbackBase() : m_nCallbackFlags(0), m_iCallback(0) {}
    virtual void Run(void* pvParam) = 0;
    virtual void Run(void* pvParam, bool bIOFailure, SteamAPICall_t hSteamAPICall) = 0;
    int GetICallback() { return m_iCallback; }
    virtual int GetCallbackSizeBytes() = 0;

protected:
    std::uint8_t m_nCallbackFlags;
    int m_iCallback;
};

// Function pointer table resolved from steam_api64.dll at runtime.
struct Api {
    bool loaded{false};

    // accessors
    void* (*SteamMatchmaking)();
    void* (*SteamFriends)();
    void* (*SteamUser)();
    void* (*SteamUtils)();
    void* (*SteamNetworkingMessages)();
    void* (*SteamNetworkingUtils)();

    // callbacks
    void (*RegisterCallback)(CCallbackBase*, int);
    void (*UnregisterCallback)(CCallbackBase*);

    // ISteamMatchmaking
    SteamAPICall_t (*CreateLobby)(void*, ELobbyType, int);
    SteamAPICall_t (*JoinLobby)(void*, uint64);
    void (*LeaveLobby)(void*, uint64);
    int (*GetNumLobbyMembers)(void*, uint64);
    uint64 (*GetLobbyMemberByIndex)(void*, uint64, int);
    uint64 (*GetLobbyOwner)(void*, uint64);
    bool (*SetLobbyData)(void*, uint64, const char*, const char*);
    const char* (*GetLobbyData)(void*, uint64, const char*);
    bool (*SetLobbyJoinable)(void*, uint64, bool);
    bool (*InviteUserToLobby)(void*, uint64, uint64);

    // ISteamFriends
    const char* (*GetPersonaName)(void*);
    int (*GetFriendCount)(void*, int);
    uint64 (*GetFriendByIndex)(void*, int, int);
    const char* (*GetFriendPersonaName)(void*, uint64);
    bool (*GetFriendGamePlayed)(void*, uint64, FriendGameInfo_t*);
    void (*ActivateGameOverlayInviteDialog)(void*, uint64);
    bool (*SetRichPresence)(void*, const char*, const char*);

    // ISteamUser
    uint64 (*GetSteamID)(void*);

    // ISteamUtils
    bool (*IsAPICallCompleted)(void*, SteamAPICall_t, bool*);
    bool (*GetAPICallResult)(void*, SteamAPICall_t, void*, int, int, bool*);
    std::uint32_t (*GetAppID)(void*);

    // ISteamNetworkingMessages
    int (*SendMessageToUser)(void*, const SteamNetworkingIdentity*, const void*, std::uint32_t, int, int);
    int (*ReceiveMessagesOnChannel)(void*, int, SteamNetworkingMessage_t**, int);
    bool (*AcceptSessionWithUser)(void*, const SteamNetworkingIdentity*);
    bool (*CloseSessionWithUser)(void*, const SteamNetworkingIdentity*);
    void (*MessageRelease)(SteamNetworkingMessage_t*);

    // ISteamNetworkingUtils
    void (*InitRelayNetworkAccess)(void*);
    bool (*SetGlobalConfigValueInt32)(void*, int, std::int32_t); // optional (may be null)
};

constexpr int k_ESteamNetworkingConfig_SendBufferSize = 9;

// Resolves every pointer; returns false (and names the first missing export) if anything is absent.
bool load_api(Api& api, const char** missing);

} // namespace steam
