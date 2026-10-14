"""Start RE9 and get into gameplay from the latest save (dev tool).

usage: python tools/start_game.py
Launches the game through Steam, waits for the dev bridge, then skips the title intro / confirms
"Continue" (Esc opens the cutscene menu, holding F skips a cutscene or confirms a menu item) until the
mod logs a player and no cutscene plays.
"""
import os
import subprocess
import sys
import time

GAME = r"E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem"
LOG = os.path.join(GAME, "re2_framework_log.txt")
HERE = os.path.dirname(os.path.abspath(__file__))


def bridge(code, timeout=10):
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), code, "-t", str(timeout)],
                       capture_output=True, text=True, timeout=timeout + 10)
    return r.returncode, (r.stdout + r.stderr).strip()


def drive(*cmds):
    subprocess.run(["um", "win", "drive", "--proc", "re9", "focus", "sleep 200", *cmds], capture_output=True, shell=True)


def main():
    subprocess.run(["taskkill", "/IM", "re9.exe", "/F"], capture_output=True)
    time.sleep(3)
    subprocess.run(["um", "win", "launch", "--steam", "3764200"], capture_output=True, shell=True)
    t0 = time.time()
    while time.time() - t0 < 120:
        time.sleep(3)
        rc, out = bridge("return 'up'", 5)
        if rc == 0 and "up" in out:
            break
    start = len(open(LOG, encoding="utf-8", errors="replace").read().splitlines())
    time.sleep(8)
    drive("key 0x2D", "sleep 500")  # close the REFramework menu
    for _ in range(25):
        lines = open(LOG, encoding="utf-8", errors="replace").read().splitlines()[start:]
        player = [l for l in lines if "[re9coop] player" in l]
        rc, cut = bridge("return tostring(_G.re9coop.selftest().cutscene)", 10)
        if player and '"false"' in cut:
            print(player[-1].split("[re9coop] ")[1])
            return 0
        if '"true"' in cut:  # a cutscene (the title's intro too): skip it
            drive("key 0x1B", "sleep 700", "hold 0x46 3500", "sleep 1500")
        elif not player:  # title / its menu: F confirms ("Continue" is the default)
            drive("key 0x46", "sleep 500")
        time.sleep(6)
    print("no gameplay")
    return 1


if __name__ == "__main__":
    sys.exit(main())
