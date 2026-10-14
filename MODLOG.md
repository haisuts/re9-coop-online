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

## Next steps
- [ ] Two-PC test over Steam (friend with the game): lobby, invite, P2P, puppet both ways.
- [ ] v0.2: muzzle flash / gun sound / flashlight on the puppet (find the game's shot effect call).
- [ ] v0.3: host-authoritative enemies (`CharacterManager:get_EnemyContextList()`), client damage
      forwarded to host.
- [ ] v0.4: doors / pickups / chapter flow follow the host.
