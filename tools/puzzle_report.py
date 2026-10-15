"""Summarize re9coop_bridge/puzzles_<chapter>.json files from tools/puzzle_sweep.py (dev tool).

usage: python tools/puzzle_report.py
For every puzzle type: chapters it is in, whether the mod replays its outcome live (a lock, item slots)
or has a finisher, and which of its runtime fields stay behind when the partner's data arrives.
"""
import glob
import json
import os

DIR = r"E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem\reframework\data\re9coop_bridge"
FINISHERS = {"GmSafe", "GmContainer"}
CHECKED = {"Gm99_054": "microscope: recipes shared, verified", "Gm99_104": "heart / lung: slots replayed, verified",
           "GmMultipleUseKeyItem": "item slots replayed, verified"}


def main():
    types = {}
    for path in sorted(glob.glob(os.path.join(DIR, "puzzles_*.json"))):
        d = json.load(open(path, encoding="utf-8"))
        for tn, ty in (d.get("types") or {}).items():
            t = types.setdefault(tn, {"chapters": [], "n": 0, "lock": False, "slots": False, "stays": set(), "follows": set(), "rewritten": set(), "triggers": ""})
            t["chapters"].append(d["chapter"])
            t["n"] += ty.get("n", 0)
            t["lock"] = t["lock"] or ty.get("lock")
            t["slots"] = t["slots"] or ty.get("slots")
            t["triggers"] = t["triggers"] or ty.get("triggers", "")
            for field, r in (ty.get("test") or {}).items():
                res = r.get("result", "")
                (t["follows"] if res == "follows" else t["rewritten"] if res.startswith("data") else t["stays"]).add(field)
    for tn in sorted(types):
        t = types[tn]
        if t["lock"]:
            how = "lock: opens live (unlock trigger)"
        elif t["slots"] or tn in CHECKED:
            how = CHECKED.get(tn, "item slots: live")
        elif tn in FINISHERS:
            how = "finisher (forceOpen): live"
        elif t["stays"] or t["rewritten"]:
            how = "STATE ONLY: runtime catches up when the area reloads"
        else:
            how = "state only (no runtime copy of its data)"
        print(f"{tn:28} x{t['n']:<3} {how}")
        print(f"{'':32}chapters: {', '.join(sorted(set(t['chapters'])))}")
        if t["stays"] or t["rewritten"]:
            print(f"{'':32}stays: {', '.join(sorted(t['stays'] | t['rewritten']))}")
        if t["follows"]:
            print(f"{'':32}follows: {', '.join(sorted(t['follows']))}")


if __name__ == "__main__":
    main()
