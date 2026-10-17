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

- 2026-10-13 20:52:46 — APPCRASH c0000005 at re9.exe+0xcde323 (no REFramework dump), ~2 s after
  calling the local weapon's `app.EPVExpertMuzzleFlashCustom:play(puppetWeaponGO, nil)`; the puppet weapon
  is a bare GameObject (Transform + Mesh). Never hand game effect components a foreign GameObject.

- 2026-10-13 21:01:54 — c0000005 in `app.ShellManager.setupShell` ~1 s after calling
  `ShellGenerater.requestShellInstance(vec3, Quaternion, info)` with `getShellRequestInfo()`'s default
  object (Owner/GenerateOwner set by us, MultiStatus nil). Don't fake bullets.
- 2026-10-13 ~20:57 — not a crash, a game over: zombie spawned with drivers "disabled" through
  `set_Enabled` (doesn't exist on drivers: they're `app.CharacterDriver`, switch is `set_IsEnable`)
  grabbed and killed Grace. Game over -> Continue restores the last save (ammo etc.).

## Enemy recon (Chap3_02)

- `CharacterManager:get_EnemyContextList()` -> 40 `app.EnemyContext` per chapter, spawned or not.
  ID = `app.ContextID` wrapping a `System.Guid` from the scene data (same on both PCs).
  `get_KindID()` (cp_B000 zombie, cp_B001..7, cp_C100...), `get_IsSpawn()`, `get_IsDead()`,
  `get_HitPoint()` (`get_CurrentHitPoint`, `addDamageHitPoint(int, bool, bool)`), `get_GameObject()`.
- Spawn control (scene component, e.g. `app.Cp_B000SpawnParam` : `app.CharacterSpawnParamBase`) from
  `CharacterManager:getSpawnDataRef(id):get_SpawnControl()`: `requestSpawn()`, `requestSuspend()`,
  `requestKill()`, `requestResume()`, `getSpawnInstance()` -> GameObject. Verified spawn + kill.
- AI off: `ctx:get_CharacterUpdaterBase():get_ThinkDriver():set_IsEnable(false)` (+ LockOnTargetDriver).
  Zombie then stands still (0 drift over 4 s). Keep AttackDamageDriver on (it also takes damage).
  A freshly spawned enemy stays `DrawSelf=false` if AI is off from frame 1: set it true.
- `GameObject:set_UpdateSelf(false)` freezes an enemy completely; writing joint local rotations then
  poses it (zombie mirrored Grace: 64 of its 78 joints share player joint names). But a frozen enemy
  takes NO hits (no damage calls at all).
- `CharacterManager:requestWarp(id, Nullable<vec3>, Nullable<Quaternion>)` with plain vec3/quat from
  Lua -> enemy flung to ~1e27. Set the Transform position directly instead.
- Damage pipeline: `app.HitController.requestDamage(attackerHC, u32 hash, DamageUserData, string, vec3,
  WeaponID[, HC])`, `callbackDamageCalc(DamageInfo)`, `app.HitPoint.addDamageHitPoint(int, bool, bool)`.
- **Verified client-puppet recipe (21:08-21:12):**
  1. `spawnControl:requestSpawn()`; wait until `getSpawnInstance()` exists AND `get_HasCompletedSpawn()`
     AND `go:get_UpdateSelf()` (3-4 frames). Turning AI off earlier blocks spawn completion (the enemy
     stays asleep at its spawn point, and the spawn later overwrites our position/draw).
  2. AI off: updater `get_ThinkDriver()` + `get_LockOnTargetDriver()` `:set_IsEnable(false)`. Keep
     AttackDamageDriver ON. `app.CharacterOutOfAreaDriver` (component) `set_IsEnable(false)` and force
     `set_UpdateSelf(true)` / `set_DrawSelf(true)` every frame, or a far enemy falls asleep again.
  3. Move with `CharacterManager:requestWarp(id, Nullable<vec3>, Nullable<Quaternion>)` built by hand:
     `ValueType.new(System.Nullable`1<via.vec3>)`, byte 0 = 1, value floats at +16 (quat x,y,z,w at
     +16..+28). Plain Transform:set_Position is undone by the CharacterController; PostureData is
     rewritten from the transform; CharacterController:warp() didn't help on a corpse.
  4. Pose: write joint local rotations in `re.on_application_entry("LateUpdateBehavior")` (after the
     enemy's own Motion) — sticks while its idle animation runs.
  5. Client hits register on such an enemy: one revolver round -> `HitPoint:addDamageHitPoint(1579, false,
     true)` + `addDamageReactionHP(900)` on that enemy's HitPoint (address matches ctx:get_HitPoint()),
     HP 580 -> 0, dead. No requestDamage/callbackDamageCalc in that path. So: pre-hook these two on
     puppet HitPoints, forward to host, SKIP_ORIGINAL.
- Testing ammo: this save has 1 revolver round (arm0400 is the revolver). Pause menu "Перезапустить" ->
  Up -> Enter restores it (~20 s).

## Shot recon (pistol arm0400, Grace, Chap3_02)

- One shot = `EPVExpertMuzzleFlashCustom.play(GO, Nullable<int>)` once on `arm0400`, plus
  `soundlib.SoundContainer.trigger(u32 id, GO a, GO b, u32, bool, u32, CallbackType, 4x Action)` calls:
  shot-only ids on arm0400 2306885167, 3161648387, 4147811264, 502346124, 727472596; aim raise/lower
  1618725184 / 1659952173 (also seen without firing); empty-gun click 1829826749 (a=arm0400 b=cp_A100);
  bullet `PoolingObject_PlayerStraightShell_0` 1292272569. Shells: `app.ShellGenerater.requestShellInstance`.
- WinDrive: `mdown 960 540 right` (aim) + `click 960 540` (fire) + `mup right`.

## Automation notes (1920x1080 borderless)

- Title: Enter -> "Основной сюжет" -> Enter = "Продолжить" (loads last save, ~20 s).
- REFramework menu: Insert. ScriptRunner header (150, 492); "Reset scripts" (178, 518) — avoid.
- Dev bridge: `python tools/bridge.py "<lua>"` (runs on UpdateBehavior, globals in `dev`).

## v0.1.0 status (2026-10-13 20:50) — verified on one PC

- Steam: real friends-only lobby created under app 3764200; loopback send/recv OK. Two-PC P2P NOT
  verified yet (user has one PC).
- Self test ("echo" via the plugin's loopback, 150 ms delay): puppet built from the local costume
  (8 parts + ch02.refskel), follows walking/strafing with leg animation, gun mesh on R_Wep, name tag
  above `Head_0`. Screenshots: scratchpad e5/e6/e7.
- Package: `dist/RE9_Coop_Online_v0.1.0.zip` (autorun lua + plugin dll + README). `um publish check`
  "game file copied verbatim" failures are false positives: our own installed mod files.
- Shaders recompile on every launch until the game exits cleanly once (shader.cache2 still from March):
  kill = no save. Quit from the game menu.


## v0.3.0 status (2026-10-13 21:30) — verified on one PC with the built-in test mode

- v0.2 shots: muzzle hook (`EPVExpertMuzzleFlashCustom.play` on our gun) -> MSG_SHOT -> puppet point
  light on R_Wep for 60 ms (light object created on the echo after a real shot). Gun sounds: hook
  `SoundContainer.trigger(u32, GO a, ...)` where a == our gun -> MSG_SOUND(id) -> partner side plays
  `SoundContainer.trigger(u32, vec3, GO, u32, CallbackType, 4x Action)` on its own gun's container at
  the puppet's R_Wep. Audio capture proved the positional call plays (-54 dB -> -14 dB, 1.5 s tail).
- v0.3 shared enemies, test mode (`dev/test_enemy_echo.lua`: enemy A's stream goes through the
  loopback and drives enemy B as the guest copy): B copied A walking at Grace with arms out; with A
  calm, a revolver shot at B was caught (B HP stayed 580), sent as 2 damage messages, applied to A
  (580 -> 0, dead), and B then collapsed copying A's death. Screens: scratchpad t1, t7-t10.
- Gotchas found during the test:
  - A wave spawner (`cp_B000SpawnParam_隔離病棟最後WAVE_B00`) calls `requestSuspend()` ->
    `executeSuspend()` -> `invalidateSpawn()` on its enemy about every 10 s on the guest. The mod
    now refuses `CharacterSpawnParamBase.requestSuspend()` / `(ContextID)` for puppets the host still
    reports (its own calls pass via `foes.self_call`).
  - A put-away enemy comes back with `requestResume()`, not `requestSpawn()` (which is a no-op once
    HasCompletedSpawn is true). The mod alternates the two.
  - Warping an enemy into wall geometry makes it sink through the floor (CharacterController pushes it
    out downwards). Real host positions are valid, so only the test offset was affected.
- Two-PC test still to do (user has one PC).


## v0.4 WIP status (2026-10-13 21:45)

- Enemy ownership model (nearer player runs the enemy, lobby owner arbitrates, presence reports,
  handover keeps HP) implemented; test-mode regression passed (hit on copy B killed original A).
  Owner rule: 11/11 offline cases (`tools/luacheck/luacheck.exe --run tools/test_owner_decision.lua`).
  Two-PC behaviour (arbitrate/presence/handover) untested.
- **Lights created with `createComponent(via.render.SpotLight/PointLight)` don't work**: their float
  setters (Intensity/Cone/Spread/Radius) read back 0.0, while the same plain `call('set_Cone', 31.0)`
  works on the game's own flashlight light. So the v0.2 muzzle-flash light and the v0.4 partner
  flashlight are invisible. `sdk.float_to_ptr` is WRONG here (wrote 0.0). Next: instantiate the
  game's pool prefab `appsystem/character/characterprefab/playercommon/prefab/playerflashlightpoolobject.pfb`
  (has a configured SpotLight + PointLight) for puppets instead.
- Grace's flashlight can't be switched on in Chap3_02 (`FlashLightBlackboardUnit.Core:
  set_SwitchLightRequestImmediately(Nullable<bool>)` ignored, `_IsLighting` reset each frame).


## v0.4.0 status (2026-10-14 01:20) — verified on one PC

- Lights fixed: runtime `createComponent` lights ignore intensity/cone; puppets now instantiate the
  game's `AppSystem/Character/CharacterPrefab/PlayerCommon/Prefab/PlayerFlashLightPoolObject.pfb`
  (root SpotLight 10000/30 deg, children PointLight 100, LightShaft, LensFlare). Plain setters work on
  it. Muzzle flash = its PointLight, warm (1, .72, .38), 2000, r 5 m, 60 ms (screens l4). Flashlight =
  its SpotLight placed from the pose's light block (screen l5: beam on the pillar ahead of the echo).
  NB `sdk.float_to_ptr(x)` as a float argument writes 0.0 — pass plain Lua numbers.
- Teleport to partner: `requestWarp(player ctx id, Nullable pos, Nullable rot)` 1 m behind; landed
  within 1 cm.
- Doors: 57 `app.GmDoorV3` per chapter, id = `GimmickCore:get_ContextID()`. A push is one
  `addForce(RequestInfo{ActionType, Force, ForceDir})` (class, not value type). Replay with
  `sdk.create_instance("app.GmDoorV3.RequestInfo")` opened Gm01_102 remotely. Hook -> MSG_DOOR ->
  loopback -> addForce again: sent 1 / applied 1, no echo resend.
  `IGimmickDoor.requestInteractOpen(...)` did nothing on a far door.
- Pickups: 181 `app.ItemCore` (with InteractActionItemPickupHolder); id = `ItemCore:get_ContextID()`.
  Real pickup (ink ribbon, F) = `pickup` -> `onPickup` -> `notifyPickupped(true)`. Removing:
  `ItemCore._Context:set_IsSpawn(false)` -> item hidden by the game (Draw false).
- Chapter jump candidates (not used): `MainGameFlowManager:setOverrideNextJumpScene(string)` +
  `requestContinueToTransitionGame()`.
- FPS camera keeps its own yaw after a player warp: WinDrive `rel` turns of >600 px per event are
  unreliable; step in <=600 px chunks (45.5 px per degree at default sensitivity).


## v0.5.0 status (2026-10-14 08:00)

- Gimmicks: `GimmickManager._GimmickContextCache` (684 contexts in Chap3_02, 558 with GmBaseData;
  full scan 8 ms -> 60 per frame). `GimmickContext:store()` returns COPIES; `restore(SaveData)` returns
  true and replaces the live StructureData objects. But a running gimmick rewrites its data from its
  runtime state within a frame (door Gm01_144: `_IsLock` back to true; its lock is the key gimmick
  Gm02_013 next to it). Tried and failed to change a running lock: restore, live set_field + onDirty,
  `GimmickCore.setup()`, `GmDoorV3.assignDataContainer`, `requestInfo(0,0,Normal)`,
  `StructureDataContainer.insertStructureData` (made `_IsDone` stick, not the lock),
  `GimmickManager.requestGimmickForceEnd`. So gimmick data sync only helps gimmicks that aren't
  loaded; the mod ignores its own rewrite for 3 s after applying (no ping-pong).
  `via.Serializer.serializeJsonInternal(obj, nil, nil)` returned "null"; no deserializer in the TDB.
- Story: `LevelFlowManager._ProgressiveNumberList` Dictionary<uint,int> (637 flows; read via
  `_entries[i].key/value/hashCode`, `_count`). Hooked `setProgressiveNumber(UInt32, Int32)`; replay with
  `requestChangeProgressiveNumber`. Not exercised end to end (needs two players).
- Chapter jump verified: `MainGameFlowManager:setOverrideNextJumpScene("Chap3_03")` +
  `LevelFlowManager:requestGameJump()` loaded the next part (player folder Chap3_0304, its cutscene
  started). No save was written (killed the game during the cutscene). Saves backed up first.
- Cutscene flag: `app.TimelineEventMediator:get_IsPlayingCutScene()` true during that cutscene.
- Public lobby (`host(2, 2)`, plugin 0.2.0) created; `sdk.copy_to_clipboard(id)` puts the lobby ID on
  the clipboard (checked with Get-Clipboard).
- Lua main chunk hit the 200-locals limit: the doors/pickups, gimmick and story sections are now
  `do ... end` blocks exporting only what other code uses.

## v0.6.0 status (2026-10-14 21:20)

- Dead enemies: when the runner's copy reports F_DEAD, the other game releases its puppet (AI back)
  and deals lethal damage through `HitPoint.addDamageHitPoint` (bypassing the forward hook). One-PC
  echo test: zombie B (copy of A) -> `get_IsDead` true, HP 0, death animation; both bodies on the floor.
- Item box: inventories per `InventoryManager._Inventories` key (`_User:ToString()` + `_BoardType`):
  None/2 (ShareItemBox), User00/1, User01/1 (ItemBox, 1x100 list, every panel 1x1). Read with
  `getPanelStates()` (ItemID `_Name`, stock, position, rotation, loaded ammo via
  `ContainItemState._AmountData._ItemID/_Stock`). Changes as ops, applied with
  `addPanel(ItemID, Int32, via.Int2, RotateType, ItemStockChangedEventType)`, `reloadDirect`,
  `removePanel(PanelKey, EventType)`. `ItemStockChangedEventType` is an enum class: static objects
  Default, Discard, Reloaded, Unloaded, Switched, Moved, Craft, Backup, Missable, Append, CarryOver.
  `addPanelImpl(PanelItemSaveData)` and `restoreFrom` throw.
- CRASHES (c0000005 in runtime code ~re9.exe+0x555xxxx-0x558xxxx; stack via tools/dump_stack.py +
  method address map: `LockOnTargetDriver.onUpdateScanPhase` -> `CharacterRoleActionDriver
  .get_IsRoleMode` -> `BitArrayApp.isTrue` on a worker thread): changing any inventory (add or remove,
  any event type, mergeOrAdd/consumeStock too, even Grace's own box) from REFramework callbacks
  (pre UpdateBehavior, post LateUpdateBehavior, post BeginRendering) crashed within seconds in ~1 of 3
  ops. The same ops run inside a hook of `app.GuiAutoSaveFlowController.update()` (GUI update, every
  frame): 26 ops in a row incl. reloadDirect and removing loaded guns, no crash. Rule: change
  inventories only from inside the game's GUI update.
- Full box flow (simulated partner): partner's loaded gun + ammo put in; our own removal sent (no
  echo); partner's removal applied; join merge adds the owner's items, sends back ours; stable.
- Saves: `app.SaveServiceManager` slots via `_SaveSlotInfoDict` (key `_SlotId`, value
  `_SerialNumber`): -1 system (data00-1), 0, 1, 10, 11. `_CurrentSaveSerialNumber` moves on every save
  (system ones too). The game's autosave: `GuiManager.<AutoSaveFlow>` (`GuiAutoSaveFlowController`),
  `requestAutoSave(GuiAutoSaveFlowRequestArgs)`; default args = Auto (2) / EmptyOrOldest (2049).
  Phases: Idle 0, Update 1, RequestGameSave 2, GameSaveWait 3, ... The guest's save reached
  `requestSave(Auto, 2049)` (blocked by the dev save guard: dev bridge skips game-slot saves while
  re9coop_bridge/block_saves.flag holds "1"). Boot writes a System save (`requestSaveCore(System, 0)`).
- Follow: with a fake host in Chap3_03, the countdown showed, then the jump loaded Chap3_0304. Chapters
  now compare by "Chap<N>_<NN>" so a folder name (Chap3_0304) and its chapter (Chap3_03) match.
- Live locks: `GmLockV2._GmLockData` is the same object as the context's StructureData (so writing it
  directly reaches the running gimmick; `restore` swaps in copies). Setting `_UnlockCount` to max makes
  `get_IsUnlock()` true, but `_IsCurrLock` stays true (updateLockSync re-derives it); the running state
  only flips through the key-use scene (`GmUseKeyItemV3`). Not shipped.
- Occasionally `scene:findComponents(Type)` hands back a non-array; lookups are pcall'd now.

## v0.6.1 status (2026-10-14 21:50) — live locks and gimmicks

- `GmLockV2` unlocks on interact triggers named in `_UnlockParams[i]._TriggerName` (bound through
  `IInteractTriggerInitializer.initializeInteractTrigger`). Triggers live in holder components on the
  same GameObject (`InteractTrigger*Holder._Triggers`: KeyInput "Interact", KeyItemInventory
  "UseKeyItem_Success/Failed/None", "Inventory_Open/Close", GimmickEvent "TurnOff", "SuccessEnd",
  GmStructureData "MotionEnd", "Unlock"...). 2064 triggers in Chap3_02.
  Gm02_028: unlock on "UseKeyItem_Success"; Gm02_021 (security lock of gate Gm01_148): "TurnOff" (sent
  by the key scene's end); Gm02_042: "MotionEnd".
- Calling `InteractTrigger.onProcessEvent(go)` on that trigger (go = the gimmick's GameObject) opens
  the lock the game's way: `_GmLockData._UnlockCount` 1/1, `_IsDone`, target `_IsLock` false, no
  player scene. Gate Gm01_148 then opened with F (door `IsDoorOpen` true).
- `GimmickContext.restore()` replaces the SDC's StructureData objects, but running components keep
  references to the old ones (`GmLockV2._GmLockData` / `GmSwitchV2._GmSwitchData` == SDC object before
  any restore). Writing fields straight into `StructureDataContainer._Structures[i]` reaches the running
  gimmick: switch Gm19_009 `_GmSwitchData._Index` 0 -> 2, its `_CurrIndex` followed once the player was
  near (gimmicks far away don't update).
- Right after a load, gimmick components' `_Context` is nil for a few seconds: indexes built then miss
  them; the replay retries for 10 s and forces an index rebuild (at most every 2 s).
- Echo: a replay's own trigger chain isn't sent back (5 s per context), each trigger is sent once per
  10 s, and an already open lock isn't opened again.

## v0.7.0 (2026-10-15) — downed / revive, grabs, personal pickups, chapter sweep

- HitPoint: `get_NoDeath()` is an `app.ReferenceCountBoolRequestHolder` (`request(String label, Boolean)`,
  `clear(String)`, `getResult()`): with a request on, 5000 damage left Grace at 1 HP, alive. Also
  `set_Invincible`, `setNoDieCharacter`, `recovery(Int32, RecoveryFactor)` (nil factor works).
- Player restrictions: `upd:get_RestrictBlackboardCore()._Unit (<Unit>k__BackingField)
  :requestRestrictionAction(RestrictionType)`; consumed every frame (`_RequestRestriction` back to 0),
  so request each pre-UpdateBehavior. RestrictionType: Walk 1 Run 2 Move 4 Terrain 8 Hold 16 DispHUD 32
  InventoryOpen 64 Crouch 128 EquipmentWeapon 256 QuickTurn 512 CameraControl 1024 SwitchControl 2048
  SwitchLight 4096 MeleeWepAttack 8192 Stumble 16384 Cover 32768. With 58335 W didn't move Grace.
- Player status: `pc:get_Common()` (PlayerContextUnit_Common): IsCrouch, IsMeleeAttack, IsDamageAction...
  Crouch key on PC: left Ctrl (VK 0xA2).
- Grabs: `app.GrappleFsmController` (pooled component). `requestGrapple(GameObject[], UInt32)` /
  `startGrapple(GameObject[])` with participants [cp_B000_06, cp_A100]; `get_IsPlaying()`;
  `forceEndGrapple(false)` (from the GUI update) freed Grace at once, zombie unharmed. The player's
  InteractTrigger "GrappleEscape..." flags don't move during a zombie grab.
- Down flow verified: lethal hit -> HP 1 + down; a real zombie bite (800 -> 260 -> lethal) -> down, its
  grab ended; revive -> 280/800; bleed out -> "Вы погибли" game over. Bug fixed: after dying the mod
  re-entered "down" on the dead player (lethal hits keep coming while HP is 0).
- Items: `ItemManager._ItemCatalog:getValue(ItemID, nil)` -> ItemDetailData `_ItemCategory`
  (enum class; ToString): Ammo it40, Heal it00, Material it50, Weapon it10_0x/it10_2x, SubWeapon it20,
  Armor it10_30, Attachment it30_00_1xx.., Charm, KeyItem it60, Map/Flag/Storage/Other it99, Procedure
  it70. 181 ItemCores in Chap3_02 all resolve.
- Chapters (natives/stm/gameassets/content/maingame/scene/*.scn): chap1_00 1_01 1_10, chap3_01 3_02 3_03
  3_0304 3_04 3_05 3_06 3_10 3_20 3_324 3_40, chap4_00 4_10 4_1020 4_20 4_30 4_40 4_4050 4_50, chap5_02
  5_03 5_04 5_05 5_10, ff_01 ff_02. Chap1_10 is Leon (cp_A000, 84 joints): his echo puppet builds (9
  parts) and holds his gun.
- Title screen: left idle it plays the opening (FBI office) in-engine; Esc opens the cutscene menu,
  holding F skips. Driving the title needs a screenshot first.
- Crash during the first sweep (jump Chap1_01 -> Chap1_10, same LockOnTargetDriver stack as the
  inventory crashes) while several dev hooks (fake partner reading the stale player object every
  frame, zombie test hooks) were installed; a clean jump Chap1_10 -> Chap3_01 with the echo puppet on
  went fine.

- SCENE JUMPS CRASH OUTSIDE THE GUI UPDATE: `setOverrideNextJumpScene` + `requestGameJump` issued from
  REFramework callbacks (pre UpdateBehavior via the bridge) crashed 1-5 s later in 3 of ~6 jumps
  (LockOnTargetDriver scan / runtime, same as the inventory crashes). The same jump run inside the
  `GuiAutoSaveFlowController.update` hook: 17 chapter jumps in a row, no crash. The game itself calls
  `LevelFlowManager.requestGameJump` for every move into a game scene (loading a save, the next chapter).
  So the mod now queues everything that changes the world (`ext.later`: chapter jumps for following
  the host, story steps, door pushes, pickups, the guest's save) and runs the queue in the GUI update;
  on `requestGameJump` / `requestLoad` it drops all scene-object indexes and puppets and collects.
- Chapter jumps to Chap5_03 / Chap5_04 straight from Chap5_02 left a black screen (no player, game
  alive): not every chapter can be jumped into out of order.
- `scene:findComponents` / `go:get_Components` sometimes return something that isn't an array:
  `elements(arr)` (pcall'd get_elements) everywhere.
- Item box screen: firing the box's own "Interact" trigger (KeyInputHolder on Gm15_003) opens the
  real box screen (and a first-use tutorial). While it is open: `GmItemBoxV2._StepType` = 3 and
  `GuiItemBoxModel.setup / canStore / collectHasItem` run. Tab ("Положить") stored the medical injector
  into User00/1 (Grace's ItemBox); the mod saw and sent it. A partner op that arrived meanwhile waited
  and was applied after closing; our addPanel'ed ammo shows in the real box screen. Side effect: the
  Steam achievement "С глаз долой" (store an item as Grace) unlocked on the user's account.
- Chapter starts fill boxes on their own (21 box changes over the sweep): only changes made while a box
  is in use (step not None, or the box screen within 3 s) are sent now; box.known resets on scene
  change. Two chapter jumps after that: nothing sent.

## v0.8.0 (2026-10-15) — puzzles either player solves, recipes, bosses

- REFramework sometimes hangs at game start: log ends with "Locking PEB + loader locks" and a list of
  "Suspending <tid>" lines, the window stays black, the bridge never answers. Kill and relaunch;
  `tools/start_game.py` now retries the launch up to 3 times.
- Laser microscope (Gm99_054, Chap3_02 f63b9e78 / fa05b693): using a blood sample (it60_00_064,
  "Проба крови (денатурация)") fires KeyItemInventory UseKeyItem_Success + UseKeyItem_Success1, then
  GmStructureData Gm99_054Start / PuzzleStart and a close-up molecule puzzle ("activate all atoms",
  aim the cursor with raw mouse moves, F converts). Solving it fires GmStructureData Success1 and
  unlocks crafting recipes (pistol ammo, hemolytic injector) — on the solver's side only.
  - Recipes: `ItemManager._UnlockedCraftRecipeIDSet` (HashSet<app.CraftRecipeID>; CraftRecipeID is a
    class with static instances like `recipe40_00_000_01`, ToString gives the name),
    `unsealCraftRecipe(app.CraftRecipeID, System.Boolean)` (true: shows as new), `isSealCraftRecipe`,
    `isNewArrivalCraftRecipe`, `_AcquireItem2UnsealCraftRecipeCatalog` (recipe files).
  - Replaying UseKeyItem_Success on the partner's microscope started its puzzle there with nobody at
    it. Close-up gimmicks carry `InteractActionFixCameraHolder` (locks don't, heart/lung Gm99_104
    doesn't): key-item triggers of gimmicks with a fix-camera holder and no GmLockV2 aren't replayed.
  - The partner's microscope, given the solver's data, shows _IsDone / _IsLock / GmMotionData
    _IsLoopWait = true, and still opens its item screen when used: it isn't stuck.
- Live "area reload" of one gimmick — `GmBase` explicit interface methods
  `app.GimmickCore.IGimmickContextReceiver.finishGimmickContextReceiver()` then
  `...setupGimmickContextReceiver(GimmickContext)` (context from `GimmickCore._Context`; finish clears
  `GmBase._Context`) — runs without errors but breaks the gimmick: using the microscope afterwards hung
  at StepType 1 with a dark screen. Not used.
- Gimmick types with force methods (all of app.Gm*): Gm18_008(_02).forceGimmickEnd,
  GmContainer.forceOpen/Reset, GmSafe.forceOpen/Reset, GmFragileSymbol.forceBroken/Reset,
  GmElevator.forceRequet/forceRequestNextFloor/forceRequestDoor, Gm99_098.requestForceStart.
- Enemy kinds (app.CharacterKindID): A players, B zombies and stalkers, C/D creatures, E/S/T/V/X/Y/Z
  others. No boss flag in the data (EnemyContext has EliteStatus, RoleActionState). Boss / stalker
  traits by type names: B800 (phases, retreat points, wander, door block — a stalker), B700 (battle
  area), C100 (phase driver), C610 (phase attacks), D110 (weak points, stance, battle cycles, an HP
  gauge configuration), D100 (stagger timer).
- Bosses: kinds in `foes.bosses` keep their owner for the whole fight (a handover restarts the AI and
  breaks phases); they only move when the owner's copy is gone and the other player still has one.
- Chapter sweep with enemy kinds (20 chapters, no mod errors; Chap4_00 and Chap5_10 don't load
  directly): one-of-a-kind enemies are B700 (Chap4_10/1020, 10000 HP, with 68 C700), C100 (Chap3_02,
  Chap3_20, 6000 HP), C510 (Chap4_40), C900 (Chap4_50, with 4 C901), B032 and B052 (Chap3_40), B002.
  D000 / D100 / D110 / C610 never showed up in a directly loadable chapter (story-only chapters).
- Boss spawn controls live in their arena's folders (C100: six `app.Cp_C100SpawnParam` around
  院長室前, `Chap3_02_CharacterSpawnParam_00/東エリア/院長室前まわり` and `..._InsanityOnly`). Folders:
  `go:get_Folder()`, `get_Parent` up to "MainGame", `get_Child` / `get_Next` down; `Folder.activate()`
  loads one. The six spawn params share the boss's context (InheritOtherObjectSpawnedContext): before
  one of them spawns it, `CharacterManager.getSpawnDataRef(id)` is nil; `permitSpawn(true)` +
  `requestSpawn()` (GUI update) spawns it.
- BUG FIXED: `spawn_control()` cached a failed lookup as false for good, so an enemy whose spawn
  control loaded after the enemy list was first read (every boss, and enemies of areas loaded later)
  was never puppeted or spawned for the partner. Misses are looked up again after 1 s, hits after 5 s.
- C100 spawns asleep (`GameObject.UpdateSelf` false) until its entrance; `puppetize` waited for it to
  wake. Now the partner's copy is woken when the owner's copy is up (fresh state, spawned flag), then
  puppeted. Test (one PC, loopback, C100 as the copy of zombie a87da8ab): woken and puppeted
  automatically, drawn and warped; a direct addDamageHitPoint(120) and two real pistol shots went to
  the owner's enemy (boss HP stayed 6000); ending the test gave the boss its AI back (it walked off).
- Joint lists are capped at 255 (the count is a byte); C100 has 100, players 68 / 84.

## v0.9.0 (2026-10-15) — game over, cutscenes, partner marker, drops, reconnect

- Game over: "Вы погибли" -> "Продолжить" loads the last SAVE (not a separate checkpoint). With a
  partner up, a player down for 30 s now comes to next to them (teleport + 35% HP). Loads announce
  themselves (MSG.LOADED); the partner who stayed answers STAYED and resends story (MSG.STORY_FWD:
  forward only), gimmicks, box, recipes and its own pickups; a host that just loaded waits 4 s first.
- Cutscenes: `app.TimelineEventMediator` (managed singleton) `skip(System.Object)` is what the pause
  menu calls (caller `GuiPauseMenuController.Unit`); null throws, the mediator itself as the caller
  works. Current event: `_ActiveEvents` (TimelineEventProcess) `<TimelineEventId>k__BackingField`
  (e.g. 312700 = c312s700, 410201). Fades: `app.FadeManager` isFadeOut(FadeType), requestFadeIn;
  FadeType INTER_GAMESTATE 0, GAMESTATE 1, SCENARIO_JUMPER 2, GUI 3, EVENT 4, PLAYER_MODE 5,
  GIMMICK 6, POTOMODE 7, WAITLOAD 8, BATTLE_READY 9. Jumping straight into Chap3_10 and skipping its
  intro (even with the game's own menu) leaves the EVENT fade out in Chap3_02 with no control: an
  out-of-order jump artefact. Jump names: "Chap4_10" works, "Chap4_1020" (a folder) reloads.
- Map: `app.UI2500GuiBehavior` (map screen, open while its GameObject DrawSelf). Player icon
  `_PlayerIconControl` (via.gui.Panel) GlobalPosition in 1920x1080 GUI space; `_PlayerPosition` is in
  map units; `_ZoomMagnification`; `_DisplayRange` (via.gui.Rect, centre 960,588, size 1284x616);
  floor maps: 20.48 map units per metre, world x -> right, z -> down (Chap3_02 calibration).
  NPC icons exist (NpcIconNum 4) but take their positions from the floor data.
- Enemy drops: `ItemManager.requestGenerateItem(ItemAmountData, via.Position, via.Quaternion,
  ItemGenerateRequestType, Action, Action)`; request types Unknown, ReliefCh (enemy), ReliefGm,
  SpawnCh, SpawnGm, DropResource; generated items carry `ItemCore._GenerateType`. Enemy relief drops
  are a lottery per player (`requestLotteryReliefItem`); zombies in Chap3_02 have
  `<IsPermitedItemDropnOnDead>` false and dropped nothing even with it on. `app.ItemAmountData` can't
  be created from Lua (create_instance nil); `Inventory.PanelState.deployAmountData()` gives an
  `app.ItemStockData` (`_ItemID` string, `_Stock`) to fill in with set_ItemID.
- Box race: a partner's "-panel" that no longer matches, for a panel we took out < 10 s ago.
- Reconnect: net plugin states idle / creating / joining / in_lobby / error; ids are strings.
  Tested with `re9coop_net.status / join / friends` stubbed (no real Steam lobby made).
- Leon and Grace together (research, not done): `CharacterManager.getPlayerContextID(kind)` gives an
  id for every playable character in every chapter; the chapter's player comes from
  `app.LevelPlayerCreateController` (`_DefaultPlayer` CreateSetting: `_ControlCharaId` "cp_A100",
  montage 200/2; `_OtherInitPlayerArray`, `createOtherCharacter()`, `suspendOtherCharacter()`), and
  `CharacterManager.SwitchPlayerControlChecker.requestSwitch` moves control. requestSpawn for Leon's id
  in Chap3_02 and an extra CreateSetting + createOtherCharacter() both did nothing (no spawn data /
  resources for him there).
- Tools: `luacheck --globals file.lua` lists every global read/write from the bytecode (GETTABUP /
  SETTABUP on _ENV); globals_check.py uses it. It found `T_MEDIATOR` read out of its scope (the cause
  of a load error) and `rig_enable` called before its local was declared (the puppet's torch stayed on
  when the partner was hidden).

## v0.9.1 (2026-10-15) — puzzles checked one by one

Method: a lock or puzzle solved for real on one side (the game's item screen through the dev bridge:
item given, Interact fired, cursor moved to the item's cell, F), the mod's messages recorded and the
gimmick's state snapshotted (data + every component's plain fields); then the recording played back
on a fresh game as the partner and the same snapshot compared field by field
(tools/solve_gimmick.py, scratchpad gm_snap / partner_check). Then a census of every puzzle type in
every loadable chapter with a "does the runtime follow its data" test (tools/puzzle_probe.lua,
puzzle_sweep.py, puzzle_report.py).

- BUG FIXED, locks never opened live for the partner (since v0.6.1): the partner's state messages
  (UnlockCount 1, IsLock false) arrive before the unlock trigger; lock_open() read the data, took the
  lock for open and skipped the trigger, while GmLockV2._IsCurrLock stayed true and the lock wrote its
  data back. Now: open = `_IsCurrLock` false; an unlock trigger waits 0.5 s after the partner's data
  was written (data written in the same frame made the lock drop the unlock), the data after it waits
  1 s (gim.hold); the count goes one down before the trigger (the lock adds it again on its next
  update: 1 -> 2 otherwise, and a two-key lock would open on one). Verified on 4 real solves: a
  padlock (Gm02_006, unlocks on GmUseKeyItemSuccess) and three security-tag doors (Gm02_012 / 021 /
  027, unlock on TurnOff): every changed field matches the solver except the item screen's own.
- BUG FIXED, item use replayed into puzzles took the partner's controls: Gm99_108 (pencil rubbing)
  replayed UseKeyItem_Success went to step 10 with "move the pencil / shade" prompts on the partner.
  Item use is now replayed only on gimmicks with item slots (GmMultipleUseKeyItem: heart / lung,
  verified again); locks open on their own _UnlockParams triggers (GmUseKeyItemSuccess, TurnOff,
  SetMoon/Sun/Star, Unlock, MotionEnd, SuccessEnd, SuccessTag, UseKeyItem_Success(_Lv2)). A miss in
  the trigger index rebuilds it for any name replayed so far.
- Lock unlock triggers in Chap3_02 (28 locks): see `_UnlockParams._TriggerName`; required items are on
  the KeyItemInventory triggers (`_TargetItemIDStrs`, System.String objects: ToString), e.g. Gm02_006
  it99_50_006, Gm02_012 it60_00_055/068/075, Gm02_016 sun it60_00_048 moon 049 star 050 (bits 4/2/8).
- Gm02_016 (sun / moon / star) is the lock that ends Grace's part of Chap3_02 (into Chap3_10, Leon).
  Partner: data (_SetType, ProgressIndex, UnlockCount) follows; the panel's runtime _SetType doesn't
  (set_SetItemType(data) sets it, unverified on screen).
- GmMotionV2 follows its data live (_Index written -> the motion plays to the end).
- Puzzle census, runtime NOT following data (state only; the partner's copy catches up when the game
  loads): Gm99_081V2, 098, 099, 101, 102, 105, 108, 110 (the hospital, Chap3_02 / 3_20), Gm19_066
  (Chap3_01). Their progress (story steps, global flags, locks) is shared live. GmItemInstallation
  (Chap3_01, 4_1020, 5_02, GetItem) also stays, which is right: the key item stays for the partner.
- Gimmicks never stream out within a chapter (all 374 GimmickCores of Chap3_02 exist at once): "the
  area reloads" means a load. The `.../stXX_YYY_Gimmick_Common/<Group>` folders report inactive while
  their objects live; Folder.activate() does nothing there.
- Warping straight into another room right after a load can drop the player through the world (to
  y -469, then a game over): its collision isn't there yet.

## v0.9.2 (2026-10-16) — solved puzzles look solved for the partner

Method as in v0.9.1, now with the game's own controls on the solver side (a coin locker with the
coin count screen, the two quartz cabinets with A / D / F, the pencil rubbing with the mouse held
down, the hint panel), recordings played back as the partner on a fresh game, and screenshots.

- The running copy of most puzzles reads its data only when it starts, as after a load: onStart(),
  IStructureDataUser.assignDataContainer(SDC), or its own reform method. Called right after the
  partner's data is written (in the GUI update), the puzzle catches up the way a load would
  (gim.catch_up in the mod; only when set up, idle (_StepType 0 or none) and behind the data):
  - Gm02_032 coin lockers: onStart when data _Unlock and runtime not: the glass door goes down
    (local y 0.92 -> -0.08, as on the solver) and the item inside can be taken (hip pouch, steroids,
    unlock manual seen).
  - Gm99_102 sun quartz safe: reformOpenState when data _Success: the door turns 110 degrees; the
    sun quartz and the leather notebook inside can be taken.
  - Gm99_108 pencil rubbing: assignDataContainer when data _Success and runtime not: opening the
    notebook shows the shaded page with MOON SUN STAR MOON and the "chairman's note"; the partner
    gets the document. (onStart doesn't read it.)
  - Gm02_016 sun / moon / star door: onStart when data _SetType differs: the emblems put in show in
    its window (checked with sun, then sun + moon); putting in the star afterwards worked as usual
    (one emblem, no double handling after two restarts).
  - Gm99_099 (a talking "pilot" in a helmet behind a grate, HP 50, Dead 5 / DeadCrash 6): onStart
    when data _State >= 5 sets the runtime dead (_State 5, IsStateDead). Not seen on screen (too
    dark), not killed for real (the revolver had no matching ammo).
- Not needed: Gm99_101 moon quartz cabinet (its GmMotionData index brings the quartz out, the
  partner can take it), Gm99_110 (a hint panel with three code plates: only _HasInteracted), Gm99_105
  (the monitor rewrites its data from its runtime: follows the heart / lung slots).
- Gm99_081V2 is not a puzzle of its own: it is the molecule puzzle inside the laser microscope
  (Gm99_054). Its "PuzzleStart" / "Success1..4" are GmStructureData triggers on its own data
  (PuzzleNo, IsSuccess), its "Success" / "Cancel" send PuzzleEndCommand to Gm99_054Data. Its result
  (recipes) is shared since v0.8.0 and the partner's microscope takes the done state: nothing to do.
- Gm99_099 sits in the cabin of the big machine of the bulldozer scene (Gm99_098; head joint ~4 m up,
  out of sight from the floor): its death is caught up by onStart, and its data trigger "Dead" fires
  in the partner's game from the data alone, for the gimmicks waiting on it.
- Left: Gm19_066 hanging lamps (Chap3_01) light zones for the stalker (GmStructureDataLightZoneSwitcher
  with Cp_B800LightingControl, GmIlluminationData index 1 = zone off); they light from the wall switch
  Gm18_001 (GmSwitchData index 1 -> lamp ProgressIndex 1), which is shared. Their BurnOut
  (_ActionType 4) isn't read by onStart or assign, GmIlluminationV2 writes its data back from its
  runtime, app.DamageInfo can't be created from Lua, and Chap3_01 entered by a chapter jump starts
  with a fixed camera and no control (Esc opens the pause menu, W doesn't move): not reproduced.
- Codes: Gm99_101 Moon Sun Star Moon (buttons 0 Star, 1 Sun, 2 Moon), Gm99_102 Star Sun Moon Sun
  (buttons 0 Sun, 1 Moon, 2 Star): `_CorrectMarks`. Gm99_108 needs 29 of 60 cells
  (`_NumOfPaintedCells`); its pencil item could be skipped by firing UseKeyItem_Success (then Esc).
- BUG FIXED, settings sent as 0: gimmick states are read from store()'s copy, which leaves some
  settings out (they read 0 / false there): GmLockData._MaxUnlockCount (29-40 locks per chapter),
  GmSwitchData._IndexCount / GmMotionData._IndexCount (hundreds), GmDoorData._IsDoubleDoorClose,
  GmElevatorButtonData._IsButtonInteractable, the _PlaceIDHash of safes, containers and symbols
  (census of store() vs the live data in Chap1_01, 3_02, 3_05, 4_10, 5_02). They were written into
  the partner's live data with every state message ("0 keys needed", "0 positions"). Never sent and
  never written now (gim.unsaved). A lock didn't open early from it (sun alone: still locked).
- BUG FIXED, a coin locker sent twice a second for good: GmStructureData triggers fire from data
  conditions; an open locker's "Unlock" fires every frame while Gm02_032Data._Unlock is true and its
  lock adds one each time (UnlockCount 6691 after a minute), so its fingerprint never settled. The
  count is now sent capped at what the lock needs (the live _MaxUnlockCount).
- Gm02_028 (a key lock on the sun quartz safe) is unlocked by the safe's code, with no trigger: on
  the partner its data says open, its _IsCurrLock stays true (lock onStart doesn't change it); the
  safe door and its items are right.
- A chapter jump keeps the stage's gimmick data (data written in Chap3_02 was still there in
  Chap3_20); after a jump the screen can stay black until FadeManager.requestFadeIn.
- In Chap3_02 the side of the sun / moon / star door facing -z (z < 23.5) isn't loaded at the start:
  warping there is a fall; its window is seen from z 25 (its "Item" child at y 5.93).

- Release zip with its dependencies (2026-10-17): the mod needs only REFramework. re9coop_net.dll
  imports KERNEL32 alone (static CRT, /MT) and finds the game's steam_api64.dll at run time;
  REFramework's dinput8.dll imports only Windows DLLs (d3d11 / d3d12 / D3DCompiler_47 and the VR
  loaders openxr_loader / openvr_api are delay-loaded, the VR ones only in VR). The zip now carries
  dinput8.dll of nightly 01432 (d052e8fd, the build every test ran on; SHA-256 70a2a3c2...05ac,
  identical to the installed one) at its root, plus licenses/REFramework_LICENSE.txt (MIT) and
  licenses/REFramework_THIRD_PARTY_NOTICES.txt: REFramework's own src/LicenseStrings.hpp at that
  commit (glm, imgui, cimgui, MinHook, spdlog, Roboto / Noto CJK, OpenVR, sol2, json, Lua, AsmJit,
  bddisasm, OpenXR, ImGuizmo, DirectXTK) and the license files of imnodes, DirectXTK12, safetyhook,
  kananlib and FreeType (FTL) at the revisions its cmake.toml pins. tools/package.py takes the dll
  from _deps/REFramework-nightly/ (downloads the pinned nightly zip if missing) and checks the hash.

## v0.10.0 (2026-10-17) — the guest plays in the host's story; the partner's hair

A two-PC session (a friend's logs): the friend loaded their own save (Leon, Chap4_1020), joined, was
taken back to Chap3_02 (Grace) by the follow, then into Chap3_20 by the host's skipped cutscene, and
was left on a black screen, with no cutscene; the box sync sent their 21 box items into the host's
box; the host saw the friend's Leon bald.

- The partner's hair: Leon's hair is strand hair, a child "ch0100_21_00_Strand_Hair" of part 21
  (via.render.Strands, via.dynamics.GpuStrandsDynamics, app.MontageStrandsDynamicsBinder with
  BindTargetName "10"). The game's costume system binds the dynamics to the face part; a puppet has
  none, so its strands stayed unbound (StrandCount 0, Initialized false) and their bounds blew up to
  +-138 km: bald. Fixed: GpuStrandsDynamics.set_BindingGameObject(GameObjectRef(.ctor(GameObject))) to
  the puppet's own part named by the binder, ResetSimulation two frames after the first pose and after
  any jump of more than 3 m. Verified on the echo (bald before, hair after; nothing else changed).
  Not it: the part-21 mesh (same mesh, material, parts, LOD, material variables as ours: drawn but the
  card hair is hidden while strands are on), the ShellFurMesh parts 01/02/40 (stubble).
  ch0100_41_000.pfb / ch0100_44_000.pfb in the friend's reframework_faulty_files.txt are just prefab
  names the puppet builder tried first (it found _001).
- Saves can't be handed over: DSSS files, encrypted (entropy 8.00 bits per byte), keyed per account.
- New game straight in a chapter: GameDifficultyManager.setNewGameDifficulty(GameDifficultyID.ID00x0),
  TitleFlowController.onNewGame() (it calls SaveServiceManager.requestNewgame, the handlers'
  setupNewgame, LevelFlowManager.requestReset, and sets NewGameSceneName back to Chap1_00), then
  MainGameFlowManager.setNewGameSceneName(chapter): the scene loads after the fade. Tested: Chap3_20
  (Leon, no intro, control, an empty inventory). Quitting to the title already runs requestReset +
  requestNewgame (the title's data is a new game's). The title's GUI update hook runs, so the mod's
  GUI-thread jobs work there. A follow jump from a new game into Chap3_02 also worked (Grace with one
  gun).
- Guest co-op playthrough (cfg.fresh_join): at the main menu the guest sends PLAY_REQ(1); the lobby
  owner answers PLAY (chapter "Chap%d_%d%d", difficulty "ID0030"); the guest starts the new game,
  then on arrival restores its kit from re9coop_coop_<host>.json or asks for one (PLAY_REQ(2) -> KIT,
  JSON: per hand inventory (User00 Grace, User01 Leon) level, money, panels as the box's
  "item|count|rot|ammo@x,y", equip Primary/Secondary and shortcuts Equip_Up..Right2 by slot
  position; applied with setLevel, mergeMoneys, removePanel/addPanel/reloadDirect, setEquip /
  resetEquip, setShortcut). Saves while active: the requestSave(Category...) / requestSaveCore /
  requestSave(Index|Address) requests are skipped unless the category is System (1). A requestLoad
  ends the playthrough (the guest's own save loads). The guest's box takes the owner's as it is
  (extras removed, nothing sent back). On their own save in a lobby the guest gets nothing shared
  (world_shared false) and a hint. Verified on one PC: phase asked -> new game in Chap3_20 on ID0030;
  the game's autosave there (requestSave Auto/EmptyOrOldest, let through by the dev guard in its new
  "2" mode) skipped by the mod, all save files byte-identical after; the host's kit applied (same
  panels, ammo 9/40 on screen; Leon's empty Primary comes back holding the handgun: the game equips a
  gun when there is one, resetEquip doesn't keep it empty), kit stored,
  10 extra rounds given, stored, quit to the title (playthrough ended), joined again: the 10 rounds
  were back. PLAY_REQ / PLAY / KIT also round-tripped through the net plugin's loopback.
- Black screen: FadeManager.isAnyFadeOut with a player, no cutscene, no pause GUI for 8 s, within
  2 minutes of a scene change the mod brought about (follow jump, co-op playthrough start, the
  partner's skip) -> requestFadeIn on fade types 0-8. Seen firing on a forced fade; not armed for the
  game's own fades (it fired once on a normal Continue load before it was limited).
- PROTO 9 (new messages PLAY_REQ 33, PLAY 34, KIT 35).

## v0.10.1 (2026-10-17) — the guest's chapter froze on joining

The first real co-op playthrough (the friend's log and the host's): the guest's new game started in
Chap3_02, the host sent its 86 story steps and 684 gimmick states on arrival, the guest's screen
stayed black (the mod's watchdog faded it in after 8 s) and the guest could neither move nor look
around.
- Reproduced on one PC with the host's real Chap3_02 (AUTO 02, 86 moved flows): a new game in
  Chap3_02 alone plays the chapter's opening cutscene after ~12 s of black, then gives control; with
  the 86 steps applied right on arrival the opening never starts, the screen stays black (40 s+),
  and faded in there is no moving, no camera; a chapter jump doesn't recover it (the flows carry
  over). The same 86 steps applied after the opening: control, no black screen.
- Fixed: the partner's story steps (whole-chapter catch-up and live ones) and gimmick messages wait
  while our game is setting up (no player, a cutscene, a fade); they're applied once it has been free
  for 3 s ("caught up with N story steps"). The guest's kit is applied then too. The co-op
  playthrough skips the chapter's opening cutscene: TimelineEventMediator.skip right as a cutscene
  starts is taken (returns true) but it plays on; 3-4 s in it ends it (what the pause menu does,
  with GuiPauseMenuController.Unit as the caller; the mediator as the caller works the same). The
  black-screen watchdog waits 20 s (8 s cut into the normal opening load).
- End to end on one PC: host reply -> player 12 s -> opening skipped 6 s later -> 86 steps and the
  kit 4 s after that -> moving 2.5 m and turning the camera.
- A test game started with the user's last session less than 10 minutes old hosted a (friends-only)
  lobby by itself (auto-rejoin); left at once, nobody had joined. The dev bridge now sets
  _G.re9coop_test_no_rejoin.

## v0.11.0 (2026-10-18) — the guest loads the host's world

The second real session (host's log, the friend's report): items came back for the guest after
rejoining and every cutscene played again, the guest's box things were gone after rejoining, doors
stuck for the host, enemies stood in different places in the two games. The guest's new game (v0.10)
was a world of its own: the mod only patched parts of it (flows, gimmicks, box), not the items the
host had taken, the enemies killed, the events seen.

- Saves can't be handed over as files: they are encrypted per Steam account (the save service's
  encryption seed is the Steam ID). Not pursued.
- The game's save handlers instead (SaveServiceManager._GameSlotSaveHandlers, 37: CharacterManager,
  EventSaveManager (_EndTimelineEventArray: events seen), ItemManager (_PickedupItemHashes,
  _ItemBackups), GimmickManager, LevelFlowManager, MainGameFlowManager (the scene), ...): each
  implements IGameSlotSaveHandler.createGameSlotSavedata (what a save writes) and
  restoreGameSlotSavedata (what a load reads). Loading any save while every restore gets another
  game's created objects in place of the file's (sdk.hook pre, args[3] replaced) brings that world up
  exactly: a save of Leon in Chap3_20 came up as the captured Chap3_02 with Grace, to the centimetre.
- ext.worldx packs those objects for the network: types and field lists once; numbers, enums and
  structs without references as raw bytes (field offsets get_offset_from_base for objects,
  get_offset_from_fieldptr in structs, array data from 0x20 with the element size); strings and
  references through get_field / set_field (reference counting); arrays of base types keep their
  element type (names like "Dictionary`2.Entry[[A, asm..],[B, asm..]]" turned into "Entry<A,B>" for
  find_type_definition / create_managed_array); dictionaries and hash sets as plain objects (their
  _buckets / _entries copied; comparers left to the constructor). Named-constant objects (static
  fields of their own type, e.g. GuiMapSectionVariationID) go by name and are the same statics on
  the other side (copies broke hash sets keyed by them). Not packed: InventoryManager (it references
  the item catalog; the guest's things come from the kit, the box from the box sync),
  LayeredParamManager (flashlight user data), AchievementManager. 11.9k objects, 707 KB JSON,
  0.3 s to pack, 0.2 s to unpack; packed and unpacked again it matched itself field for field.
- The flow: the guest at the main menu asks (PLAY_REQ start); the host answers PLAY and sends its
  world (MSG.WORLD, 60 KB pieces, two a frame, a piece Steam can't queue yet tried again); a guest
  with a save of their own "Continues" (TitleFlowController.onContinue) with the restores taking the
  host's world; arrival = a new player object; then the kit as before. A guest without a save: the
  v0.10 new game. No world within 40 s: the new game too. The host sends its world again whenever it
  saves; a load in the co-op playthrough (game over, "Load") uses the last one, and asks for a new one.
  Verified on one PC (loopback for the network part, the title flow by feeding the pieces in): 5 s
  from the last piece to the player, control after the game's own fade.
- Rejoin: the lobby owner kept a partner who left as "synced" and sent nothing when they came back
  (story, gimmicks, box, recipes): the guest's box things were missing and their world unpatched.
  Now leaving (drop_peer) or starting a co-op playthrough clears that partner's sync, and the pickups
  made here go with every whole-world send.
- Doors: GmDoorV3.ActionType Lock (3, a locked door's rattle), Const and MotionSync aren't shared any
  more, only pushes (Normal, UniformSpeed), and a partner's push on a door we pushed in the last 1.5 s
  is dropped (ours and theirs fighting). A door locked in the guest's game made the host's rattle shut.
  Not reproduced on one PC.
- PROTO 10 (MSG.WORLD 36).

## Next steps
- [ ] Two-PC test over Steam (friend with the game): lobby, invite, P2P, puppet both ways.
- [ ] v0.2: muzzle flash / gun sound / flashlight on the puppet (find the game's shot effect call).
- [ ] v0.3: host-authoritative enemies (`CharacterManager:get_EnemyContextList()`), client damage
      forwarded to host.
- [ ] v0.4: doors / pickups / chapter flow follow the host.
