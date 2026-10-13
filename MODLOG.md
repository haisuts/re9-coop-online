# MODLOG — RE Requiem online co-op (Steam)

Goal: online co-op for Resident Evil Requiem (RE9) over Steam (lobby + P2P), inspired by
"RE2 Co-op: HUNK" v1.4.8 (Nexus residentevil22019/2938, local couch co-op).

## Recon (2026-10-13)

- Game: Resident Evil Requiem, Steam app 3764200, buildid 23634047
  - Path: `E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem`
  - Exe: `re9.exe` (x64, 587 MB, updated 2026-07-01, patch_005)
  - Engine: Capcom RE Engine. Anti-cheat: none found by `um scan`. Owner SteamID in manifest.
- REFramework already installed: `dinput8.dll`, commit 1904b553 (v1.5.9.1 +427, built 2026-03-05).
  - Built BEFORE the 2026-07-01 game patch -> may need the current nightly. Last game run: 2026-03-05.
  - Log file is `re2_framework_log.txt` (sic), config `re2_fw_config.txt`.
  - `Enums_Internal.hpp` (enum dump) is in the game folder: namespaces `app::PlayerDefine`,
    `app::character`, `app::Inventory`, `app::CameraDefine`, enemies `app::cp_*` / `app::Cp_*Define`.
  - autorun already holds REFramework's stock VR scripts (re2_*, re4_*, re8_vr.lua).
- `steam_api64.dll` (game's own) flat API exports, used by our plugin:
  - `SteamAPI_SteamMatchmaking_v009`, `SteamAPI_SteamFriends_v017`, `SteamAPI_SteamUser_v021`,
    `SteamAPI_SteamUtils_v010`, `SteamAPI_SteamNetworkingMessages_SteamAPI_v002`,
    `SteamAPI_SteamNetworkingUtils_SteamAPI_v004`, plus `SteamAPI_ISteam*_*` methods.

## Reference mod: RE2 Co-op HUNK 1.4.8 (studied, NOT copied — no reuse permission)

- Files: `reframework/autorun/re2coop_main.lua` (23k lines, 1.25 MB), `plugins/re2coop_pads.dll`
  (extra pads), a font. Extracted to scratchpad only.
- Technique: spawns P2 from a player prefab (`ObjectRoot/Prefab/Character/Player/pl4000.pfb`) with
  `via.Prefab` + instantiate; tags player/weapon component update methods by owner and answers
  P2's input queries from pad 2 (static InputSystem reads the "active" pad).
- RE2 types: `app.ropeway.PlayerManager`, `app.ropeway.InputSystem`, `app.ropeway.EnemyManager`,
  `app.ropeway.gamemastering.MainFlowManager`, `via.SceneManager`.

## Route (chosen)

REFramework Lua (game logic: puppet, sync) + native REFramework plugin `re9coop_net.dll`
(Steam lobby + ISteamNetworkingMessages via the game's own steam_api64.dll flat API, exposed to
Lua). No callbacks registered with Steam: call results are polled with
`ISteamUtils::GetAPICallResult`; sessions are accepted implicitly by sending first.
Reason: REFramework is the community loader for RE Engine; Lua can't open sockets, a plugin can.

## Next steps
- [ ] Confirm REFramework build works on the current game version (or update to nightly).
- [ ] Live recon in game: player manager singleton, player GameObject, prefab path, motion/anim.
- [ ] Vertical slice: local loopback puppet (own pose echoed back with an offset).
