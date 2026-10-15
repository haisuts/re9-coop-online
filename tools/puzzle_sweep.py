"""Run tools/puzzle_probe.lua in every chapter (dev tool).

usage: python tools/puzzle_sweep.py [Chap1_01 Chap1_10 ...]
Needs the game running with the dev bridge, its save guard on, and the GUI op runner (recorder.lua).
For each chapter: jump (inside the game's GUI update), wait for the player, skip cutscenes, wait for
the gimmicks to get their IDs, then census / write / check. Results: re9coop_bridge/puzzles_<chapter>.json
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "puzzle_probe.lua")
CHAPTERS = ["Chap1_01", "Chap1_10", "Chap3_01", "Chap3_02", "Chap3_03", "Chap3_04", "Chap3_05", "Chap3_06", "Chap3_20",
            "Chap3_40", "Chap4_10", "Chap4_20", "Chap4_30", "Chap4_40", "Chap4_50", "Chap5_02"]


def bridge(code, timeout=20):
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), code, "-t", str(timeout)],
                       capture_output=True, text=True, timeout=timeout + 10)
    return (r.stdout + r.stderr).strip()


def probe(step):
    bridge(f"dev.pp_step = '{step}' return 1")
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), "-f", PROBE, "-t", "60"], capture_output=True, text=True, timeout=80)
    return (r.stdout + r.stderr).strip()


def skip_cutscene():
    subprocess.run(["um", "win", "drive", "--proc", "re9", "focus", "sleep 200", "key 0x1B", "sleep 700", "hold 0x46 3500", "sleep 1500"],
                   capture_output=True, shell=True)


def main():
    chapters = sys.argv[1:] or CHAPTERS
    for ch in chapters:
        cur = bridge("return tostring(_G.re9coop.me.chapter)").strip('"')
        if not cur.startswith(ch):
            bridge("dev.op = function() local mg = sdk.get_managed_singleton('app.MainGameFlowManager') "
                   "local lf = sdk.get_managed_singleton('app.LevelFlowManager') "
                   f"mg:call('setOverrideNextJumpScene', '{ch}') lf:call('requestGameJump') end return 1")
            time.sleep(8)
        t0 = time.time()
        ok = False
        while time.time() - t0 < 200:
            time.sleep(4)
            st = bridge("return tostring(_G.re9coop.me.go ~= nil) .. ' ' .. tostring(_G.re9coop.me.chapter) .. ' ' .. tostring(_G.re9coop.selftest().cutscene)")
            if '"true' in st and st.endswith('false"'):
                ok = True
                break
            if st.endswith('true"'):
                skip_cutscene()
        if not ok:
            print(ch, "no gameplay")
            continue
        time.sleep(15)  # gimmick IDs are assigned a moment after the player shows up
        print(ch, "census", probe("census"))
        print(ch, "write", probe("write"))
        time.sleep(3)
        print(ch, "check", probe("check"))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
