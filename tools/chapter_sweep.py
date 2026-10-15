"""Load every main-game chapter with the mod running and collect its self test (dev tool).

usage: python tools/chapter_sweep.py OUT_DIR [Chap1_00 Chap1_01 ...]
Needs the game running with a save loaded, the dev bridge installed and its save guard flag on
(chapter jumps can autosave). For each chapter: jump (MainGameFlowManager.setOverrideNextJumpScene +
LevelFlowManager.requestGameJump), wait for the mod's "player ... in <chapter>" log line, turn the
self-test echo on, wait, then record re9coop.selftest(), new mod error lines and a screenshot.
"""
import json
import os
import subprocess
import sys
import time

GAME = r"E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem"
LOG = os.path.join(GAME, "re2_framework_log.txt")
HERE = os.path.dirname(os.path.abspath(__file__))
ALL = ["Chap1_00", "Chap1_01", "Chap1_10", "Chap3_01", "Chap3_02", "Chap3_03", "Chap3_0304", "Chap3_04", "Chap3_05",
       "Chap3_06", "Chap3_10", "Chap3_20", "Chap3_324", "Chap3_40", "Chap4_00", "Chap4_10", "Chap4_1020", "Chap4_20",
       "Chap4_30", "Chap4_40", "Chap4_4050", "Chap4_50", "Chap5_02", "Chap5_03", "Chap5_04", "Chap5_05", "Chap5_10",
       "ff_01", "ff_02"]


def bridge(code, timeout=20):
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), code, "-t", str(timeout)],
                       capture_output=True, text=True, timeout=timeout + 10)
    return r.returncode, (r.stdout + r.stderr).strip()


def in_cutscene():
    rc, out = bridge("return tostring(_G.re9coop.selftest().cutscene)", 10)
    return rc == 0 and "true" in out


def skip_cutscene():
    # Esc opens the cutscene menu, holding F skips the cutscene
    subprocess.run(["um", "win", "drive", "--proc", "re9", "focus", "sleep 200", "key 0x1B", "sleep 700",
                    "hold 0x46 3500", "sleep 1500"], capture_output=True, shell=True)


def game_running():
    r = subprocess.run(["tasklist", "/FI", "IMAGENAME eq re9.exe"], capture_output=True, text=True)
    return "re9.exe" in r.stdout


def log_lines():
    with open(LOG, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def main():
    out_dir = sys.argv[1]
    chapters = sys.argv[2:] or ALL
    os.makedirs(out_dir, exist_ok=True)
    results = {}
    res_path = os.path.join(out_dir, "sweep.json")
    if os.path.exists(res_path):
        results = json.load(open(res_path, encoding="utf-8"))
    for ch in chapters:
        if ch in results and results[ch].get("ok"):
            continue
        if not game_running():
            results[ch] = {"ok": False, "why": "game not running"}
            break
        start = len(log_lines())
        # the jump runs inside the game's GUI update (dev.op runner), like the game's own scene changes
        rc, out = bridge("if not dev.gui_op then dev.gui_op = true "
                         "sdk.hook(sdk.find_type_definition('app.GuiAutoSaveFlowController'):get_method('update'), "
                         "function() local op = dev.op if op then dev.op = nil pcall(op) end end, nil) end "
                         "dev.op = function() local mg = sdk.get_managed_singleton('app.MainGameFlowManager') "
                         "local lf = sdk.get_managed_singleton('app.LevelFlowManager') "
                         f"mg:call('setOverrideNextJumpScene', '{ch}') lf:call('requestGameJump') end return 'jump'")
        if rc != 0:
            results[ch] = {"ok": False, "why": "jump failed: " + out}
            continue
        t0 = time.time()
        arrived = None
        next_skip = time.time() + 20
        while time.time() - t0 < 240:
            time.sleep(3)
            if not game_running():
                break
            new = log_lines()[start:]
            for line in new:
                if "[re9coop] player" in line:
                    arrived = line.split("[re9coop] ")[1]
            if arrived and not in_cutscene():
                break
            if time.time() >= next_skip and in_cutscene():
                skip_cutscene()
                next_skip = time.time() + 12
        if not game_running():
            results[ch] = {"ok": False, "why": "crash", "log": [l for l in log_lines()[start:] if "error" in l.lower()][-5:]}
            json.dump(results, open(res_path, "w", encoding="utf-8"), indent=1)
            print(ch, "CRASH")
            break
        if not arrived:
            results[ch] = {"ok": False, "why": "no player within 240 s"}
            json.dump(results, open(res_path, "w", encoding="utf-8"), indent=1)
            print(ch, "no player")
            continue
        time.sleep(12)
        bridge("_G.re9coop.set_loopback(true) _G.re9coop_test_shared = true return 1")
        time.sleep(10)
        rc, st = bridge("local r = _G.re9coop.selftest() "
                        "local l = sdk.get_managed_singleton('app.CharacterManager'):call('get_EnemyContextList') "
                        "r.enemy_contexts = l and l:call('get_Count') r.enemy_kinds = {} "
                        "for i = 0, (l and l:call('get_Count') or 0) - 1 do "
                        "local k = l:call('get_Item', i):call('get_KindID'):call('ToString') "
                        "r.enemy_kinds[k] = (r.enemy_kinds[k] or 0) + 1 end return json.dump_string(r)")
        try:
            st = json.loads(json.loads(st)) if st.startswith('"') else st
        except Exception:
            pass
        shot = os.path.join(out_dir, ch + ".png")
        subprocess.run(["um", "win", "shot", "--exe", "re9.exe", shot, "--scale", "0.3"], capture_output=True, shell=True)
        errs = [l for l in log_lines()[start:] if "[re9coop]" in l and ("error" in l.lower() or "fail" in l.lower())]
        results[ch] = {"ok": True, "arrived": arrived, "selftest": st, "errors": errs[-8:]}
        json.dump(results, open(res_path, "w", encoding="utf-8"), indent=1)
        print(ch, "->", arrived, "| errors:", len(errs))
    json.dump(results, open(res_path, "w", encoding="utf-8"), indent=1)


if __name__ == "__main__":
    main()
