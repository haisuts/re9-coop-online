"""Both stand games through every main-game chapter (dev tool; needs tools/stand.py start + coop first).

usage: python tools/stand_sweep.py OUT_DIR [Chap1_00 Chap1_01 ...]
For each chapter: the host jumps there (MainGameFlowManager.setOverrideNextJumpScene +
LevelFlowManager.requestGameJump, inside the game's GUI update); the guest is left to follow the host the
mod's way, and is sent there directly if it hasn't in 45 s. Cutscenes are skipped in each window. Once
both are in: each game's self test, the guest's sync check against the host, both copies of the other
player, the mod's error lines in both logs, the chapter's boss kinds, a screenshot of each window.
Results go to OUT_DIR/sweep.json (a chapter already done is skipped: run again to go on).
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GAMES = {"1": r"E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem",
         "2": r"E:\RE9coop_stand\game2"}
ALL = ["Chap1_00", "Chap1_01", "Chap1_10", "Chap3_01", "Chap3_02", "Chap3_03", "Chap3_0304", "Chap3_04", "Chap3_05",
       "Chap3_06", "Chap3_10", "Chap3_20", "Chap3_324", "Chap3_40", "Chap4_00", "Chap4_10", "Chap4_1020", "Chap4_20",
       "Chap4_30", "Chap4_40", "Chap4_4050", "Chap4_50", "Chap5_02", "Chap5_03", "Chap5_04", "Chap5_05", "Chap5_10",
       "ff_01", "ff_02"]
BOSSES = ["cp_B700", "cp_C100", "cp_C510", "cp_C900", "cp_D100", "cp_D110", "cp_B052", "cp_C610", "cp_B800", "cp_B032",
          "cp_B002", "cp_D000"]
GUI_OP = ("if not dev.gui_op then dev.gui_op = true "
          "sdk.hook(sdk.find_type_definition('app.GuiAutoSaveFlowController'):get_method('update'), "
          "function() local op = dev.op if op then dev.op = nil local ok, r = pcall(op) dev.op_result = { ok = ok, r = tostring(r) } end end, nil) "
          "end return 'ok'")


def bridge(game, code, timeout=20):
    try:
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "bridge.py"), "-g", game, code, "-t", str(timeout)],
                           capture_output=True, text=True, timeout=timeout + 15)
    except subprocess.TimeoutExpired:
        return 1, "timeout"
    return r.returncode, (r.stdout + r.stderr).strip()


def windows():
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          "Get-Process re9 | ForEach-Object { $_.MainWindowHandle.ToString() + '|' + $_.Path }"],
                         capture_output=True, text=True).stdout
    w = {}
    for line in out.splitlines():
        if "|" in line:
            h, path = line.split("|", 1)
            w["2" if "RE9coop_stand" in path else "1"] = h.strip()
    return w


def front(game):
    h = windows().get(game)
    if h:
        subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(HERE, "fg.ps1"), h],
                       capture_output=True)
    return h


# the game's own skip (what the pause menu's "skip" calls), only while a skippable cutscene plays: keys
# (Esc, hold F) opened the pause menu when the cutscene had just ended, and F picked "Restart"
SKIP = ("dev.op = function() local m = sdk.get_managed_singleton('app.TimelineEventMediator') "
        "if m and m:call('get_IsPlayingCutScene') and m:call('get_IsSkippable') then return tostring(m:call('skip(System.Object)', m)) end "
        "return 'nothing to skip' end return 1")


def skip_cutscene(game):
    bridge(game, GUI_OP, 5)
    bridge(game, SKIP, 5)


def shot(game, path):
    h = windows().get(game)
    if h:
        subprocess.run(["um", "win", "shot", "--hwnd", h, path, "--scale", "0.3"], capture_output=True, shell=True)


def log_len(game):
    try:
        with open(os.path.join(GAMES[game], "re2_framework_log.txt"), encoding="utf-8", errors="replace") as f:
            return len(f.read().splitlines())
    except OSError:
        return 0


def log_since(game, start):
    with open(os.path.join(GAMES[game], "re2_framework_log.txt"), encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()[start:]


STATE = ("local G = _G.re9coop local ok, s = pcall(G.selftest) "
         "return json.dump_string({ chapter = G.me.chapter, kind = G.me.kind, player = G.me.go ~= nil, "
         "cut = ok and s.cutscene or false, self = ok and s or tostring(s) })")
PARTNER = ("local G = _G.re9coop local r = {} for id, p in pairs(G.peers()) do local pup = p.puppet "
           "r[#r+1] = { name = p.name, chapter = p.chapter, state = pup and pup.state or 'none', visible = pup and pup.visible or false } end "
           "return json.dump_string(r)")
BOSS_LIST = ("local cm = sdk.get_managed_singleton('app.CharacterManager') local list = cm:call('get_EnemyContextList') "
             "local want = {" + ",".join("['%s'] = true" % b for b in BOSSES) + "} local r = {} "
             "for i = 0, list:call('get_Count') - 1 do local x = list:call('get_Item', i) local k = x:call('get_KindID'):call('ToString') "
             "if want[k] then local hp = x:call('get_HitPoint') r[#r+1] = { kind = k, id = x:call('get_ID'):call('ToString'):sub(1, 8), "
             "spawn = x:call('get_IsSpawn'), dead = x:call('get_IsDead'), hp = hp and hp:call('get_CurrentHitPoint') or -1 } end end "
             "return json.dump_string(r)")


def parse(out):
    try:
        return json.loads(json.loads(out))
    except (ValueError, TypeError):
        return out


def in_chapter(game, ch):
    rc, out = bridge(game, STATE, 10)
    st = parse(out) if rc == 0 else None
    return st if isinstance(st, dict) and st.get("player") and str(st.get("chapter", "")).startswith(ch[:8]) else None


def jump(game, ch):
    bridge(game, GUI_OP)
    return bridge(game, "dev.op = function() local mg = sdk.get_managed_singleton('app.MainGameFlowManager') "
                        "local lf = sdk.get_managed_singleton('app.LevelFlowManager') "
                        f"mg:call('setOverrideNextJumpScene', '{ch}') lf:call('requestGameJump') return 'jump' end return 'queued'")


def wait_both(ch, t_max=240):
    t0 = time.time()
    st = {"1": None, "2": None}
    sent_guest = False
    next_skip = {"1": time.time() + 15, "2": time.time() + 15}
    while time.time() - t0 < t_max:
        time.sleep(3)
        for g in ("1", "2"):
            if st[g] is None:
                st[g] = in_chapter(g, ch)
            if time.time() > next_skip[g]:
                rc, out = bridge(g, "return tostring(_G.re9coop.selftest().cutscene)", 10)
                if '"true"' in out:
                    skip_cutscene(g)
                next_skip[g] = time.time() + 10
        if st["1"] and not st["2"] and not sent_guest and time.time() - t0 > 45:
            jump("2", ch)
            sent_guest = True
        if st["1"] and st["2"]:
            return st, sent_guest
    return st, sent_guest


def errors(lines):
    bad = []
    for line in lines:
        if "[re9coop" in line and any(w in line.lower() for w in ("error", "failed", "can't", "couldn't", "stack traceback")):
            bad.append(line.split("] ", 2)[-1][:300])
        elif "[ScriptRunner]" in line or ("[error]" in line and "re9coop" in line):
            bad.append(line[:300])
    return bad[:30]


def main():
    out_dir = sys.argv[1]
    chapters = sys.argv[2:] or ALL
    os.makedirs(out_dir, exist_ok=True)
    res_path = os.path.join(out_dir, "sweep.json")
    results = json.load(open(res_path, encoding="utf-8")) if os.path.exists(res_path) else {}
    for ch in chapters:
        if ch in results and results[ch].get("both"):
            continue
        start = {g: log_len(g) for g in GAMES}
        rc, out = jump("1", ch)
        st, sent = wait_both(ch)
        r = {"host": st["1"], "guest": st["2"], "both": bool(st["1"] and st["2"]), "guest_sent_directly": sent}
        if r["both"]:
            time.sleep(12)
            for g in ("1", "2"):
                rc, out = bridge(g, STATE, 10)
                r["state_" + g] = parse(out)
                rc, out = bridge(g, PARTNER, 10)
                r["partner_" + g] = parse(out)
            rc, out = bridge("2", "return tostring(_G.re9coop.ext.check.request('sweep'))", 10)
            time.sleep(10)
            r["check"] = [l.split("[re9coop] ", 1)[-1] for l in log_since("2", start["2"]) if "sync check" in l][-1:]
            rc, out = bridge("1", BOSS_LIST, 15)
            r["bosses"] = parse(out)
            for g in ("1", "2"):
                shot(g, os.path.join(out_dir, "%s_game%s.png" % (ch, g)))
        for g in ("1", "2"):
            r["errors_" + g] = errors(log_since(g, start[g]))
        results[ch] = r
        json.dump(results, open(res_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(ch, "both" if r["both"] else "NOT BOTH", "check:", r.get("check"), "errors:",
              len(r["errors_1"]) + len(r["errors_2"]), "bosses:", r.get("bosses"), flush=True)


if __name__ == "__main__":
    main()
