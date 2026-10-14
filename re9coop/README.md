# RE9 Co-op (online) — v0.5.0

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
- **Story steps (experimental)**: every level-flow step either of you takes is taken by the other
  game too; a joining guest gets the host's chapter progress.
- **Chapters**: when the host moves on, the guest's game follows 5 s later (countdown on screen).
- **Locks, puzzles, switches**: their state goes to the partner and takes effect when that area loads
  in the partner's game.
- **Cutscenes**: the partner is hidden while either of you is in one.
- **Teleport to partner**, partner health in the name tag, public lobbies and a "Copy lobby ID" button.

**Not shared:** inventories (each keeps their own). A key used or a lever pulled by one player shows up
for the other only after that area reloads (running gimmicks follow their own state).

---

## Русский

**Что синхронизируется:**
- **Напарник в вашем мире:** персонаж в своём костюме со всеми анимациями, оружием, вспышками
  выстрелов, звуками оружия, фонариком; над головой ник, здоровье в % и пинг.
- **Враги:** каждым врагом управляет тот, к кому он ближе, — враги нападают на обоих; попадания
  обоих засчитываются; второй игрок видит того же врага движение в движение.
- **Двери:** толкнули дверь — она открывается и у напарника.
- **Предметы:** подобранный предмет исчезает и у напарника (инвентари у каждого свои).
- **Сюжет (экспериментально):** шаги сюжетных потоков главы (то, что запускает события) у одного
  повторяются у другого; при подключении гость получает весь прогресс главы хоста.
- **Главы:** если хост ушёл в другую главу, гость через 5 секунд переходит туда же (с отсчётом на
  экране); есть и кнопка «Go to partner's chapter».
- **Замки, загадки, переключатели:** их состояние передаётся напарнику и применяется, когда этот
  участок у него загрузится (см. ограничения).
- **Катсцены:** пока у кого-то из вас катсцена, напарник скрыт и не мешает.

### Установка (оба игрока)
1. **REFramework**: скачайте `REFramework.zip` (текущая ночная сборка) с
   https://github.com/praydog/REFramework-nightly/releases и положите **только** `dinput8.dll` в папку
   игры (где `re9.exe`).
2. Распакуйте архив мода в папку игры (папка `reframework` сольётся с существующей).
3. Версия мода у обоих должна совпадать.

### Как подключиться к лобби
Меню мода: в игре нажмите **Insert** → *Script Generated UI* → **RE9 Co-op (online)**.

**Хост (тот, чей мир и сюжет главные):**
1. Загрузите сохранение.
2. Если друг не у вас в друзьях Steam — поставьте галочку **Anyone with the ID can join**.
3. Нажмите **Host a co-op session**.
4. Пригласите друга одним из способов:
   - **Invite friends (Steam overlay)** → выберите друга → «Пригласить»;
   - или **Copy lobby ID** и отправьте этот номер другу в любой мессенджер.

**Гость (друг):**
1. Загрузите своё сохранение (лучше ту же главу; если другая — мод сам переведёт вас к хосту).
2. Подключитесь одним из способов:
   - примите приглашение в чате Steam (Shift+Tab) — мод подключится сам;
   - или в меню мода **Refresh friends** → **Join <имя хоста>**;
   - или вставьте номер в поле **Lobby ID** и нажмите **Join by ID**.
3. Через пару секунд вы увидите друг друга. Если далеко — **Teleport to partner**.

Если не подключается:
- «not a RE9 co-op lobby» / «host runs another mod version» — у вас разные версии мода;
- друг не видит вашу сессию в списке — включите «Anyone with the ID can join» и подключайтесь по ID;
- приглашения Steam работают только при включённом оверлее Steam;
- проброс портов не нужен (соединение идёт через сеть Steam).

**Self test** (флажок в меню) — проверка без друга: ваш персонаж повторяется «эхом» перед вами.

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
- Gimmicks: ~700 `GimmickContext`s per chapter are fingerprinted a slice per frame (their bool / int
  fields); changes travel as field lists and are applied with the game's own `store()` / `restore()`.
  The lobby owner sends them all on join. Gimmick global bit flags are OR-ed.
- Story: `LevelFlowManager.setProgressiveNumber` is hooked; the partner replays the step with
  `requestChangeProgressiveNumber`. Chapter jumps use `MainGameFlowManager.setOverrideNextJumpScene` +
  `LevelFlowManager.requestGameJump`.

## Roadmap
1. Live sharing of key items, levers and puzzles that are running (per gimmick kind, like door pushes).
2. Leon as the partner in Grace's chapters (and the reverse), downed/revive.

## Known limitations
- Both players need the same chapter loaded; the partner is hidden while you're in different areas.
- On the non-runner side, a dead enemy shows its death, but that game still counts it as alive (aim
  assist may still pick it).
- Gun sounds of a weapon the listener doesn't carry may be silent (its sound bank isn't loaded).
- Items dropped at runtime (e.g. by enemies) aren't shared.
- A key, lever or puzzle used by one player takes effect for the other only once that area reloads.
- Story sharing is experimental: a step can start a cutscene or move the other player.
- Tested on one PC only, with a built-in self test (an echo of yourself, and a second enemy copying
  the first through the network code). The first real two-PC session may still find problems — please
  send `re2_framework_log.txt` from both games.
- Don't use REFramework's *Reset scripts* button while co-op is on (it can crash the game); restart
  the game instead.

## Credits
- REFramework by praydog and contributors (Lua scripting and plugin API).
- File path list for RE9 paks: Ekey's REE.PAK.Tool project lists.
- Built with Claude (Anthropic) using the universal-modder toolkit.
