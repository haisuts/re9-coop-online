-- RE9 co-op: what the player's flashlight is tied to (read only, changes nothing). Run it from the
-- REFramework menu (Insert): ScriptRunner > "Run script" > this file, with the flashlight not
-- working. The lines go to re2_framework_log.txt, all starting with "[flashlight]".
local function say(s) log.info("[flashlight] " .. s) end

local function describe(v)
    if type(v) ~= "userdata" then return tostring(v) end
    local ok, td = pcall(v.get_type_definition, v)
    local name = ok and td and td:get_full_name() or "?"
    local okg, go = pcall(v.call, v, "get_GameObject")
    if okg and go then
        local okn, n = pcall(go.call, go, "get_Name")
        name = name .. " on " .. tostring(okn and n) .. string.format("@%x", go:get_address())
    end
    local oke, en = pcall(v.call, v, "get_Enabled")
    if oke and en ~= nil then name = name .. " enabled=" .. tostring(en) end
    return name
end

local function fields(o, prefix)
    local t = o:get_type_definition()
    while t and t:get_full_name() ~= "System.Object" and not t:get_full_name():find("^via%.") do
        for _, f in ipairs(t:get_fields()) do
            if not f:is_static() then
                local ok, v = pcall(o.get_field, o, f:get_name())
                say(prefix .. f:get_name() .. " = " .. (ok and describe(v) or "?"))
            end
        end
        t = t:get_parent_type()
    end
end

local G = _G.re9coop
local fc = G and G.me and G.me.flashlight
say("mod " .. tostring(G ~= nil) .. ", player " .. tostring(G and G.me.go ~= nil) .. ", chapter " .. tostring(G and G.me.chapter))
if fc then
    say("player's FlashLightController: " .. describe(fc))
    fields(fc, "  ")
else
    say("no FlashLightController found on the player")
end

-- the mod's lights for the partner (built from the game's flashlight pool prefab)
local mine = {}
for id, p in pairs(G and G.peers() or {}) do
    local pup = p.puppet
    for _, k in ipairs({ "torch", "muzzle" }) do
        local rig = pup and pup[k]
        if rig and rig.go then
            mine[rig.go:get_address()] = tostring(id) .. " " .. k
            say(string.format("mod light for %s: %s @%x on %s", tostring(id), k, rig.go:get_address(), tostring(pup[k .. "_on"])))
        end
    end
end

-- every flashlight pool object in the scene
local sm = sdk.get_native_singleton("via.SceneManager")
local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
local td = sdk.find_type_definition("app.FlashLightPoolObject")
local arr = td and scene:call("findComponents(System.Type)", td:get_runtime_type())
local list = arr and arr:get_elements() or {}
say(#list .. " FlashLightPoolObject(s) in the scene")
for i, po in ipairs(list) do
    local go = po:call("get_GameObject")
    local tag = mine[go:get_address()] and (" (the mod's: " .. mine[go:get_address()] .. ")") or ""
    say(string.format("pool object %d: %s draw=%s update=%s%s", i, describe(po), tostring(go:call("get_DrawSelf")), tostring(go:call("get_UpdateSelf")), tag))
    if i <= 6 then fields(po, "    ") end
end
say("done")
