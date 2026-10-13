# RE9 Co-op (online) — v0.4.0

Online co-op for **Resident Evil Requiem** (Steam) through Steam lobbies and Steam's peer-to-peer
relay. Inspired by the local co-op mod *RE2 Co-op: HUNK* (Nexus, residentevil22019 mod 2938); no code
from it is used.

**What it does:**
- **Your partner in your world**: a fully posed character in their own costume — every animation they
  play, the gun in their hands, a name tag with the ping, their muzzle flash, gun sounds and
  flashlight.
- **Shared enemies**: each enemy is run by the player it's closest to, so enemies hunt, grab and hurt
  both of you. The other player sees the same enemy pose for pose; their hits on it count.
- **Shared doors and pickups**: a door your partner pushes open opens in your game too; an item your
  partner picks up disappears from yours.
- **Teleport to partner** (same chapter), and an on-screen note when you're in different chapters.

**Not shared yet:** key-locked doors (a key used by one player doesn't unlock the other's door),
events, cutscenes and story progress. Each of you still plays your own copy of the game and your own
inventory; load the same chapter (ideally the same save) to play together.

---

## Русский

**Что умеет:**
- **Напарник в вашем мире:** полноценный персонаж в своём костюме, со всеми анимациями, оружием в
  руках, ником и пингом над головой, вспышками выстрелов, звуками оружия и фонариком.
- **Общие враги:** каждым врагом управляет тот игрок, к которому он ближе, поэтому враги охотятся,
  хватают и ранят вас обоих. Второй игрок видит того же врага движение в движение, и его попадания
  засчитываются.
- **Общие двери и предметы:** дверь, которую толкнул напарник, открывается и у вас; предмет, который
  он подобрал, исчезает и у вас.
- **Телепорт к напарнику** (в пределах главы) и надпись на экране, если вы в разных главах.

**Пока не общее:** запертые на ключ двери (ключ одного игрока не открывает дверь у другого),
события, катсцены и сюжет. Каждый играет в своей копии игры со своим инвентарём — загружайте одну и
ту же главу (лучше одно и то же сохранение).

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
5. Через пару секунд напарник появится рядом. Если вы далеко друг от друга — **Teleport to partner**.

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
- Players: after animation every frame each game reads its player's 68-joint skeleton and sends it 20
  times a second (~600 bytes, ~100 kbit/s), with the flashlight's position, direction and strength.
  The partner's game builds a puppet from the same costume parts and skeleton file and plays the pose
  back with a 120 ms buffer. Its flashlight and muzzle flash are copies of the game's own flashlight
  light rig (lights created from scratch ignore their brightness).
- Enemies: the lobby owner decides who runs each enemy — the nearer player, with 3 m of hysteresis so
  enemies don't flip back and forth. The runner's game keeps the enemy's AI and sends its state 15
  times a second (the 4 nearest the partner with their full skeleton). The other game spawns the same
  enemy through its own spawn control (enemies are identified by their scene GUID), switches off its
  think, lock-on and out-of-area drivers, warps it and writes the runner's skeleton over its
  animation. Damage dealt to such a copy is caught and sent to the runner. When an enemy changes
  hands it keeps its health. Expect ~300–400 kbit/s each way with enemies.
- Doors: a door push (`GmDoorV3.addForce`) is replayed on the partner's copy of the same door.
  Pickups: `ItemCore.notifyPickupped` here despawns the partner's copy through its `ItemContext`.

## Roadmap
1. Key-locked doors and key items shared.
2. Following the host into the next chapter automatically.
3. Cutscenes: hide the partner and keep both players in step.
4. Later: Leon as the partner in Grace's chapters (and the reverse), downed/revive.

## Known limitations
- Both players need the same chapter loaded; the partner is hidden while you're in different areas.
- On the non-runner side, a dead enemy shows its death, but that game still counts it as alive (aim
  assist may still pick it).
- Gun sounds of a weapon the listener doesn't carry may be silent (its sound bank isn't loaded).
- Items dropped at runtime (e.g. by enemies) aren't shared.
- Tested on one PC only, with a built-in self test (an echo of yourself, and a second enemy copying
  the first through the network code). The first real two-PC session may still find problems — please
  send `re2_framework_log.txt` from both games.
- Don't use REFramework's *Reset scripts* button while co-op is on (it can crash the game); restart
  the game instead.

## Credits
- REFramework by praydog and contributors (Lua scripting and plugin API).
- File path list for RE9 paks: Ekey's REE.PAK.Tool project lists.
- Built with Claude (Anthropic) using the universal-modder toolkit.
