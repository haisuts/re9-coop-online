# RE9 Co-op (Online)

Online co-op mod for **Resident Evil Requiem** (PC / Steam) using Steam lobbies and Steam's peer-to-peer relay (`ISteamNetworkingMessages`).

> **Players:** Download the ready-to-install archive from [**Releases**](https://github.com/haisuts/re9-coop-online/releases/latest) (`RE9_Coop_Online_v0.12.9.zip`).
> **Developers:** Full Lua + C++ source code, build scripts, and offline tests are in this repository.

---

## Features

- **Full-body partner sync**: Costumes, hair, 68-joint animated skeleton, held weapons, flashlight, muzzle flashes, footsteps, breathing, gunshots, and name tag with HP% & ping.
- **Shared enemies & bosses**: Dynamic nearest-player enemy ownership (3 m hysteresis), full skeleton poses, synced hits/damage, boss runner locking, and full death sync (including across reconnects).
- **Shared world & story**:
  - Doors, drawers, levers, switches, breakables, locks, and puzzles (including parlor coin cabinets `Gm02_032`).
  - Story progression (`LevelFlowManager`), chapter transitions, synchronized/skippable cutscenes, and crafting recipe unlocks.
  - Shared item box (`ItemBox` / `ShareItemBox`) with live sync and merge on join.
  - Per-player weapons, key items, maps, and upgrades; shared ammo, healing, crafting materials, and enemy drops (configurable in menu).
- **Co-op playthrough & saving**: Host streams the world snapshot (MSZIP-compressed over Steam P2P) to a guest joining from the main menu without overwriting the guest's single-player saves.
- **Downed, revive & grab rescue**: Fatal hits down you while your partner is nearby; crouching beside your partner revives them, and shooting/meleeing an enemy grabbing your partner frees them.
- **Zero port forwarding**: Uses Steam's `ISteamNetworkingMessages` relay and Steam invites / Lobby IDs.

---

## Quick Install & Play (End Users)

1. Download **`RE9_Coop_Online_v0.12.9.zip`** from [**Releases**](https://github.com/haisuts/re9-coop-online/releases/latest).
2. Extract the archive into your **Resident Evil Requiem** folder (where `re9.exe` is located) and merge the `reframework` folder.
   - Everything needed (`dinput8.dll` from REFramework nightly `01432`, `re9coop_main.lua`, `re9coop_net.dll`, and licenses) is included.
3. Make sure **Steam** is running (with Steam Overlay enabled) and both players have the **same mod version**.
4. Launch the game through Steam.
5. Press **`Insert`** in-game → **`Script Generated UI`** → **`RE9 Co-op (online)`**.

### Hosting & Joining
- **Host:** Load your save (or start New Game) → click **`Host a co-op session`** → invite via **`Invite friends (Steam overlay)`** or click **`Copy lobby ID`** (enable **`Anyone with the ID can join`** if you aren't Steam friends).
- **Guest:** Stay on the **Main Menu** (do not load your solo save) → accept the Steam invite, or use **`Refresh friends` → `Join`**, or paste the ID into **`Lobby ID` → `Join by ID`**.

Full player guide, continuing a co-op run, troubleshooting, and uninstallation steps are in [`re9coop/README.md`](re9coop/README.md) (also bundled inside the release ZIP as `README_RE9_Coop.md`).

---

## Repository Layout

```text
re9coop/
  lua/autorun/re9coop_main.lua   # Main REFramework Lua co-op script
  plugin/
    src/                         # C++20 Steam lobby & ISteamNetworkingMessages plugin (re9coop_net.dll)
      plugin.cpp
      net.cpp / net.hpp
      steam_flat.hpp             # Flat C ABI bindings to game's steam_api64.dll
    build.bat                    # MSVC build script
  third_party/                   # REFramework MIT license & third-party notices
  README.md                      # Player documentation shipped in release ZIP
tools/
  package.py                     # Builds dist/RE9_Coop_Online_v<version>.zip
  globals_check.py               # Verifies zero accidental global accesses in Lua bytecode
  test_owner_decision.lua        # Offline unit tests for enemy ownership arbitration
  luacheck/                      # Minimal Lua 5.4.3 bytecode/local-limit checker
  stand.py, bridge.py, ...       # Local two-instance test stand & automation helpers
dev/                             # In-game dev bridge & diagnostic probe scripts
MODLOG.md                        # Reverse-engineering & testing journal
```

---

## Build from Source

### Prerequisites
- Windows x64
- Visual Studio 2022 / Build Tools with MSVC (`vcvars64.bat`) and Windows SDK (`cabinet.lib`, `ws2_32.lib`)
- Python 3.10+
- An unmodified checkout of [REFramework](https://github.com/praydog/REFramework) placed at `_deps/REFramework` (specifically for `include/reframework/API.h` and Lua `5.4.3` sources in `dependencies/lua/src`).

### Build & Verify
1. **Build the native Steam P2P plugin (`re9coop_net.dll`):**
   ```bat
   re9coop\plugin\build.bat
   ```
   Output: `re9coop\plugin\build\re9coop_net.dll`

2. **Build `luacheck.exe` (optional, for Lua 5.4.3 local-limit and global checks):**
   ```bat
   tools\luacheck\build.bat
   ```

3. **Run offline checks:**
   ```bat
   tools\luacheck\luacheck.exe re9coop\lua\autorun\re9coop_main.lua
   python tools\globals_check.py re9coop\lua\autorun\re9coop_main.lua
   tools\luacheck\luacheck.exe --run tools\test_owner_decision.lua
   ```

4. **Package the release ZIP:**
   ```bat
   python tools\package.py
   ```
   Downloads/verifies REFramework nightly `01432` (`dinput8.dll` by SHA-256) into `_deps/REFramework-nightly/` and writes `dist/RE9_Coop_Online_v<version>.zip`.

---

## Credits, License & AI Disclosure

- **Author & Maintainer:** [@haisuts](https://github.com/haisuts) ([Contributors](https://github.com/haisuts/re9-coop-online/graphs/contributors))
- **License:** Mod source code in this repository is licensed under the [MIT License](LICENSE). Bundled REFramework binaries are redistributed unmodified under REFramework's MIT License (`re9coop/third_party/`).
- **REFramework** by praydog and contributors.
- Inspired by *RE2 Co-op: HUNK* (Nexus Mods #2938); no code from it is used.
- RE9 asset/path references: Ekey's `REE.PAK.Tool`.
- **Tooling & AI Disclosure:** Built and tested using the [coop-anything](https://github.com/cranebeaker/coop-anything) and `universal-modder` plugins with AI coding agents (Claude by Anthropic and Gemini / Antigravity).
