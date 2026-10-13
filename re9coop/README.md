# RE9 Co-op (online) — v0.3.0

Online co-op for **Resident Evil Requiem** (Steam) through Steam lobbies and Steam's peer-to-peer
relay. Inspired by the local co-op mod *RE2 Co-op: HUNK* (Nexus, residentevil22019 mod 2938); no code
from it is used.

**What it does:**
- **Your partner in your world** (v0.1): a fully posed character in their own costume — every
  animation they play, the gun in their hands and a name tag with the ping.
- **Shots** (v0.2): their muzzle flash (a burst of light at the gun) and their gun sounds — shot,
  tail, slide, raise and lower — played where they stand.
- **Shared enemies** (v0.3): the lobby owner (host) runs the enemies. The guest's game spawns the same
  enemies, switches their AI off and shows exactly what they do on the host, pose for pose. The
  guest's hits are sent to the host and hurt the real enemy there, so both of you can kill them.

**Not shared yet:** items, doors, events, cutscenes and story progress — each of you still plays your
own copy of the game. Enemies only attack the host for now.

---

## Русский

**Что умеет:**
- **Напарник в вашем мире** (v0.1): полноценный персонаж в своём костюме, со всеми анимациями, с
  оружием в руках и ником над головой (с пингом). Вы так же видны у него.
- **Выстрелы** (v0.2): вспышка у ствола напарника и звуки его оружия (выстрел, затвор, подъём и
  опускание) — там, где он стоит.
- **Общие враги** (v0.3): врагами управляет хост (создатель лобби). У гостя появляются те же враги
  с выключенным ИИ и повторяют всё, что они делают у хоста, движение в движение. Попадания гостя
  уходят хосту и ранят настоящего врага — убивать их можете оба.

**Пока не общее:** предметы, двери, события, катсцены и сюжет — каждый играет в своей копии игры.
Враги пока нападают только на хоста.

### Установка
1. Установите **REFramework** — текущую ночную сборку (`REFramework.zip` с
   https://github.com/praydog/REFramework-nightly/releases). Скопируйте из архива только `dinput8.dll`
   в папку игры (там, где `re9.exe`).
2. Распакуйте этот архив в папку игры: папка `reframework` сольётся с уже существующей.
   - `reframework/autorun/re9coop_main.lua` — сам мод;
   - `reframework/plugins/re9coop_net.dll` — сетевая часть (Steam).
3. Оба игрока ставят одну и ту же версию мода.

### Как играть вместе
1. Оба запускают игру через Steam и загружают **одну и ту же главу** (лучше одинаковое сохранение).
2. Откройте меню REFramework клавишей **Insert** → *Script Generated UI* → **RE9 Co-op (online)**.
3. Хост нажимает **Host a co-op session**, затем **Invite friends (Steam overlay)** и приглашает друга.
4. Друг принимает приглашение в Steam — мод сам подключится. Либо в том же меню друг жмёт
   **Refresh friends** → **Join <имя хоста>**, либо вводит *Lobby ID* и жмёт **Join by ID**.
5. Через пару секунд напарник появится рядом (если вы в одной области главы).

**Self test** (флажок в меню) — проверка без друга: ваш персонаж повторяется «эхом» перед вами с
задержкой 150 мс, через тот же сетевой путь, что и у напарника.

### Удаление
Удалите `reframework/autorun/re9coop_main.lua`, `reframework/plugins/re9coop_net.dll` и
`reframework/data/re9coop_config.json`.

---

## How it works
- `re9coop_net.dll` (REFramework plugin, C++): uses the game's own `steam_api64.dll` — a friends-only
  Steam lobby (max 2–4 players), `ISteamNetworkingMessages` P2P through Steam's relay (no port
  forwarding, IPs stay hidden), Steam invites and "Join game". It only accepts data from members of
  your lobby.
- `re9coop_main.lua`: after animation every frame it reads your player's 68-joint skeleton and sends it
  20 times a second (~600 bytes, ~100 kbit/s). The partner's game builds a puppet from the same costume
  parts and skeleton file, and plays the pose back with a 120 ms buffer for smoothness. The puppet has
  no AI and no collision.
- Enemies: the host sends each spawned enemy 15 times a second (position, rotation, health; the 4
  nearest the guest with their full skeleton, ~650 bytes each). The guest spawns the same enemy through
  its own spawn control (enemies are identified by their scene GUID), switches off its think and
  lock-on drivers, warps it to the host's position and writes the host's skeleton over its animation.
  The guest's damage (`HitPoint.addDamageHitPoint` / `addDamageReactionHP`) is caught, sent to the host
  and applied there. The guest's own spawn logic is not allowed to put away an enemy the host still
  has. When co-op ends, every enemy gets its AI back. Expect ~300–400 kbit/s each way with enemies.

## Roadmap
1. ~~v0.2 — shots and effects~~ (flashlight on the partner still to do).
2. ~~v0.3 — shared enemies, host decides~~. Next: enemies also attack the guest.
3. **v0.4 — shared progress:** doors, pickups, chapter changes and cutscenes follow the host.
4. Later: Leon as the partner in Grace's chapters (and the reverse), downed/revive, shared inventory.

## Known limitations
- Both players need the same chapter loaded; the partner is hidden while you're in different areas.
- Enemies attack only the host. The guest can't be hurt by them yet.
- On the guest, an enemy the host killed shows its death, but the guest's game still counts it as
  alive (aim assist may still pick it).
- Gun sounds of a weapon the guest doesn't carry may be silent on the guest (its sound bank isn't
  loaded there).
- Shared enemies have only been tested on one PC with a built-in test (a second enemy copying the
  first through the network code); the first real two-PC session may still find problems.
- The partner's character model is whatever character they play (Grace or Leon).
- Don't use REFramework's *Reset scripts* button while the partner is shown (it can crash the game);
  restart the game instead.

## Credits
- REFramework by praydog and contributors (Lua scripting and plugin API).
- File path list for RE9 paks: Ekey's REE.PAK.Tool project lists.
- Built with Claude (Anthropic) using the universal-modder toolkit.
