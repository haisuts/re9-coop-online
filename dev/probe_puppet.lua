-- dev probe: a live zombie as a client-side puppet. AI off, warped every 0.1 s to a point in front of
-- the camera, joints overwritten AFTER animation with Grace's pose (names matched).
local tv = sdk.find_type_definition("System.Nullable`1<via.vec3>")
local tq = sdk.find_type_definition("System.Nullable`1<via.Quaternion>")
local function nvec(v) local n = ValueType.new(tv); n:write_byte(0, 1); n:write_float(16, v.x); n:write_float(20, v.y); n:write_float(24, v.z); return n end
local function nquat(q) local n = ValueType.new(tq); n:write_byte(0, 1); n:write_float(16, q.x); n:write_float(20, q.y); n:write_float(24, q.z); n:write_float(28, q.w); return n end
local cm = sdk.get_managed_singleton("app.CharacterManager")
local list = cm:call("get_EnemyContextList")
local ctx
for i = 0, list:call("get_Count") - 1 do
    local x = list:call("get_Item", i)
    if x:call("get_ID"):call("ToString"):find("^a477ecb6") then ctx = x end
end
local sd = cm:call("getSpawnDataRef", ctx:call("get_ID"))
dev.zp = { ctx = ctx, ctl = sd:call("get_SpawnControl"), state = "spawning", log = {}, next_warp = 0 }

local function target()
    local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
    local cp = cam:call("get_Position")
    local fwd = cam:call("get_Rotation") * Vector3f.new(0, 0, -1)
    local pp = re9coop.me.go:call("get_Transform"):call("get_Position")
    local yaw = math.atan(-fwd.x, -fwd.z)
    return Vector3f.new(cp.x + fwd.x * 3.0, pp.y, cp.z + fwd.z * 3.0), Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
end

re.on_pre_application_entry("UpdateBehavior", function()
    local Z = dev.zp
    if not Z or Z.state == "done" then return end
    local go = Z.ctl:call("getSpawnInstance")
    if Z.state == "spawning" and go and Z.ctl:call("get_HasCompletedSpawn") and go:call("get_UpdateSelf") then
        Z.go, Z.upd = go, Z.ctx:call("get_CharacterUpdaterBase")
        for _, g in ipairs({ "get_ThinkDriver", "get_LockOnTargetDriver" }) do
            local d = Z.upd:call(g)
            if d then d:call("set_IsEnable", false) end
        end
        local oa = go:call("getComponent(System.Type)", sdk.typeof("app.CharacterOutOfAreaDriver"))
        if oa then oa:call("set_IsEnable", false) end
        local by = {}
        for _, j in ipairs(go:call("get_Transform"):call("get_Joints"):get_elements()) do by[j:call("get_Name")] = j end
        Z.map = {}
        for i, n in ipairs(re9coop.me.names) do
            if by[n] then Z.map[#Z.map + 1] = { re9coop.me.joints[i], by[n] } end
        end
        Z.state = "puppet"
        Z.log[#Z.log + 1] = "puppet, mapped " .. #Z.map
    end
    if Z.state == "puppet" then
        if not Z.go:call("get_UpdateSelf") then Z.go:call("set_UpdateSelf", true) end
        if not Z.go:call("get_DrawSelf") then Z.go:call("set_DrawSelf", true) end
        local t = os.clock()
        if t >= Z.next_warp then
            Z.next_warp = t + 0.1
            local p, q = target()
            Z.last_target = p
            cm:call("requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)",
                Z.ctx:call("get_ID"), nvec(p), nquat(q))
        end
        local pp = re9coop.me.go:call("get_Transform"):call("get_Position")
        local zp = Z.go:call("get_Transform"):call("get_Position")
        if (zp - pp):length() < 1.2 then
            Z.ctl:call("requestKill"); Z.state = "done"; Z.log[#Z.log + 1] = "EMERGENCY KILL"
        end
    end
end)

re.on_application_entry("LateUpdateBehavior", function()
    local Z = dev.zp
    if not Z or Z.state ~= "puppet" or not Z.mirror then return end
    for _, pr in ipairs(Z.map) do pr[2]:call("set_LocalRotation", pr[1]:call("get_LocalRotation")) end
end)

dev.zp.ctl:call("requestSpawn")
return "spawning"
