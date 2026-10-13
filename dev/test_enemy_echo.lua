-- dev: one-PC test of the shared-enemy pipeline (needs re9coop_main.lua v0.3 and the self test).
-- Zombie A (AI on) is spawned and warped 6 m in front of the camera; zombie B becomes the "guest"
-- copy of A, 2 m to the side, 150 ms late.
local A, B = "a87da8ab", "a477ecb6"
local cm = sdk.get_managed_singleton("app.CharacterManager")
local list = cm:call("get_EnemyContextList")
local ids = {}
for i = 0, list:call("get_Count") - 1 do
    local x = list:call("get_Item", i)
    local id = x:call("get_ID"):call("ToString")
    if id:find("^" .. A) then ids.A, ids.Actx = id, x end
    if id:find("^" .. B) then ids.B = id end
end
local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
local fwd = cam:call("get_Rotation") * Vector3f.new(0, 0, -1)
local right = Vector3f.new(-fwd.z, 0, fwd.x)
re9coop.set_loopback(true)
re9coop.foes.test = { src = ids.A, dst = ids.B, offset = right * 2.0 }
local sd = cm:call("getSpawnDataRef", ids.Actx:call("get_ID"))
dev.ta = { ctx = ids.Actx, ctl = sd:call("get_SpawnControl"), state = "spawning" }
if not dev.ta_hook then
    dev.ta_hook = true
    local tv = sdk.find_type_definition("System.Nullable`1<via.vec3>")
    local tq = sdk.find_type_definition("System.Nullable`1<via.Quaternion>")
    re.on_pre_application_entry("UpdateBehavior", function()
        local T = dev.ta
        if not T or T.state ~= "spawning" then return end
        local go = T.ctl:call("getSpawnInstance")
        if go and T.ctl:call("get_HasCompletedSpawn") and go:call("get_UpdateSelf") then
            local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
            local cp = cam:call("get_Position")
            local f = cam:call("get_Rotation") * Vector3f.new(0, 0, -1)
            local pp = re9coop.me.go:call("get_Transform"):call("get_Position")
            local p = Vector3f.new(cp.x + f.x * 6, pp.y, cp.z + f.z * 6)
            local yaw = math.atan(-f.x, -f.z)
            local q = Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
            local nv = ValueType.new(tv); nv:write_byte(0, 1); nv:write_float(16, p.x); nv:write_float(20, p.y); nv:write_float(24, p.z)
            local nq = ValueType.new(tq); nq:write_byte(0, 1); nq:write_float(16, q.x); nq:write_float(20, q.y); nq:write_float(24, q.z); nq:write_float(28, q.w)
            cm:call("requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)", T.ctx:call("get_ID"), nv, nq)
            if dev.ta_calm then -- the original stands still (damage test), the copy still follows it
                local upd = T.ctx:call("get_CharacterUpdaterBase")
                for _, g in ipairs({ "get_ThinkDriver", "get_LockOnTargetDriver" }) do
                    local d = upd:call(g); if d then d:call("set_IsEnable", false) end
                end
            end
            T.state = "placed"
        end
    end)
end
dev.ta.ctl:call("requestSpawn")
return { A = ids.A, B = ids.B }
