"""Solve a key-item gimmick for real in the running game, recording what the mod sends (dev tool).

usage: python tools/solve_gimmick.py NAME CONTEXT_PREFIX ITEM [ITEM ...] [--trigger Interact]
Needs the dev bridge with the scratchpad helpers loaded (recorder.lua, solve.lua, gm_snap.lua). For each
item: give it, warp next to the gimmick, fire its Interact trigger (the game's item screen opens), move
the cursor to the item's cell and press F, then wait. The mod's messages go to re9coop_bridge/rec_NAME.json
and the gimmick's state before / after to snap_NAME.json.
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.environ.get("RE9_SCRATCH", "")


def bridge(code, timeout=20):
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), code, "-t", str(timeout)],
                       capture_output=True, text=True, timeout=timeout + 10)
    return (r.stdout + r.stderr).strip()


def bridge_file(path):
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), "-f", path], capture_output=True, text=True, timeout=40)
    return (r.stdout + r.stderr).strip()


def drive(*cmds):
    subprocess.run(["um", "win", "drive", "--proc", "re9", "focus", "sleep 200", *cmds], capture_output=True, shell=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("prefix")
    ap.add_argument("items", nargs="+")
    ap.add_argument("--trigger", default="Interact")
    ap.add_argument("--wait", type=float, default=12)
    a = ap.parse_args()
    setup = bridge(f"return dev.solve_setup('{a.prefix}', '{a.trigger}')")
    print(setup)
    if "interact=true" not in setup:
        sys.exit("gimmick or its trigger not found: not pressing any keys")
    print(bridge(f"return dev.snap_save('{a.name}', '{a.prefix}', 'before')"))
    bridge("dev.rec = { t0 = os.clock(), msgs = {} } return 1")
    for item in a.items:
        bridge(f"dev.op = function() dev.give('{item}') return 1 end return 1")
        time.sleep(1)
        print(bridge_file(os.path.join(SCRATCH, "warp_to.lua")))
        time.sleep(1)
        bridge("dev.op = function() return dev.interact() end return 1")
        time.sleep(2.5)
        ui = bridge("return tostring(sdk.get_managed_singleton('app.GuiManager'):call('get_ActiveGuiWithPause'))")
        if "true" not in ui:
            print(item, "no item screen: skipped")
            continue
        cell = bridge(f"local c = dev.item_cell('{item}') return c and (c.x .. ',' .. c.y) or 'none'")
        print(item, "cell", cell)
        cell = cell.strip('"')
        if "," not in cell:
            drive("click 960 540 right", "sleep 800")
            continue
        x, y = (int(v) for v in cell.split(","))
        keys = ["key 0x27", "sleep 250"] * x + ["key 0x28", "sleep 250"] * y
        drive(*keys, "sleep 300", "key 0x46", "sleep 500")
        time.sleep(a.wait)
    time.sleep(3)
    print(bridge(f"return dev.snap_save('{a.name}', '{a.prefix}', 'after')"))
    print(bridge(f"return dev.rec_save('rec_{a.name}')"))


if __name__ == "__main__":
    main()
