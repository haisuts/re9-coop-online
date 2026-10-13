# RE9 Co-op (online) — v0.1.0

Online co-op for **Resident Evil Requiem** (Steam) through Steam lobbies and Steam's peer-to-peer
relay. Inspired by the local co-op mod *RE2 Co-op: HUNK* (Nexus, residentevil22019 mod 2938); no code
from it is used.

**What v0.1 does:** your friend appears in your game as a fully posed character — their own costume,
every animation they play (walk, run, crouch, aim, reload...), the gun in their hands and a name tag
with the ping — and you appear in theirs. You see each other only while you're in the same chapter
area.

**What v0.1 doesn't do yet:** each of you still plays your own copy of the game. Enemies, items,
doors, cutscenes and story progress are not shared, and your partner's shots don't hurt your enemies.
That is the next stage (see Roadmap).

---

## Русский

**Что умеет v0.1:** напарник по Steam появляется в вашей игре полноценным персонажем — в своём
костюме, со всеми анимациями (ходьба, бег, присед, прицеливание, перезарядка), с оружием в руках и
ником над головой (с пингом), а вы — у него. Видно друг друга, когда вы в одной и той же области
главы.

**Пока не умеет:** каждый играет в своей копии игры — враги, предметы, двери, катсцены и сюжет не
общие, выстрелы напарника по вашим врагам не наносят урон. Это следующий этап (см. Roadmap).

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

## Roadmap
1. **v0.2 — shots and effects:** muzzle flash, gun sounds and flashlight on the partner.
2. **v0.3 — shared enemies (host decides):** the client's enemies follow the host's (position, pose,
   health, death); the client's hits are sent to the host and applied there.
3. **v0.4 — shared progress:** doors, pickups, chapter changes and cutscenes follow the host.
4. Later: Leon as the partner in Grace's chapters (and the reverse), downed/revive, shared inventory.

## Known limitations
- Both players need the same chapter loaded; the partner is hidden while you're in different areas.
- The partner's character model is whatever character they play (Grace or Leon).
- Don't use REFramework's *Reset scripts* button while the partner is shown (it can crash the game);
  restart the game instead.

## Credits
- REFramework by praydog and contributors (Lua scripting and plugin API).
- File path list for RE9 paks: Ekey's REE.PAK.Tool project lists.
- Built with Claude (Anthropic) using the universal-modder toolkit.
