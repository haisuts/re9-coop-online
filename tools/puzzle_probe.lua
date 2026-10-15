-- Dev probe for one chapter: every puzzle-like gimmick type here, its triggers, and whether its runtime
-- follows its data. dev.pp_step = "census" | "write" | "check"; results in re9coop_bridge/puzzles_<chapter>.json
local sm = sdk.get_native_singleton("via.SceneManager")
local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
local function els(arr)
    if arr == nil then return {} end
    local ok0, list = pcall(arr.get_elements, arr)
    if ok0 then return list end
    list = {}
    for i = 0, arr:call("get_Length") - 1 do list[#list + 1] = arr:call("GetValue(System.Int32)", i) end
    return list
end
local function is_puzzle(tn)
    return tn:find("^Gm%d") or tn:find("^GmMultipleUseKeyItem$") or tn:find("^GmSafe$") or tn:find("^GmContainer$")
        or tn:find("^GmItemInstallation")
end
local chapter = _G.re9coop.me.chapter

if dev.pp_step == "census" then
    local types = {}
    for _, core in ipairs(els(scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickCore")))) do
        local go = core:call("get_GameObject")
        local okid, id = pcall(function() return core:call("get_ContextID"):call("ToString") end)
        local comps = els(go:call("get_Components"))
        local has, trig = {}, {}
        for _, c in ipairs(comps) do
            local tn = c:get_type_definition():get_name()
            has[tn] = c
            local okt, trs = pcall(function() return c:get_field("_Triggers") end)
            for _, t in ipairs(okt and els(trs) or {}) do
                trig[#trig + 1] = tn:gsub("InteractTrigger", ""):gsub("Holder", "") .. ":" .. tostring(t:get_field("_Name"))
            end
        end
        for tn, c in pairs(has) do
            if is_puzzle(tn) and okid then
                local ty = types[tn]
                if ty == nil then
                    -- data fields of this gimmick, and runtime fields with the same name
                    local data = {}
                    local ctx = core:get_field("_Context")
                    local list = ctx and ctx:call("get_SDC"):get_field("_Structures")
                    for i = 0, (list and list:call("get_Count") or 0) - 1 do
                        local x = list:call("get_Item", i)
                        for _, f in ipairs(x:get_type_definition():get_fields()) do
                            if not f:is_static() then data[f:get_name()] = x:get_type_definition():get_name() end
                        end
                    end
                    local mirrors = {}
                    for _, f in ipairs(c:get_type_definition():get_fields()) do
                        if not f:is_static() and data[f:get_name()] then mirrors[#mirrors + 1] = f:get_name() end
                    end
                    ty = { n = 0, id = id, lock = has.GmLockV2 ~= nil, slots = has.GmMultipleUseKeyItem ~= nil,
                        triggers = table.concat(trig, " "), mirrors = mirrors, done = 0 }
                    types[tn] = ty
                end
                ty.n = ty.n + 1
                local okd, done = pcall(function() return core:get_field("_GmBaseData"):get_field("_IsDone") end)
                if okd and done then ty.done = ty.done + 1 end
            end
        end
    end
    dev.pp = { chapter = chapter, types = types }
    local n = 0
    for _ in pairs(types) do n = n + 1 end
    return n
end

local function parts(tn, id, field)
    for _, core in ipairs(els(scene:call("findComponents(System.Type)", sdk.typeof("app.GimmickCore")))) do
        local ok, cid = pcall(function() return core:call("get_ContextID"):call("ToString") end)
        if ok and cid == id then
            local comp = core:call("get_GameObject"):call("getComponent(System.Type)", sdk.typeof("app." .. tn))
            local list = core:get_field("_Context"):call("get_SDC"):get_field("_Structures")
            for i = 0, list:call("get_Count") - 1 do
                local x = list:call("get_Item", i)
                if x:get_type_definition():get_field(field) then return comp, x end
            end
        end
    end
end

if dev.pp_step == "write" then
    dev.op = function()
        for tn, ty in pairs(dev.pp.types) do
            ty.test = {}
            for _, field in ipairs(ty.mirrors) do
                local comp, d = parts(tn, ty.id, field)
                local okv, cur = pcall(function() return d:get_field(field) end)
                local new
                if okv and type(cur) == "boolean" then new = not cur elseif okv and type(cur) == "number" then new = cur + 1 end
                if comp and new ~= nil then
                    ty.test[field] = { data = tostring(cur), rt = tostring(comp:get_field(field)), new = tostring(new) }
                    pcall(d.set_field, d, field, new)
                    pcall(d.call, d, "onDirty")
                end
            end
        end
        return 1
    end
    return "queued"
end

-- check: did the runtime follow?
for tn, ty in pairs(dev.pp.types) do
    for field, t in pairs(ty.test or {}) do
        local comp, d = parts(tn, ty.id, field)
        local rt = comp and tostring(comp:get_field(field))
        local dv = d and tostring(d:get_field(field))
        t.result = (rt == t.new) and "follows" or (dv ~= t.new and "data rewritten by the gimmick" or "stays")
    end
end
fs.write("re9coop_bridge/puzzles_" .. chapter .. ".json", json.dump_string(dev.pp))
return "saved"
