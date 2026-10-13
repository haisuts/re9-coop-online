"""Build the release zip: dist/RE9_Coop_Online_v<version>.zip

usage: python tools/package.py
The version is read from re9coop_main.lua (local VERSION = "x.y.z"). Ships only our own files.
"""
import os
import re
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "re9coop", "lua", "autorun", "re9coop_main.lua")
DLL = os.path.join(ROOT, "re9coop", "plugin", "build", "re9coop_net.dll")
README = os.path.join(ROOT, "re9coop", "README.md")


def main():
    src = open(LUA, encoding="utf-8").read()
    version = re.search(r'local VERSION = "([^"]+)"', src).group(1)
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", f"RE9_Coop_Online_v{version}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(LUA, "reframework/autorun/re9coop_main.lua")
        z.write(DLL, "reframework/plugins/re9coop_net.dll")
        z.write(README, "README_RE9_Coop.md")
    print(out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
