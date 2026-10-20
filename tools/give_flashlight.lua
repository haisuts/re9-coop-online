-- RE9 co-op: the flashlight back. A co-op playthrough that started as a new game right in the host's
-- chapter (the host's world didn't come) skips the scene where Grace gets the flashlight: it never
-- switches on. This gives it back (the player's FlashLightBlackboardUnit: HasFlashLight and the
-- switching it allows) and switches it on once to show it works.
-- Run it from the REFramework menu (Insert): ScriptRunner > "Run script" > this file. After a game
-- over or a load it may be needed again (mod 0.12.7 does it by itself).
local done = false
sdk.hook(sdk.find_type_definition("app.GuiAutoSaveFlowController"):get_method("update"), function()
    if done then return end
    done = true
    local ok, r = pcall(function()
        local G = _G.re9coop
        local fc = G and G.me and G.me.flashlight
        local bb = fc and fc:get_field("_OwnerLightBlackboardUnit")
        if bb == nil then return "no player flashlight (are you in the game?)" end
        local had = bb:call("get_HasFlashLight")
        bb:call("set_HasFlashLight", true)
        bb:call("set_IsSelfControlFlashLight", true)
        bb:call("set_DisableSelfControlFlashLightByExternal", false)
        bb:call("set_IsDisableFlashLightSwitching", false)
        if not bb:call("get_UseFlashLight") then bb:call("requestSelfSwitchLight") end
        return "flashlight back (had it before: " .. tostring(had) .. ")"
    end)
    log.info("[give_flashlight] " .. tostring(ok and r or ("failed: " .. tostring(r))))
end, nil)
log.info("[give_flashlight] queued")
