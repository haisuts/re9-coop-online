-- dev probe: reflective serializer round trip of app.Inventory.SaveData (JSON), restored into another
-- inventory. dev.invs comes from an earlier bridge call (inventories by _Inventories order).
local SKIP = { ["_DetailDataRef"] = true }

local function is_skipped_type(name)
    return name:find("Action`", 1, true) or name:find("Func`", 1, true) or name:find("ItemDetailData", 1, true)
end

local ser
local function ser_fields(obj, td, depth)
    local f = {}
    local t = td
    while t and t:get_full_name() ~= "System.Object" and t:get_full_name() ~= "System.ValueType" do
        for _, fl in ipairs(t:get_fields()) do
            if not fl:is_static() and not SKIP[fl:get_name()] and not is_skipped_type(fl:get_type():get_full_name()) then
                local ok, v = pcall(obj.get_field, obj, fl:get_name())
                if ok and v ~= nil then f[fl:get_name()] = ser(v, depth + 1) end
            end
        end
        t = t:get_parent_type()
    end
    return f
end

ser = function(v, depth)
    depth = depth or 0
    local tv = type(v)
    if tv ~= "userdata" then return v end
    if depth > 8 then return nil end
    -- arrays
    local okA, size = pcall(function() return v:get_size() end)
    if okA and size then
        local et = v:get_type_definition():get_full_name():gsub("%[%]$", "")
        local a = {}
        for i = 0, size - 1 do a[#a + 1] = ser(v:get_element(i), depth + 1) or false end
        return { arr = et, n = size, a = a }
    end
    -- value types
    local okV, vtd = pcall(function() return v:type() end)
    if okV and vtd then
        return { vt = vtd:get_full_name(), f = ser_fields(v, vtd, depth) }
    end
    -- managed objects
    local okM, td = pcall(function() return v:get_type_definition() end)
    if okM and td then
        if td:is_enum() then return nil end
        if td:is_value_type() then
            return { vt = td:get_full_name(), f = ser_fields(v, td, depth) }
        end
        return { t = td:get_full_name(), f = ser_fields(v, td, depth) }
    end
    return nil
end

local de
de = function(x)
    if type(x) ~= "table" then return x end
    if x.arr then
        local items = x.a or {}
        local arr = sdk.create_managed_array(sdk.find_type_definition(x.arr), x.n or #items)
        for i, e in ipairs(items) do
            if e then arr[i - 1] = de(e) end
        end
        return arr
    end
    if x.vt then
        local vt = ValueType.new(sdk.find_type_definition(x.vt))
        for k, v in pairs(x.f or {}) do pcall(vt.set_field, vt, k, de(v)) end
        return vt
    end
    if x.t then
        local o = sdk.create_instance(x.t)
        if o == nil then return nil end
        for k, v in pairs(x.f or {}) do pcall(o.set_field, o, k, de(v)) end
        return o
    end
end

dev.box_ser, dev.box_de = ser, de

local src, dst = dev.invs[4], dev.invs[1] -- User01 hand (13) -> ShareItemBox (empty)
local saved = src:call("storeTo")
local t0 = os.clock()
local tbl = ser(saved)
local js = json.dump_string(tbl)
local back = json.load_string(js)
local obj = de(back)
-- keep the destination's own owner and board type
obj:set_field("_User", dst:call("get_User"))
obj:set_field("_BoardType", dst:call("get_BoardType"))
dev.box_backup = dst:call("storeTo")
local ok, res = pcall(dst.call, dst, "restoreFrom", obj)
return { json_bytes = #js, ms = (os.clock() - t0) * 1000, restore_ok = ok, res = tostring(res),
    dst_used = dst:call("get_UsedSlotCount"), src_used = src:call("get_UsedSlotCount"), sample = js:sub(1, 400) }
