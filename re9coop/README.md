# RE9 Co-op (Online) — v0.12.9

Online co-op mod for **Resident Evil Requiem** (Steam) using Steam lobbies and Steam's peer-to-peer relay (`ISteamNetworkingMessages`). No port forwarding or VPN required.

Inspired by *RE2 Co-op: HUNK* (Nexus Mods #2938); written completely from scratch for Resident Evil Requiem.

---

## Requirements

- **Resident Evil Requiem** (Steam version, PC)
- **Steam** running with Steam Overlay enabled (for Steam invites)
- Both players must use the **exact same mod version** (`v0.12.9`)
- Everything else needed (`dinput8.dll` REFramework nightly `01432`, Lua mod script, and `re9coop_net.dll`) is included in the release ZIP.

---

## Installation (Both Players)

1. Download **`RE9_Coop_Online_v0.12.9.zip`** from the [GitHub Releases page](https://github.com/haisuts/re9-coop-online/releases/latest).
2. Open your **Resident Evil Requiem** installation folder (the folder containing `re9.exe`, typically `...\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem`).
3. Extract the ZIP directly into that folder and allow folders/files to merge:
   - `dinput8.dll` — REFramework nightly build `01432` (commit `d052e8f`), unmodified. Replaces an older `dinput8.dll` if you already have REFramework installed.
   - `reframework/autorun/re9coop_main.lua` — Main co-op mod script.
   - `reframework/plugins/re9coop_net.dll` — Native Steam lobby & P2P networking plugin (uses the game's own `steam_api64.dll`; no extra runtimes needed).
   - `licenses/` — REFramework license and third-party notices.
4. Launch **Resident Evil Requiem** through Steam.

---

## How to Play Together

In-game, press **`Insert`** to open the REFramework menu, then open **`Script Generated UI` → `RE9 Co-op (online)`**.

### Host (Your World & Story Are Shared)
1. Load your save (or start a **New Game**).
2. *(Optional)* If your friend is not on your Steam friends list, enable **`Anyone with the ID can join`**.
3. Click **`Host a co-op session`**.
4. Invite your friend in one of two ways:
   - Click **`Invite friends (Steam overlay)`** and invite them via Steam, **or**
   - Click **`Copy lobby ID`** and send the Lobby ID to your friend.

### Guest (Joining the Host's World)
1. Stay on the **Main Menu** — do **not** load your own single-player save first. The mod automatically loads the host's world snapshot into your game without touching your personal save slots.
2. Join using any method:
   - Accept the Steam invite (`Shift+Tab`) — the mod joins automatically, **or**
   - In the mod menu, click **`Refresh friends`** → **`Join <host name>`**, **or**
   - Paste the host's Lobby ID into **`Lobby ID`** and click **`Join by ID`**.
3. Your game receives the host's compressed world snapshot over Steam P2P and spawns you next to the host.
4. If you spawn far apart, use **`Teleport to partner`** in the mod menu.

### Continuing a Co-op Run on Another Day
1. **Host:** Launch the game, click **Continue** to load your save, and click **`Host a co-op session`**.
2. **Guest:** Launch the game, stay at the **Main Menu**, and join the host's lobby.
3. The guest automatically receives the host's world again, and the mod restores the guest's own carried inventory/gear saved for that host (`reframework/data/re9coop_coop_<HostSteamID>.json`).

---

## Features

- **Full-body partner puppet**: Costumes/hair, 68-joint animated poses, equipped weapon, muzzle flash, flashlight, footsteps, breathing, gun sounds, name tag with ping and HP%.
- **Shared enemies & bosses**: Each enemy is simulated by the nearest player (with 3 m hysteresis); the partner sees a pose-synced puppet whose hits register on the owner. Bosses (`cp_B700`, `C100`, `C510`, `C900`, `D100`, `D110`, `B052`, `C610`) stay with one runner unless they go down/leave. Killed enemies (including already-despawned enemies when reconnecting) sync across both games.
- **Shared world & progress**:
  - Doors (`GmDoorV3`), drawers, levers, switches, breakables, and puzzle locks/counters (including coin lockers / parlor cabinets `Gm02_032`, sun/moon/star emblems, safes, and pencil rubbing).
  - Story steps (`LevelFlowManager`), chapter transitions, and synchronized/skippable cutscenes.
  - Crafting recipes unlocked by one player unlock for both.
  - Shared item box (`ItemBox` / `ShareItemBox`) with live add/remove sync and merge on join.
  - Weapons, key items, maps, and upgrades are per-player; ammo, healing, materials, and enemy drops are shared (or per-player via the menu toggle).
  - **"Give your partner"** menu action drops healing/ammo/materials/subweapons from your hands in both games.
- **Co-op survival & reconnect**:
  - **Downed state**: Fatal hits put you into a downed state while your partner is alive nearby; crouching beside a downed partner for 2.5 s revives them (or auto-revive at partner after 30 s).
  - **Grab rescue**: Shooting or meleeing an enemy grabbing your partner frees them immediately.
  - **Auto-reconnect & out-of-bounds rescue**: Automatically rejoins after drops/crashes and pulls players back if they fall below the map.
- **Sync Check diagnostic**: Automatic and manual (`Check sync with partner`) comparison of story flows, gimmicks, items, enemies, and player puppets, written to `reframework/data/re9coop_sync_report.txt`.

---

## Troubleshooting

- **`not a RE9 co-op lobby` / `host runs another mod version`**: Both players must be on the exact same mod version (`v0.12.9`).
- **Friend doesn't see the session**: Enable **`Anyone with the ID can join`** on the host and connect via **`Copy lobby ID`** → **`Join by ID`**.
- **Steam invites don't open / fail**: Make sure the Steam Overlay is enabled in Steam settings for Resident Evil Requiem.
- **Port forwarding**: Not required; traffic goes over Steam's `ISteamNetworkingMessages` relay / direct P2P.
- **Script crash when clicking "Reset scripts"**: Do not use REFramework's *Reset scripts* button while co-op is active; restart the game instead.
- **Logs & diagnostics**: Check `re2_framework_log.txt` in the game folder and `reframework/data/re9coop_sync_report.txt` from both players when debugging issues.

---

## Uninstall

Delete the following files from your Resident Evil Requiem folder:
- `reframework/autorun/re9coop_main.lua`
- `reframework/plugins/re9coop_net.dll`
- `reframework/data/re9coop_config.json` (and optional `re9coop_coop_*.json` / `re9coop_sync_report.txt`)
- Delete `dinput8.dll` only if you do not use any other REFramework mods.

---

## Known Limitations

- Both players must be in the same chapter; the partner puppet is hidden across area/chapter boundaries until both load into the same area.
- Sound effects for a weapon the listener does not hold may not play if its sound bank is not loaded in memory.
- Hanging lamps in `Chap3_01` can desync visually between clients; their shared light switch stays synced.

---

## Changelog Highlights

- **v0.12.9**: Fixed shared pickups reappearing after reconnect (`ext.send_pickups` now includes already-taken shared items in `world.items` + `world.pending_taken` queue), fixed dead/despawned zombies staying alive or lying frozen on reconnect (`MSG.ENEMIES_DEAD` + `foes.kill_step`), improved shared item box change detection (`app.Inventory` hooks + `_GuiItemBoxHandle` + 10 s window), and fixed parlor coin counter `Gm02_032` (`_LeftUsageCount`) live sync in `gim.catch_up`.
- **v0.12.8 (`net 0.3.3`)**: Added MSZIP world-snapshot compression (`~765 KB -> ~131 KB`), Steam relay status & direct/relay P2P diagnostics, pinned host lobby key, and auto-reset of broken P2P sessions.

---

## Credits & AI Disclosure

- **Author & Contributors:** [@haisuts](https://github.com/haisuts) ([Contributors](https://github.com/haisuts/re9-coop-online/graphs/contributors))
- **REFramework** by praydog and contributors (MIT License), bundled unmodified as `dinput8.dll` with notices in `licenses/`.
- Inspired by *RE2 Co-op: HUNK* (Nexus Mods #2938); no code reused.
- RE9 file path lists reference Ekey's `REE.PAK.Tool` project.
- Built and verified using the [coop-anything](https://github.com/cranebeaker/coop-anything) and `universal-modder` plugins with AI coding agents (Claude by Anthropic and Gemini / Antigravity).
