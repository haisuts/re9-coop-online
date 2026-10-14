"""Rough check for accidental globals in a Lua file: names used but never declared local/param.

usage: python tools/globals_check.py file.lua
"""
import re
import sys

KNOWN = set("""
and break do else elseif end false for function goto if in local nil not or repeat return then true until while
sdk re imgui draw json fs log ValueType Vector3f Vector4f Quaternion Matrix4x4f string table math pairs ipairs pcall xpcall
tostring tonumber type next select os error assert setmetatable getmetatable rawget rawset rawequal rawlen print
utf8 coroutine debug require load dofile collectgarbage _G _ENV re9coop_net self
""".split())

src = open(sys.argv[1], encoding="utf-8").read()
# strip comments and strings
src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
src = re.sub(r"--[^\n]*", "", src)
src = re.sub(r'"(\\.|[^"\\])*"', '""', src)
src = re.sub(r"'(\\.|[^'\\])*'", "''", src)

declared = set()
for m in re.finditer(r"\blocal\s+function\s+(\w+)", src):
    declared.add(m.group(1))
for m in re.finditer(r"\blocal\s+([\w\s,]+?)(=|\n|$)", src):
    for n in m.group(1).split(","):
        declared.add(n.strip())
for m in re.finditer(r"\bfunction\s*[\w.:]*\s*\(([^)]*)\)", src):
    for n in m.group(1).split(","):
        declared.add(n.strip())
for m in re.finditer(r"\bfor\s+([\w\s,]+?)\s+(=|in\b)", src):
    for n in m.group(1).split(","):
        declared.add(n.strip())

bad = {}
for i, line in enumerate(src.split("\n"), 1):
    for m in re.finditer(r"(?<![.:\w])([A-Za-z_]\w*)", line):
        n = m.group(1)
        # table constructor keys "name ="
        rest = line[m.end():]
        if re.match(r"\s*=[^=]", rest):  # table fields (and assignments) are skipped
            continue
        if n not in KNOWN and n not in declared:
            bad.setdefault(n, i)
for n, i in sorted(bad.items(), key=lambda x: x[1]):
    print(f"{i}: {n}")
