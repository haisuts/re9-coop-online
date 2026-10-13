-- dev probe: damage hooks + one zombie spawned, AI off, warped 3.5 m in front of the camera
dev.dmg = {}
local function goname(o)
    local ok, n = pcall(function() return o:call("get_GameObject"):call("get_Name") end)
    return ok and n or "?"
end
local function H(tn, sig, tag, fn)
    local m = sdk.find_type_definition(tn):get_method(sig)
    if not m then return tag .. " MISSING" end
    sdk.hook(m, function(args)
        if #dev.dmg < 80 then
            local ok, s = pcall(fn, args)
            dev.dmg[#dev.dmg + 1] = ok and s or ("ERR " .. tag .. " " .. tostring(s))
        end
    end, nil)
    return tag .. " ok"
end
local r = {}
r[#r + 1] = H("app.HitController", "requestDamage(app.HitController, System.UInt32, app.DamageUserData, System.String, via.vec3, app.WeaponID)", "reqDmg6", function(a)
    local this = sdk.to_managed_object(a[2]); local atk = sdk.to_managed_object(a[3])
    local s = sdk.to_managed_object(a[6])
    return string.format("reqDmg6 victim=%s attacker=%s hash=%u str=%s", goname(this), atk and goname(atk) or "nil",
        sdk.to_int64(a[4]) & 0xFFFFFFFF, s and s:call("ToString") or "nil")
end)
r[#r + 1] = H("app.HitController", "requestDamage(app.HitController, System.UInt32, app.DamageUserData, System.String, via.vec3, app.WeaponID, app.HitController)", "reqDmg7", function(a)
    local this = sdk.to_managed_object(a[2]); local atk = sdk.to_managed_object(a[3])
    return string.format("reqDmg7 victim=%s attacker=%s hash=%u", goname(this), atk and goname(atk) or "nil", sdk.to_int64(a[4]) & 0xFFFFFFFF)
end)
r[#r + 1] = H("app.HitPoint", "addDamageHitPoint(System.Int32, System.Boolean, System.Boolean)", "addHP", function(a)
    return string.format("addDamageHitPoint this=%X dmg=%d b1=%d b2=%d", sdk.to_int64(a[2]), sdk.to_int64(a[3]) & 0xFFFFFFFF, sdk.to_int64(a[4]) & 1, sdk.to_int64(a[5]) & 1)
end)
r[#r + 1] = H("app.HitPoint", "addDamageReactionHP(System.Int32, System.Boolean, System.Boolean)", "addRHP", function(a)
    return string.format("addDamageReactionHP this=%X dmg=%d", sdk.to_int64(a[2]), sdk.to_int64(a[3]) & 0xFFFFFFFF)
end)
r[#r + 1] = H("app.HitController", "callbackDamageCalc(app.HitController.DamageInfo)", "dmgCalc", function(a)
    return "callbackDamageCalc " .. goname(sdk.to_managed_object(a[2]))
end)
r[#r + 1] = H("app.HitController", "callBackDamageFinal(app.HitController.DamageInfo)", "dmgFinal", function(a)
    return "callBackDamageFinal " .. goname(sdk.to_managed_object(a[2]))
end)

local tv = sdk.find_type_definition("System.Nullable`1<via.vec3>")
local tq = sdk.find_type_definition("System.Nullable`1<via.Quaternion>")
local function nvec(v) local n = ValueType.new(tv); n:write_byte(0, 1); n:write_float(16, v.x); n:write_float(20, v.y); n:write_float(24, v.z); return n end
local function nquat(q) local n = ValueType.new(tq); n:write_byte(0, 1); n:write_float(16, q.x); n:write_float(20, q.y); n:write_float(24, q.z); n:write_float(28, q.w); return n end

local cm = sdk.get_managed_singleton("app.CharacterManager")
local list = cm:call("get_EnemyContextList")
local ctx
for i = 0, list:call("get_Count") - 1 do
    local x = list:call("get_Item", i)
    if x:call("get_ID"):call("ToString"):find("^a87da8ab") then ctx = x end
end
local sd = cm:call("getSpawnDataRef", ctx:call("get_ID"))
dev.zh = { ctx = ctx, ctl = sd:call("get_SpawnControl"), state = "spawning", log = {}, frames = 0 }
re.on_pre_application_entry("UpdateBehavior", function()
    local Z = dev.zh
    if not Z or Z.state == "done" then return end
    Z.frames = Z.frames + 1
    local go = Z.ctl:call("getSpawnInstance")
    if Z.state == "spawning" and go and Z.ctl:call("get_HasCompletedSpawn") and go:call("get_UpdateSelf") then
        Z.go, Z.upd = go, Z.ctx:call("get_CharacterUpdaterBase")
        for _, g in ipairs({ "get_ThinkDriver", "get_LockOnTargetDriver" }) do
            local d = Z.upd:call(g)
            if d then d:call("set_IsEnable", false) end
        end
        local oa = go:call("getComponent(System.Type)", sdk.typeof("app.CharacterOutOfAreaDriver"))
        if oa then oa:call("set_IsEnable", false) end
        local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
        local cp = cam:call("get_Position")
        local fwd = cam:call("get_Rotation") * Vector3f.new(0, 0, -1)
        local pp = re9coop.me.go:call("get_Transform"):call("get_Position")
        Z.target = Vector3f.new(cp.x + fwd.x * 3.5, pp.y, cp.z + fwd.z * 3.5)
        local yaw = math.atan(-fwd.x, -fwd.z)
        cm:call("requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)",
            Z.ctx:call("get_ID"), nvec(Z.target), nquat(Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)))
        Z.log[#Z.log + 1] = "complete at frame " .. Z.frames
        Z.state = "ready"
    end
    if Z.state == "ready" then
        if not Z.go:call("get_UpdateSelf") then Z.go:call("set_UpdateSelf", true) end
        if not Z.go:call("get_DrawSelf") then Z.go:call("set_DrawSelf", true) end
        local pp = re9coop.me.go:call("get_Transform"):call("get_Position")
        local zp = Z.go:call("get_Transform"):call("get_Position")
        if (zp - pp):length() < 1.6 then
            Z.ctl:call("requestKill"); Z.state = "done"; Z.log[#Z.log + 1] = "EMERGENCY KILL"
        end
    end
end)
dev.zh.ctl:call("requestSpawn")
return r
