"""Send a Lua chunk to the running game through the dev bridge and print the result.

usage: python tools/bridge.py "return dev.singletons('player')"
       python tools/bridge.py -f some_probe.lua
       python tools/bridge.py -g 2 "..."      # the stand's second game (tools/stand.py)
"""
import argparse
import os
import sys
import time
import uuid

GAME = r"E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem"
GAMES = {"1": GAME, "2": r"E:\RE9coop_stand\game2"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("code", nargs="?")
    ap.add_argument("-f", "--file")
    ap.add_argument("-t", "--timeout", type=float, default=20.0)
    ap.add_argument("-g", "--game", default="1", help="1: the Steam install, 2: the stand's second game, or a folder")
    a = ap.parse_args()
    game = GAMES.get(a.game, a.game)
    DIR = os.path.join(game, "reframework", "data", "re9coop_bridge")
    code = open(a.file, encoding="utf-8").read() if a.file else a.code
    if not code:
        sys.exit("no code")
    os.makedirs(DIR, exist_ok=True)
    cid = uuid.uuid4().hex[:12]
    out_path = os.path.join(DIR, "out.txt")
    with open(os.path.join(DIR, "cmd.lua"), "w", encoding="utf-8") as f:
        f.write(f"--id:{cid}\n{code}\n")
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        try:
            with open(out_path, encoding="utf-8", errors="replace") as f:
                data = f.read()
            if data.startswith(f"--id:{cid}\n"):
                sys.stdout.reconfigure(encoding="utf-8")
                print(data.split("\n", 1)[1])
                return
        except OSError:
            pass
        time.sleep(0.1)
    sys.exit("timeout: no reply (is the game running with the dev bridge loaded?)")


if __name__ == "__main__":
    main()
