-- RE9 co-op dev bridge (development only, never shipped).
-- Polls reframework/data/re9coop_bridge/cmd.lua; when its first line "--id:<id>" changes, runs the
-- chunk on the game thread (UpdateBehavior) and writes the result to out.txt with the same id.
-- Globals in _G.dev persist between commands.

local CMD = "re9coop_bridge/cmd.lua"
local OUT = "re9coop_bridge/out.txt"
local last_id = nil
local tick = 0

_G.dev = _G.dev or {}
local dev = _G.dev

local function is_managed(v)
    return type(v) == "userdata" and pcall(function() return v.get_type_definition end)
end

local function ser(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" and t ~= "userdata" then return tostring(v) end
    if t == "userdata" then
        local ok, td = pcall(function() return v:get_type_definition() end)
        if ok and td then
            local ok2, name = pcall(function() return td:get_full_name() end)
            return string.format("<%s @%s>", ok2 and name or "?", tostring(v))
        end
        local ok3, x = pcall(function() return v.x end)
        if ok3 and x ~= nil then
            local ok4, w = pcall(function() return v.w end)
            if ok4 and w ~= nil then
                return string.format("(%.4f, %.4f, %.4f, %.4f)", v.x, v.y, v.z, w)
            end
            local ok5, z = pcall(function() return v.z end)
            if ok5 and z ~= nil then return string.format("(%.4f, %.4f, %.4f)", v.x, v.y, z) end
            return string.format("(%.4f, %.4f)", v.x, v.y)
        end
        return tostring(v)
    end
    if seen[v] then return "<cycle>" end
    if depth > 6 then return "<deep>" end
    seen[v] = true
    local parts = {}
    local n = #v
    for i = 1, n do parts[#parts + 1] = ser(v[i], depth + 1, seen) end
    local keys = {}
    for k in pairs(v) do
        if not (type(k) == "number" and k >= 1 and k <= n and math.type(k) == "integer") then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. ser(v[k], depth + 1, seen)
    end
    local ind = string.rep("  ", depth + 1)
    if #parts > 6 then
        return "{\n" .. ind .. table.concat(parts, ",\n" .. ind) .. "\n" .. string.rep("  ", depth) .. "}"
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end
dev.ser = ser

-- Fields and methods of a type definition (by name or object).
function dev.typeinfo(x, filter)
    local td = type(x) == "string" and sdk.find_type_definition(x) or x:get_type_definition()
    if not td then return "no type " .. tostring(x) end
    local out = { name = td:get_full_name() }
    local parent = td:get_parent_type()
    out.parent = parent and parent:get_full_name() or nil
    out.fields, out.methods = {}, {}
    for _, f in ipairs(td:get_fields()) do
        local s = (f:is_static() and "static " or "") .. f:get_name() .. ": " .. f:get_type():get_full_name()
        if not filter or s:lower():find(filter:lower(), 1, true) then out.fields[#out.fields + 1] = s end
    end
    for _, m in ipairs(td:get_methods()) do
        local params = {}
        local ok, ptypes = pcall(function() return m:get_param_types() end)
        local ok2, pnames = pcall(function() return m:get_param_names() end)
        if ok and ptypes then
            for i, p in ipairs(ptypes) do
                params[#params + 1] = ((ok2 and pnames and pnames[i]) or "") .. ":" .. p:get_full_name()
            end
        end
        local rt = m:get_return_type()
        local s = (m:is_static() and "static " or "") .. m:get_name() .. "(" .. table.concat(params, ", ") .. ")"
            .. (rt and (" -> " .. rt:get_full_name()) or "")
        if not filter or s:lower():find(filter:lower(), 1, true) then out.methods[#out.methods + 1] = s end
    end
    return out
end

-- Find type names in the TDB containing a substring (case-insensitive). Results also written to a file.
function dev.find_types(pat, limit)
    local tdb = sdk.get_tdb()
    local res = {}
    pat = pat:lower()
    local n = tdb:get_num_types()
    for i = 0, n - 1 do
        local ok, td = pcall(function() return tdb:get_type(i) end)
        if ok and td then
            local name = td:get_full_name()
            if name and name:lower():find(pat, 1, true) then
                res[#res + 1] = name
                if limit and #res >= limit then break end
            end
        end
    end
    table.sort(res)
    return res
end

function dev.all_types_to_file(path)
    local tdb = sdk.get_tdb()
    local lines = {}
    for i = 0, tdb:get_num_types() - 1 do
        local ok, td = pcall(function() return tdb:get_type(i) end)
        if ok and td then lines[#lines + 1] = td:get_full_name() end
    end
    fs.write(path, table.concat(lines, "\n"))
    return #lines
end

function dev.singletons(pat)
    local res = {}
    for _, s in ipairs(sdk.get_managed_singletons()) do
        local ok, name = pcall(function() return s.instance:get_type_definition():get_full_name() end)
        if ok and (not pat or name:lower():find(pat:lower(), 1, true)) then res[#res + 1] = name end
    end
    table.sort(res)
    return res
end

local function run_cmd(src, id)
    local f, err = load(src, "=bridge", "t", _ENV)
    local out
    if not f then
        out = "LOADERR " .. tostring(err)
    else
        local ok, res = xpcall(f, debug.traceback)
        out = ok and ser(res) or ("ERR " .. tostring(res))
    end
    fs.write(OUT, "--id:" .. id .. "\n" .. out)
end

re.on_pre_application_entry("UpdateBehavior", function()
    tick = tick + 1
    if tick % 10 ~= 0 then return end
    local ok, src = pcall(fs.read, CMD)
    if not ok or src == nil or src == "" then return end
    local id = src:match("^%-%-id:(%S+)")
    if not id or id == last_id then return end
    last_id = id
    run_cmd(src, id)
end)

-- Save guard for tests: while reframework/data/re9coop_bridge/block_saves.flag holds "1", every save
-- request (game slots and the system slot) is skipped and listed in dev.saves, so tests never write
-- the player's save files, and no Steam achievement is unlocked. "2" skips only the system slot (to
-- test the mod's own blocking of game-slot saves: back the save folder up first).
local SAVE_FLAG = "re9coop_bridge/block_saves.flag"
-- a test game never hosts or joins the player's last co-op session by itself
_G.re9coop_test_no_rejoin = true
local block_t, block_v, block_mode = -1, false, ""
local function saves_blocked()
    local t = os.clock()
    if t - block_t > 1 then
        block_t = t
        local ok, s = pcall(fs.read, SAVE_FLAG)
        block_mode = ok and s ~= nil and s:sub(1, 1) or ""
        block_v = block_mode == "1" or block_mode == "2"
    end
    return block_v
end
dev.saves = {}
local skipped = false
local T_SSM = sdk.find_type_definition("app.SaveServiceManager")
-- A skipped save is still reported as done: its requester waits for the request's _SaveFinished (the
-- clear screen's "Next" did nothing, a skipped request never finishing), so it gets one, a frame later,
-- with Success, and the request call says it was taken. Nothing is written.
dev.save_finish = {}
local function finish_later(arg)
    local ok, fin = pcall(function()
        local nv = sdk.to_valuetype(arg, "System.Nullable`1<app.SavedataSaveRequestArgs>")
        if not nv:get_field("_HasValue") then return nil end
        return nv:get_field("_Value"):get_field("_SaveFinished")
    end)
    if ok and fin then
        local okr, held = pcall(fin.add_ref, fin)
        if okr and held then fin = held end
        dev.save_finish[#dev.save_finish + 1] = { fin = fin, t = os.clock() + 0.2 }
    end
end
re.on_pre_application_entry("UpdateBehavior", function()
    if #dev.save_finish == 0 then return end
    local t = os.clock()
    local keep = {}
    for _, e in ipairs(dev.save_finish) do
        if t < e.t then
            keep[#keep + 1] = e
        else
            local once = _G.re9coop_save_done or {}
            _G.re9coop_save_done = once
            local a = e.fin:get_address()
            if not (once[a] and t - once[a] < 5) then
                once[a] = t
                local ok, err = pcall(function()
                    local info = sdk.create_instance("app.SavedataSaveResultInfo"):add_ref()
                    info:call("set_Result", 1) -- Success
                    e.fin:call("Invoke", info)
                end)
                log.info("[re9coop devbridge] skipped save reported done: " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
            end
            pcall(e.fin.release, e.fin)
        end
    end
    dev.save_finish = keep
end)
for _, sig in ipairs({
    "requestSave(app.SaveSlotCategory, app.SaveSlotSelectionMethod, System.Nullable`1<app.SavedataSaveRequestArgs>)",
    "requestSave(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataSaveRequestArgs>)",
    "requestSave(app.SaveSlotIndex, System.Nullable`1<app.SavedataSaveRequestArgs>)",
    "requestSave(app.SaveSlotAddress, System.Nullable`1<app.SavedataSaveRequestArgs>)",
    "requestSaveCore(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataSaveRequestArgs>)",
    "requestSaveCore(app.SaveSlotSegmentType, System.Int32, System.Nullable`1<app.SavedataSaveRequestArgs>)",
}) do
    local m = T_SSM:get_method(sig)
    if m == nil then
        log.info("[re9coop devbridge] no method " .. sig)
    else
        local short = sig:match("^[^(]+") .. "(" .. sig:match("%(([%w%.]+)")
        local last = 2 + m:get_num_params() -- the request's arguments (System.Nullable`1<app.SavedataSaveRequestArgs>)
        sdk.hook(m, function(args)
            local a = sdk.to_int64(args[3]) & 0xFFFFFFFF
            local b = sdk.to_int64(args[4]) & 0xFFFFFFFF
            local block = saves_blocked() -- system saves too (they carry achievement progress)
            if block and block_mode == "2" then block = sig:find("SaveSlotCategory", 1, true) ~= nil and a == 1 end
            local line = string.format("%s %s %d %d %s", os.date("%H:%M:%S"), short, a, b, block and "BLOCKED" or "passed")
            dev.saves[#dev.saves + 1] = line
            log.info("[re9coop devbridge] save " .. line)
            skipped = block
            if block then
                finish_later(args[last])
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(retval)
            if skipped then
                skipped = false
                return sdk.to_ptr(1)
            end
            return retval
        end)
    end
end

-- No Steam achievements from tests either (while the same flag is on).
local skipped_ach = false
local m_ach = sdk.find_type_definition("app.AchievementManager"):get_method("unlockAchievement")
if m_ach then
    sdk.hook(m_ach, function(args)
        skipped_ach = saves_blocked()
        if skipped_ach then
            log.info("[re9coop devbridge] achievement unlock BLOCKED")
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(retval)
        if skipped_ach then
            skipped_ach = false
            return sdk.to_ptr(0)
        end
        return retval
    end)
end

log.info("[re9coop devbridge] ready")
