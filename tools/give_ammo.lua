-- RE9 co-op test helper: two stacks of handgun ammo (it40_02_000, 15 each, the handgun it10_02_000's)
-- on the floor in front of you, 2.5 m apart. With co-op on, the mod makes the same two in your
-- partner's game (enemy-drop style): one for each of you; picking one up takes it away in both games.
-- Run it once from the REFramework menu (Insert): ScriptRunner > "Run script" > this file. Nothing
-- is reloaded; the result goes to re2_framework_log.txt ("[give_ammo] ...").
local ITEM, COUNT = "it40_02_000", 15
local SIG = "requestGenerateItem(app.ItemAmountData, via.Position, via.Quaternion, app.ItemGenerateRequestType, System.Action`1<app.ItemContext>, System.Action`1<app.ItemCore>)"

-- a fresh stock to fill in (app.ItemAmountData can't be created from Lua): a copy of one in our hands
local function stock_copy()
    local m = sdk.get_managed_singleton("app.InventoryManager")
    for _, e in ipairs(m:get_field("_Inventories"):get_field("_entries"):get_elements()) do
        local v = e:get_field("value")
        if v then
            for _, st in ipairs(v:call("getPanelStates"):get_elements()) do
                local a = st:call("deployAmountData")
                if a and a:get_type_definition():get_full_name() == "app.ItemStockData" then return a:add_ref() end
            end
        end
    end
    return nil
end

local function drop_both()
    local G = _G.re9coop
    local go = G and G.me and G.me.go
    if go == nil then return "no player (are you in the game?)" end
    local id = sdk.find_type_definition("app.ItemID"):get_field(ITEM):get_data(nil)
    local req = sdk.find_type_definition("app.ItemGenerateRequestType"):get_field("ReliefCh"):get_data(nil)
    local im = sdk.get_managed_singleton("app.ItemManager")
    local tr = go:call("get_Transform")
    local p = tr:call("get_Position")
    local rot = tr:call("get_Rotation")
    local fwd, right = rot * Vector3f.new(0, 0, 1), rot * Vector3f.new(1, 0, 0)
    local made = 0
    for _, side in ipairs({ -1.25, 1.25 }) do
        local a = stock_copy()
        if a then
            a:call("set_ItemID", id)
            a:set_field("_Stock", COUNT)
            local pos = ValueType.new(sdk.find_type_definition("via.Position"))
            pos:set_field("x", p.x + fwd.x * 1.2 + right.x * side)
            pos:set_field("y", p.y + 0.1)
            pos:set_field("z", p.z + fwd.z * 1.2 + right.z * side)
            if pcall(im.call, im, SIG, a, pos, Quaternion.new(1, 0, 0, 0), req, nil, nil) then made = made + 1 end
        end
    end
    return string.format("%d stack(s) of %s x%d in front of you", made, ITEM, COUNT)
end

-- inside the game's GUI update (item changes outside it crash the game), once
local done = false
sdk.hook(sdk.find_type_definition("app.GuiAutoSaveFlowController"):get_method("update"), function()
    if done then return end
    done = true
    local ok, r = pcall(drop_both)
    log.info("[give_ammo] " .. tostring(ok and r or ("failed: " .. tostring(r))))
end, nil)
log.info("[give_ammo] queued")
