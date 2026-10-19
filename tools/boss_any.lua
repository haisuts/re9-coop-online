-- any boss: dev.ba_kind ("cp_B700"), dev.ba_step:
--   "find"    its context(s), spawn data / control, Cp_<kind>SpawnParam components loaded now
--   "folders" the chapter's spawn-param folder tree (name, active), to find an arena
--   "activate" activate folder dev.ba_folder (a name) under the chapter
--   "spawn"   GUI op: through its spawn control, or permitSpawn + requestSpawn on a spawn param
--   "wake"    UpdateSelf on;  "state"
local G = _G.re9coop
local kind = dev.ba_kind
local cm = sdk.get_managed_singleton("app.CharacterManager")
local function contexts()
    local r = {}
    local list = cm:call("get_EnemyContextList")
    for i = 0, list:call("get_Count") - 1 do
        local x = list:call("get_Item", i)
        if x:call("get_KindID"):call("ToString") == kind then r[#r + 1] = x end
    end
    return r
end
local function param_type()
    return sdk.find_type_definition("app.Cp_" .. kind:sub(4) .. "SpawnParam")
end
local function params()
    local td = param_type()
    if not td then return {} end
    return G.world.scene_components(td:get_runtime_type())
end
local function chapter_folder()
    local f = G.me.go:call("get_Folder")
    local last = f
    while f do
        local p = f:call("get_Parent")
        if p and p:call("get_Name") == "MainGame" then return f end
        last = f
        f = p
    end
    return last
end
local step = dev.ba_step
if step == "find" then
    local r = {}
    for _, x in ipairs(contexts()) do
        local sd = cm:call("getSpawnDataRef", x:call("get_ID"))
        local ctl = sd and sd:call("get_SpawnControl")
        local cgo = ctl and ctl:call("get_GameObject")
        local hp = x:call("get_HitPoint")
        r[#r + 1] = string.format("%s spawn=%s dead=%s hp=%s ctl=%s", x:call("get_ID"):call("ToString"):sub(1, 8), tostring(x:call("get_IsSpawn")),
            tostring(x:call("get_IsDead")), tostring(hp and hp:call("get_CurrentHitPoint")), cgo and cgo:call("get_Name") or "-")
    end
    local ps = params()
    r[#r + 1] = "param type " .. tostring(param_type() ~= nil) .. ", loaded params " .. #ps
    for i, p in ipairs(ps) do
        if i <= 3 then
            local pos = p:call("get_GameObject"):call("get_Transform"):call("get_Position")
            r[#r + 1] = string.format("  param %s at %.1f,%.1f,%.1f", p:call("get_GameObject"):call("get_Name"), pos.x, pos.y, pos.z)
        end
    end
    return table.concat(r, " | ")
end
if step == "folders" then
    local r = {}
    local function walk(f, depth, path)
        if depth > 5 then return end
        local n = f:call("get_Name")
        local ok, act = pcall(f.call, f, "get_Active")
        if depth >= 1 then r[#r + 1] = string.rep(" ", depth) .. n .. (ok and (act and "" or " (off)") or "") end
        local c = f:call("get_Child")
        while c do walk(c, depth + 1, path .. "/" .. n) c = c:call("get_Next") end
    end
    local root = chapter_folder()
    local c = root:call("get_Child")
    while c do
        if c:call("get_Name"):find("Character") then walk(c, 0, "") end
        c = c:call("get_Next")
    end
    return table.concat(r, "\n")
end
if step == "activate" then
    local function find(f, depth)
        if f == nil or depth > 8 then return nil end
        if f:call("get_Name") == dev.ba_folder then return f end
        local c = f:call("get_Child")
        while c do
            local x = find(c, depth + 1)
            if x then return x end
            c = c:call("get_Next")
        end
    end
    local f = find(chapter_folder(), 0)
    if not f then return "no folder " .. tostring(dev.ba_folder) end
    dev.op_result = nil
    dev.op = function() f:call("activate") return "activated " .. f:call("get_Path") end
    return "queued"
end
if step == "spawn" then
    dev.op_result = nil
    dev.op = function()
        local r = {}
        for _, x in ipairs(contexts()) do
            if not x:call("get_IsDead") then
                local sd = cm:call("getSpawnDataRef", x:call("get_ID"))
                local ctl = sd and sd:call("get_SpawnControl")
                if ctl then
                    pcall(ctl.call, ctl, "permitSpawn(System.Boolean)", true)
                    r[#r + 1] = "ctl requestSpawn " .. tostring(pcall(ctl.call, ctl, "requestSpawn"))
                end
            end
        end
        if #r == 0 then
            local ps = params()
            if ps[1] then
                pcall(ps[1].call, ps[1], "permitSpawn(System.Boolean)", true)
                r[#r + 1] = "param requestSpawn " .. tostring(pcall(ps[1].call, ps[1], "requestSpawn"))
            end
        end
        return #r > 0 and table.concat(r, ", ") or "nothing to spawn it with"
    end
    return "queued"
end
local r = {}
local mp = G.me.go:call("get_Transform"):call("get_Position")
for _, x in ipairs(contexts()) do
    local go = x:call("get_IsSpawn") and x:call("get_GameObject")
    if step == "wake" and go then go:call("set_UpdateSelf", true) end
    local id = x:call("get_ID"):call("ToString")
    local hp = x:call("get_HitPoint")
    local p = go and go:call("get_Transform"):call("get_Position")
    r[#r + 1] = string.format("%s spawn %s awake %s dead %s hp %s runs here %s %s", id:sub(1, 8), tostring(x:call("get_IsSpawn")), tostring(go and go:call("get_UpdateSelf")),
        tostring(x:call("get_IsDead")), tostring(hp and hp:call("get_CurrentHitPoint")), tostring(G.foes.owner[id]),
        p and string.format("at %.1f,%.1f,%.1f (%.1f m)", p.x, p.y, p.z, (p - mp):length()) or "")
end
return #r > 0 and table.concat(r, " | ") or ("no " .. kind)
