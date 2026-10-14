"""Print the crashing thread's stack values that point into re9.exe, from a minidump.

usage: python tools/dump_stack.py reframework_crash.dmp [max]
Stack scanning (no unwinding): every qword on the stack that falls inside re9.exe is printed with
its stack offset; return addresses show up among them. Map them to methods with the game's TDB.
"""
import struct
import sys

path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 60
d = open(path, "rb").read()

sig, ver, nstreams, dir_rva = struct.unpack_from("<4sIII", d, 0)
assert sig == b"MDMP", sig
streams = {}
for i in range(nstreams):
    stype, size, rva = struct.unpack_from("<III", d, dir_rva + i * 12)
    streams.setdefault(stype, []).append((size, rva))

# modules (type 4)
mods = []
size, rva = streams[4][0]
(n,) = struct.unpack_from("<I", d, rva)
off = rva + 4
for i in range(n):
    base, msize = struct.unpack_from("<QI", d, off)
    name_rva = struct.unpack_from("<I", d, off + 20)[0]
    (nlen,) = struct.unpack_from("<I", d, name_rva)
    name = d[name_rva + 4:name_rva + 4 + nlen].decode("utf-16-le")
    mods.append((base, msize, name.split("\\")[-1]))
    off += 108


def mod_of(a):
    for base, msize, name in mods:
        if base <= a < base + msize:
            return name, a - base
    return None, None


# exception (type 6): thread id, record, context location
size, rva = streams[6][0]
tid = struct.unpack_from("<I", d, rva)[0]
code, flags = struct.unpack_from("<II", d, rva + 8)
addr = struct.unpack_from("<Q", d, rva + 8 + 16)[0]
ctx_size, ctx_rva = struct.unpack_from("<II", d, rva + 8 + 152)
rsp = struct.unpack_from("<Q", d, ctx_rva + 0x98)[0]
rip = struct.unpack_from("<Q", d, ctx_rva + 0xF8)[0]
print(f"thread {tid} code {code:#x} at {addr:#x} rip {rip:#x} {mod_of(rip)} rsp {rsp:#x}")

# memory: thread list (type 3) for this thread's stack, else memory list (type 5)
stack = None
size, rva = streams[3][0]
(n,) = struct.unpack_from("<I", d, rva)
for i in range(n):
    o = rva + 4 + i * 48
    t = struct.unpack_from("<I", d, o)[0]
    start, dsize, drva = struct.unpack_from("<QII", d, o + 24)
    if t == tid:
        stack = (start, dsize, drva)
assert stack, "no stack for thread"
start, dsize, drva = stack
print(f"stack {start:#x}..{start + dsize:#x}")
first = max(0, rsp - start)
shown = 0
for off in range(first - first % 8, dsize - 7, 8):
    v = struct.unpack_from("<Q", d, drva + off)[0]
    name, rel = mod_of(v)
    if name and name.lower() == "re9.exe":
        print(f"  rsp+{off - first:#06x}  {v:#x}  re9.exe+{rel:#x}")
        shown += 1
        if shown >= limit:
            break
