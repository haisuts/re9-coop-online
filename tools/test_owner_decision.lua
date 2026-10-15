-- Offline test of the enemy ownership rule in re9coop_main.lua.
-- run: tools/luacheck/luacheck.exe --run tools/test_owner_decision.lua  (from the repo root)
local src = io.open("re9coop/lua/autorun/re9coop_main.lua"):read("a")
local hyst = src:match("local OWNER_HYSTERESIS = [%d%.]+")
local fn = src:match("local function owner_decision%(.-\nend\n")
assert(hyst and fn, "owner_decision not found")
local owner_decision = load(hyst .. "\n" .. fn .. "\nreturn owner_decision")()

local cases = {
    -- cur,   together, dead,  d_me, d_peer -> want
    { nil,   false,    false, 50,   1,      true,  "apart: the arbiter runs everything" },
    { false, false,    false, 50,   1,      true,  "apart: even ones the guest had" },
    { nil,   true,     false, 2,    10,     true,  "new, nearer the arbiter" },
    { nil,   true,     false, 10,   2,      false, "new, nearer the guest" },
    { nil,   true,     false, 5,    5,      true,  "new, tie goes to the arbiter" },
    { true,  true,     false, 6,    4,      true,  "2 m closer to the guest: stays (hysteresis 3 m)" },
    { true,  true,     false, 8,    4,      false, "4 m closer to the guest: moves" },
    { false, true,     false, 4,    6,      false, "2 m closer to the arbiter: stays" },
    { false, true,     false, 2,    8,      true,  "6 m closer to the arbiter: moves back" },
    { false, true,     true,  1,    40,     false, "dead: never moves" },
    { nil,   true,     true,  40,   1,      true,  "dead and unassigned: arbiter" },
}
-- bosses: cur, together, dead, d_me, d_peer, here, there -> want
local boss_cases = {
    { nil,   true,  false, 10, 2,  true,  true,  false, "boss, new, nearer the guest: guest" },
    { true,  true,  false, 30, 1,  true,  true,  true,  "boss, guest much nearer: stays with the arbiter" },
    { false, true,  false, 1,  30, true,  true,  false, "boss, arbiter much nearer: stays with the guest" },
    { true,  true,  false, 30, 1,  false, true,  false, "boss, arbiter's copy gone: guest" },
    { false, true,  false, 1,  30, true,  false, true,  "boss, guest's copy gone: arbiter" },
    { true,  true,  false, 30, 1,  false, false, true,  "boss, both gone: stays" },
    { false, false, false, 1,  1,  true,  true,  true,  "boss, apart: arbiter" },
}
local fails = 0
for i, c in ipairs(cases) do
    local got = owner_decision(c[1], c[2], c[3], c[4], c[5])
    if got ~= c[6] then
        fails = fails + 1
        print(("FAIL %d %s: got %s"):format(i, c[7], tostring(got)))
    end
end
for i, c in ipairs(boss_cases) do
    local got = owner_decision(c[1], c[2], c[3], c[4], c[5], true, c[6], c[7])
    if got ~= c[8] then
        fails = fails + 1
        print(("FAIL boss %d %s: got %s"):format(i, c[9], tostring(got)))
    end
end
local total = #cases + #boss_cases
print(("%d/%d cases pass"):format(total - fails, total))
if fails > 0 then os.exit(1) end
