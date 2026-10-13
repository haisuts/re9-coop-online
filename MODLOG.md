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

## Engine facts found live (2026-10-13, REFramework nightly 01432 d052e8fd, TDB 83)

- REFramework monolithic build (one `dinput8.dll` for all RE Engine games) works on the 2026-07-01 game
  patch. Lua API has no `sdk.get_tdb()` / `get_managed_singletons()`: the plugin exposes
  `re9coop_net.dev_dump_types()` / `dev_singletons()` (178,177 types dumped to `_deps/re9_types.txt`).
- Singletons: `app.CharacterManager` (players/enemies/NPC contexts), `app.MainGameFlowManager`,
  `app.CameraSystem`, `app.InventoryManager`, `app.PrefabInstantiateManager`, `app.LevelFlowManager`...
- Player: `CharacterManager:get_PlayerContextFast()` -> `app.PlayerContext` (parent `app.CharacterContext`):
  `get_GameObject()`, `get_Position()`, `get_Rotation()`, `get_KindID()` (ToString "cp_A100"),
  `get_IsFPSCharacter()`, `get_Common()` (IsRun/IsCrouch/IsShooting/EquipWeaponID...).
  Grace = `cp_A100`, model `ch0200`; Leon = `cp_A000` (model presumably `ch0100`); `cp_A200` exists too.
- Characters are NOT runtime prefabs: they live in per-chapter pool scenes
  (`MainGame/<Chap>/<Chap>_CharacterPool`, file `gameassets/character/scene/<chap>/<chap>_characterpool.scn`).
  `MainGame` holds a folder per chapter (Chap1_00 ... Chap5_05, FF_01/02); only the current one is active.
- Look = "montage" parts: child GameObjects `01 02 09 10 14 21 40 50` with meshes
  `Character/ch/ch02/0200/<slot>/00/ch0200_<slot>_00.mesh` + `.mdf2`; part prefabs
  `character/ch/ch02/0200/<slot>/ch0200_<slot>_000.pfb` (each has JointConstraints + ChildSecondary).
- Skeleton: root has `via.motion.DummySkeleton` with `Character/ch/ch02/ch02.refskel` -> 68 joints
  (`root, C_Prop_Root_A, Hip, R_Leg_Upper ...`). Part meshes carry extra helper joints that their
  JointConstraints derive from the parent's 68.
- **via.Prefab in RE9 is not a ResourceHolder** (parent System.Object), so REFramework's
  `create_holder('via.Prefab')` returns nil. Working recipe: `sdk.create_instance('via.Prefab', true)`,
  write `+0x10` = `sdk.create_resource('via.PrefabResource', path)` address, `+0x18` = managed string of
  the path, `+0x20` = 1; then `set_Standby(true)`, wait `get_Ready()`, `instantiate(via.vec3)`.
  `get_Exist()` = file is in the pak (path case doesn't matter); bogus paths give false.
- Puppet recipe (verified on screen): `via.GameObject.create(name)` + `createComponent(DummySkeleton)`
  with `create_resource('via.motion.SkeletonResource', refskel):create_holder('via.motion.SkeletonResourceHolder')`
  -> 68 joints; instantiate the 8 part prefabs and `setParent(via.Transform, System.Boolean)` them under
  it; writing the root's joint local rotations poses the whole body (0.3 ms for 68 joints in Lua).
  GOTCHA: `obj:call('nonexistent signature', ...)` silently returns nil; `set_Parent(Transform, Bool)`
  does not exist (use `setParent` or `set_Parent(Transform)`).
- Time: `via.Application.get_UpTimeSecond` via `sdk.call_native_func`.
- Pak: KPKA v4.2, feature flags 0x28 (encrypted TOC). Not unpacked; path list from
  Ekey/REE.PAK.Tool `Projects/RE9_STM_Release.list` (incomplete: no player .pfb inside).

## Crash log

- 2026-10-13 20:37:26 — c0000005 in a worker thread (stack near `HashSet<via.motion.JointConstraints>`),
  3.4 s after REFramework "Reset scripts". The dev bridge state held hand-built `via.Prefab`s that had
  been put on standby (`set_Standby(true)`); resetting the Lua state released them. Working theory: the
  loader keeps raw pointers to standby prefabs -> use after free. Fix: prefabs that go on standby are
  cached per path and held with `add_ref_permanent` (never freed); prefabs only used for `get_Exist()`
  stay collectable (240 of those were freed earlier without trouble). Don't use "Reset scripts" while
  testing; restart the game instead. After a crash the game recompiles shaders (~2-3 min).

## Automation notes (1920x1080 borderless)

- Title: Enter -> "Основной сюжет" -> Enter = "Продолжить" (loads last save, ~20 s).
- REFramework menu: Insert. ScriptRunner header (150, 492); "Reset scripts" (178, 518) — avoid.
- Dev bridge: `python tools/bridge.py "<lua>"` (runs on UpdateBehavior, globals in `dev`).

## Next steps
- [ ] Confirm REFramework build works on the current game version (or update to nightly).
- [ ] Live recon in game: player manager singleton, player GameObject, prefab path, motion/anim.
- [ ] Vertical slice: local loopback puppet (own pose echoed back with an offset).
