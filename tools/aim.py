"""Turn the game camera toward dev.look_at (dev tool): reads the angles through look_at.lua and moves the
mouse until both are within 2 degrees (about 0.028 deg per unit across, 0.016 up and down in RE9).

usage: python tools/aim.py SCRATCH_DIR
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def angles(scratch):
    r = subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), "-f", os.path.join(scratch, "look_at.lua")],
                       capture_output=True, text=True, timeout=30)
    parts = r.stdout.strip().strip('"').split()
    return float(parts[0]), float(parts[1]), r.stdout.strip()


def main():
    scratch = sys.argv[1]
    subprocess.run([sys.executable, os.path.join(HERE, "bridge.py"), "dev.look_step = 'aim' return 1"], capture_output=True)
    for _ in range(8):
        yaw, pitch, line = angles(scratch)
        print(line)
        if abs(yaw) < 2 and abs(pitch) < 2:
            break
        dx, dy = int(yaw / 0.028), int(-pitch / 0.016)
        cmds = []
        while dx or dy:
            sx = max(-600, min(600, dx))
            sy = max(-600, min(600, dy))
            cmds += [f"rel {sx} {sy}", "sleep 40"]
            dx, dy = dx - sx, dy - sy
        subprocess.run(["um", "win", "drive", "--proc", "re9", "focus", "sleep 150", *cmds, "sleep 300"], capture_output=True, shell=True)


if __name__ == "__main__":
    main()
