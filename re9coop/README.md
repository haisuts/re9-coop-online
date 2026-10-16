# RE9 Co-op (online) — v0.9.2

Online co-op for **Resident Evil Requiem** (Steam) through Steam lobbies and Steam's peer-to-peer
relay. Inspired by the local co-op mod *RE2 Co-op: HUNK* (Nexus, residentevil22019 mod 2938); no code
from it is used.

**What it does:**
- **Your partner in your world**: a fully posed character in their own costume — every animation they
  play, the gun in their hands, a name tag with the ping, their muzzle flash, gun sounds and
  flashlight.
- **Shared enemies**: each enemy is run by the player it's closest to, so enemies hunt, grab and hurt
  both of you. The other player sees the same enemy pose for pose; their hits on it count, and an enemy
  killed by one player is dead in the other's game too.
- **Shared doors and pickups**: a door your partner pushes open opens in your game too; an item your
  partner picks up disappears from yours.
- **Story steps (experimental)**: every level-flow step either of you takes is taken by the other
  game too; a joining guest gets the host's chapter progress.
- **Chapters**: when the host moves on, the guest's game follows 5 s later (countdown on screen).
- **Locks, keys, puzzles, switches — live**: a lock one player opens (with a key or otherwise) opens
  in the partner's game too, right away, without any scene for the partner's character; items placed
  into puzzle slots count for both; switch positions and other gimmick states follow as soon as the
  partner is near them. Gimmicks in areas the partner hasn't loaded take the state when they load.
  Either player can solve a puzzle: the guest's solution counts in the host's game the same way.
  Solved puzzles look solved for the partner at once: a coin locker opens (its item can be taken),
  the sun quartz safe opens, the pencil rubbing shows the note, the sun / moon / star door shows the
  emblems put in, the moon quartz comes out of its cabinet.
- **Crafting recipes for both**: a recipe one player unlocks (a recipe file, the blood analysis at the
  laser microscope) is unlocked in the partner's game too, marked as new.
- **Boss fights**: a boss is run by one player for the whole fight (the one nearer when it appears),
  so its phases and attack patterns aren't broken by handing it back and forth. The other player sees
  it move for move and their hits count. It only changes hands when its player leaves the fight.
- **Cutscenes**: the partner is hidden while either of you is in one.
- **Downed, not dead**: while your partner is with you, a hit that would kill you leaves you on your
  last breath instead — you can't move or shoot, enemies can't hurt you more — and your partner gets
  you up by crouching next to you for 2.5 s (you come back with a third of your health). If nobody
  gets you up within 30 s, you come to next to your partner (no game over). If your partner leaves, or
  you both go down, it's game over as usual.
- **After a game over**: the player who died continues from their last save as usual; the partner who
  stayed sends them the chapter as it is now (story steps, locks and puzzles, item box, recipes, the
  pickups made), so their world catches up instead of the other one going back.
- **Cutscenes together**: a cutscene one of you skips is skipped for the other too.
- **Where your partner is**: on the game's map (a dot with their name, "above" / "below" for another
  floor) and, when they're out of sight, their name and distance at the edge of the screen.
- **Enemy drops for both**: what an enemy leaves is there in both games, at the same spot; whoever
  picks it up takes it (or each player their own with the "each picks up their own" option).
- **Reconnecting**: if the session drops (or a game crashes and is restarted), it is joined again by
  itself — the guest finds the host's session, the host hosts again.
- **Grabs**: when an enemy grabs you, your partner frees you by shooting that enemy or hitting it
  (knife, kick) next to you; the grab ends at once.
- **Weapons and key items for both**: a weapon, key item, file, map or upgrade one player picks up stays
  in the world for the other to pick up their own copy. Ammo, healing items and crafting materials are
  shared (whoever takes them first) — or each player's own with "Ammo, healing and materials: each
  player picks up their own".
- **One item box for both**: what one player puts in the item box, the other finds in theirs and can
  take out (guns keep their loaded ammo).
- **Saving together**: whenever the host's game saves (autosave or typewriter), the guest's game makes
  an autosave too. To go on later: both load their latest save, the host hosts, the guest joins — the
  host's progress (story, locks, puzzles, box) is sent on joining and the guest follows the host's
  chapter.
- **Teleport to partner**, partner health in the name tag, public lobbies and a "Copy lobby ID" button.

**Not shared:** what you carry (each keeps their own inventory, saved in their own save).

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
- **Замки, ключи, загадки, переключатели — сразу:** замок, открытый одним (ключом, жетоном, деталью),
  тут же открывается и у другого — без сцены с его персонажем и не отнимая у него управление; предметы, вставленные в загадку,
  засчитываются обоим; положения переключателей и другие состояния подтягиваются, когда напарник
  рядом с ними. Загадку может решить любой из двоих — решение гостя засчитывается в игре хоста так же.
  Решённая загадка сразу выглядит решённой и у напарника: шкафчик с монетами открыт (предмет внутри
  можно взять), сейф с солнечным кварцем открыт, штриховка в блокноте показывает записку, в окне
  двери «солнце / луна / звезда» видны вставленные эмблемы, лунный кварц выдвинут из шкафа.
  Исключения: лампа, разбитая выстрелом в Chap3_01, у напарника продолжает гореть; загадка с образцом
  под лазером в больнице у напарника выглядит нерешённой (её можно пройти ещё раз и увидеть тот же
  код). То, что они открывают (сюжет, двери, флаги), передаётся сразу.
- **Рецепты крафта — обоим:** рецепт, открытый одним (записка с рецептом, анализ пробы крови на
  лазерном микроскопе), открывается и у напарника (с пометкой «новое»).
- **Не встал — очнулся рядом с напарником:** если вас не подняли за 30 секунд, вы приходите в себя
  рядом с напарником (без экрана смерти).
- **После смерти:** погибший продолжает с последнего сохранения, а напарник, который остался в игре,
  досылает ему главу как она есть сейчас (сюжет, замки, загадки, ящик, рецепты, подобранные
  предметы) — мир погибшего догоняет, а не откатывает напарника.
- **Катсцены вместе:** пропустил один — пропускается и у второго.
- **Где напарник:** точка с ником на карте игры («above» / «below» — другой этаж) и ник с расстоянием
  у края экрана, когда напарника не видно.
- **Выпавшее из врагов — общее:** предмет появляется у обоих в том же месте; кто подобрал — того и
  предмет (или каждому свой при «каждому свои»).
- **Переподключение:** если связь оборвалась (или игра вылетела и вы её перезапустили), мод сам
  подключится снова: гость находит сессию хоста, хост создаёт её заново.
- **Ящик:** если оба одновременно взяли одну вещь, она остаётся у хоста, у гостя дубль убирается.
- **Боссы:** босса весь бой ведёт один игрок (тот, кто был ближе, когда босс появился), поэтому его
  фазы и атаки не ломаются от передачи туда-сюда. Второй видит его движение в движение, его попадания
  засчитываются. Босс переходит к другому, только если его игрок ушёл из боя.
- **Катсцены:** пока у кого-то из вас катсцена, напарник скрыт и не мешает.
- **Убитые враги:** враг, убитый одним игроком, мёртв и в игре второго (не «живой труп»).
- **Без сознания вместо смерти:** пока напарник рядом (та же глава, на связи), смертельный удар
  оставляет вас «при смерти»: двигаться и стрелять нельзя, враги больше не ранят. Напарник
  **приседает рядом с вами 2,5 секунды** — вы встаёте с третью здоровья. Если напарник отключился или
  без сознания оба — обычный экран смерти.
- **Захват:** если вас схватил враг, напарник освобождает вас, **выстрелив в этого врага или ударив
  его ножом/пинком рядом с вами** — захват сразу прерывается.
- **Оружие и ключевые предметы — каждому:** оружие, ключевые предметы, файлы, карты, улучшения,
  подобранные одним, остаются в мире для второго — он берёт свой экземпляр. Патроны, лечение и
  материалы для крафта — общие (кто первый взял); в меню можно включить «каждому свои».
- **Общий ящик предметов:** положили вещь в ящик — она появляется в ящике у напарника, и он может её
  забрать (и наоборот). Оружие переносится вместе с заряженными патронами. Пока ящик у вас открыт,
  изменения от напарника ждут, пока вы его закроете. Передаётся только то, что игрок сам сделал в
  ящике (стартовые наборы, которые игра кладёт в ящики в начале глав, у каждого свои — без дублей).
- **Совместное сохранение:** когда сохраняется игра хоста (автосейв или печатная машинка), игра гостя
  тут же делает автосейв (в слот автосохранения — ручные слоты гостя не трогаются). Если сохранить
  сейчас нельзя (катсцена, загрузка, бой, где игра запрещает сохранение), гость сохранится, как только
  станет можно.

### Как продолжить прохождение в другой день
1. Оба запускают игру и выбирают **«Продолжить»** (последнее сохранение — у гостя это совместный
   автосейв).
2. Хост создаёт сессию, гость подключается (см. ниже).
3. При подключении хост сам отправляет гостю прогресс главы (сюжет, замки, загадки) и содержимое
   ящика; если гость в другой главе — через 5 секунд он перейдёт к хосту. Инвентарь у каждого свой —
   тот, с которым он сохранился.

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

## Tested
With one PC (self-test echo + simulated partner messages), 2026-10-15:
- Every chapter scene that can be loaded directly: Chap1_01, 1_10, 3_01, 3_02, 3_0304, 3_04, 3_05,
  3_06, 3_10, 3_20, 3_324, 3_40, 4_1020, 4_20, 4_30, 4_4050, 5_02, 5_10 (Grace and Leon): the
  partner's character builds, doors, items, gimmicks, triggers and enemies are found, no mod errors,
  no crash over ~30 chapter changes. Chap5_03 / 5_04 / 5_05 and the ff scenes are only entered through
  the story, so they weren't loaded directly.
- Downed (a real zombie bite), revive, bleed-out game over; grab freed by the partner's hit and by
  their melee; the item box through the game's own box screen; key-locked gate opened for the partner.
- v0.8.0: the laser microscope (blood analysis puzzle) solved for real, then replayed as the partner:
  the partner gets both recipes and can still use the microscope. A boss (the hospital's cp_C100,
  6000 HP, 100 joints) as the partner's copy: woken and posed from the owner's data, real pistol hits
  on it land on the owner's side, and it gets its AI back when it changes hands.
- v0.9.0: going down and coming to next to the partner, a real game over and continue, the "I loaded"
  / "I stayed" exchange and the resend, a real cutscene skipped from the partner's message and our
  skip sent (both ways), the partner's dot on the game's map and the edge marker, an enemy-style drop
  made in the partner's game and taken away by their pickup, reconnecting (net plugin stubbed).
- v0.9.1: locks solved for real (a padlock, three security-tag doors, the sun / moon / star door)
  and played back as the partner: every field of the lock matches, the partner's controls stay free;
  the heart / lung slots again; every puzzle type of every loadable chapter checked for whether its
  state follows the partner's data.
- v0.9.2: a coin locker, the moon and sun quartz cabinets, the pencil rubbing and the hint panel
  solved for real (by the game's own controls), then played back as the partner on a fresh game:
  the locker's glass door opens and its item can be taken, the safe opens with its items, the
  notebook shows the note and gives the document, the emblems show in the door window, and putting
  in an emblem afterwards works as usual.
- Not yet: a real two-PC session, a whole boss fight from its entrance to its death.

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
  hands it keeps its health. Bosses (cp_B700, C100, C510, C900, D100, D110, B052, C610) keep their
  runner for the whole fight and always get their full skeleton; a boss that spawns asleep waiting for
  its entrance is woken in the other game when the runner's is up. Expect ~300–400 kbit/s each way
  with enemies.
- Crafting recipes: `ItemManager._UnlockedCraftRecipeIDSet` is compared every 2 s; the names go to
  the partner, whose game unlocks the missing ones with `unsealCraftRecipe`.
- Doors: a door push (`GmDoorV3.addForce`) is replayed on the partner's copy of the same door.
  Pickups: `ItemCore.notifyPickupped` here despawns the partner's copy through its `ItemContext`.
- Gimmicks: ~700 `GimmickContext`s per chapter are fingerprinted a slice per frame (their bool / int
  fields); changes travel as field lists and are applied with the game's own `store()` / `restore()`.
  The lobby owner sends them all on join. Gimmick global bit flags are OR-ed.
- Story: `LevelFlowManager.setProgressiveNumber` is hooked; the partner replays the step with
  `requestChangeProgressiveNumber`. Chapter jumps use `MainGameFlowManager.setOverrideNextJumpScene` +
  `LevelFlowManager.requestGameJump`.

- Item box: both games' item boxes (`app.Inventory`, board types ItemBox / ShareItemBox) are read
  twice a second; what changed goes to the partner as "+item" / "-item" operations, applied with
  `addPanel` + `reloadDirect` / `removePanel`. Inventories are changed only inside the game's GUI update
  (where the game's own item box moves items); changing them from REFramework's frame callbacks
  crashed the game on a worker thread. On joining, the boxes are merged (nothing is lost).
- Live gimmicks: the partner's gimmick fields are written straight into the context's live
  `StructureData` objects (`StructureDataContainer._Structures`), the ones the running gimmick reads;
  `GimmickContext.restore()` swaps in copies the running gimmick never sees. Locks: the interact
  triggers a `GmLockV2` unlocks on (`_UnlockParams._TriggerName`: "UseKeyItem_Success", "TurnOff" sent
  at the end of the key scene, ...) and the key-item success triggers are caught in
  `InteractTrigger.onProcessEvent` and fired on the partner's copy of the gimmick (by context ID).
- Saves: the host's save is noticed by `SaveServiceManager`'s serial number moving to a game slot; the
  guest then runs `GuiManager.AutoSaveFlow.requestAutoSave` with the game's default settings (Auto
  slot, empty or oldest).

## Roadmap
1. Leon as the partner in Grace's chapters (and the reverse): the game creates one playable character
   per chapter (LevelPlayerCreateController); a second one needs its resources loaded there.
2. Bosses attacking the player who doesn't run them.

## Known limitations
- Both players need the same chapter loaded; the partner is hidden while you're in different areas.
- If both players take the same thing out of the item box at the same moment, the host keeps it and
  the guest's copy is taken from their hands (if it's still there as it came out).
- After a game over the player who died starts from their own last save; the partner's chapter state
  is sent to them, but they still have to walk (or "Teleport to partner") back to them.
- The guest's co-op save is an autosave: it takes the place of the guest's oldest autosave, like the
  game's own autosaves do.
- Gun sounds of a weapon the listener doesn't carry may be silent (its sound bank isn't loaded).
- Of the items the game makes during play, only enemy drops are shared; anything else it spawns is
  each player's own.
- A hanging lamp shot out in Chap3_01 stays lit in the partner's game. The specimen puzzle in the
  hospital (rotating it under the laser) shows as not done to the partner, who can do it to read
  the same code. What they unlock (story, doors, flags) is shared at once.
- A boss (and any enemy) attacks only the player who runs it; the other player can't be hurt by it.
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
