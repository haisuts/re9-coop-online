"""Build the release zip: dist/RE9_Coop_Online_v<version>.zip

usage: python tools/package.py
The version is read from re9coop_main.lua (local VERSION = "x.y.z"). Ships the mod and what it needs to
run: REFramework (dinput8.dll from the nightly build the mod is tested with, unmodified, checked by its
SHA-256) with REFramework's license and its third-party notices. The nightly's zip is kept in
_deps/REFramework-nightly/ and downloaded from GitHub when it isn't there.
"""
import hashlib
import os
import re
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "re9coop", "lua", "autorun", "re9coop_main.lua")
DLL = os.path.join(ROOT, "re9coop", "plugin", "build", "re9coop_net.dll")
README = os.path.join(ROOT, "re9coop", "README.md")
THIRD_PARTY = os.path.join(ROOT, "re9coop", "third_party")

# REFramework nightly 01432 (commit d052e8fd): the build every in-game test of the mod ran on
REF_ZIP = os.path.join(ROOT, "_deps", "REFramework-nightly", "REFramework_nightly-01432.zip")
REF_URL = ("https://github.com/praydog/REFramework-nightly/releases/download/"
           "nightly-01432-d052e8fd3fd41d0a1a33394fcf6e6c19be39b1ee/REFramework.zip")
REF_DLL_SHA256 = "70a2a3c24030d8bc3695554e7f929fd1b0b4b757fb5ba2c9d34f42d7155005ac"


def reframework_dll():
    if not os.path.exists(REF_ZIP):
        os.makedirs(os.path.dirname(REF_ZIP), exist_ok=True)
        print("downloading", REF_URL)
        with urllib.request.urlopen(REF_URL) as r:
            data = r.read()
        with open(REF_ZIP, "wb") as f:
            f.write(data)
    with zipfile.ZipFile(REF_ZIP) as z:
        dll = z.read("dinput8.dll")
    digest = hashlib.sha256(dll).hexdigest()
    if digest != REF_DLL_SHA256:
        raise SystemExit(f"{REF_ZIP}: dinput8.dll is {digest}, not the tested build {REF_DLL_SHA256}")
    return dll


def main():
    src = open(LUA, encoding="utf-8").read()
    version = re.search(r'local VERSION = "([^"]+)"', src).group(1)
    dll = reframework_dll()
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", f"RE9_Coop_Online_v{version}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("dinput8.dll", dll)
        z.write(LUA, "reframework/autorun/re9coop_main.lua")
        z.write(DLL, "reframework/plugins/re9coop_net.dll")
        z.write(README, "README_RE9_Coop.md")
        for name in sorted(os.listdir(THIRD_PARTY)):
            z.write(os.path.join(THIRD_PARTY, name), "licenses/" + name)
    with zipfile.ZipFile(out) as z:
        for i in z.infolist():
            print(f"  {i.file_size:>10}  {i.filename}")
    print(out, os.path.getsize(out), "bytes")


if __name__ == "__main__":
    main()
