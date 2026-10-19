-- RE9 Co-op: online co-op for Resident Evil Requiem over Steam
--
-- Your Steam friend appears in your game as a fully posed character (their own costume, every move
-- they make, their gun, its muzzle flash, sounds and flashlight), and you appear in theirs. Enemies,
-- doors, pickups, gimmick states, story steps and chapters are shared, the item box is one box for
-- both, and the guest's game saves when the host's does. Steam lobby + peer-to-peer through Steam's
-- relay network.
--
-- Needs REFramework and reframework/plugins/re9coop_net.dll (the Steam part).
-- Menu: REFramework (Insert) -> Script Generated UI -> "RE9 Co-op (online)".
--
-- How it works: each section below starts with its own notes.
-- * Players: each game reads its own player's skeleton (68 joints) after animation and sends it 20
--   times a second (~600 bytes). The other game builds a "puppet" from the same montage parts and
--   skeleton file and plays the pose back through a small buffer.
-- * Enemies: each one is run by the player it's closest to; the other game spawns a copy, switches
--   its AI off and poses it from the runner's data; damage dealt to a copy goes to the runner.

local VERSION = "0.12.5"
local PROTO = 13
local CONFIG_FILE = "re9coop_config.json"
local TAG = "[re9coop] "

local net = re9coop_net

-------------------------------------------------------------------------------------------------
-- config
-------------------------------------------------------------------------------------------------
local cfg = {
    send_hz = 20,             -- pose packets per second
    interp_delay = 0.12,      -- seconds of buffering for smooth playback
    nametags = true,
    loopback_side = 1.0,      -- self test: where your echo stands, relative to you (m)
    loopback_ahead = 2.5,
    loopback_face = true,     -- self test: the echo faces you (mirror) instead of copying your heading
    loopback_delay_ms = 150,  -- self test: simulated one-way latency
    shot_fx = true,           -- partner's muzzle flash light and gun sounds
    body_sounds = true,       -- partner's footsteps, clothes, breathing: the sounds of their body
    flash_power = 2000,       -- muzzle flash light (the game's own flashlight fill light is 100)
    flash_radius = 5.0,
    enemy_sync = true,        -- share the host's enemies
    enemy_hz = 15,            -- enemy updates per second (host)
    enemy_posed = 4,          -- how many enemies nearest to the guest get their full skeleton
    world_sync = true,        -- share door pushes and pickups
    gimmick_sync = true,      -- share gimmick states (locks, puzzles, switches, used keys)
    story_sync = true,        -- share story progress (level flow steps); experimental
    follow_host = true,       -- the guest goes to the host's chapter
    fresh_join = true,        -- the guest joins from the main menu into a co-op playthrough (own saves untouched)
    box_sync = true,          -- one item box for both players
    save_with_host = true,    -- the guest's game autosaves whenever the host's game saves
    revive = true,            -- a lethal hit downs you while your partner is with you; they get you up
    pickups_for_both = false, -- ammo, healing and crafting items too: each player picks up their own
    recipe_sync = true,       -- a crafting recipe one player unlocks is unlocked for both
    respawn_at_partner = true, -- down and not got up in time: you come to next to your partner
    skip_together = true,     -- a cutscene one player skips is skipped for the other too
    partner_marker = true,    -- the partner on the map and at the screen edge when out of sight
    share_drops = true,       -- what an enemy drops is there for both (one copy, unless each picks their own)
    public_lobby = false,     -- anyone with the lobby ID can join (otherwise friends and invitees)
    auto_rejoin = true,       -- a session that drops (or a game that crashed) is picked up again
    last_host = "",           -- the last session: the host's Steam ID, its lobby, ours?, when (os.time)
    last_lobby = "",
    last_was_host = false,
    last_t = 0,
}

local function load_cfg()
    if fs.read(CONFIG_FILE) == "" then return end
    local ok, t = pcall(json.load_file, CONFIG_FILE)
    if ok and type(t) == "table" then
        for k, v in pairs(t) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
    end
end

local function save_cfg()
    pcall(json.dump_file, CONFIG_FILE, cfg)
end

load_cfg()

-------------------------------------------------------------------------------------------------
-- engine handles
-------------------------------------------------------------------------------------------------
local T_GO = sdk.find_type_definition("via.GameObject")
local M_GO_CREATE = T_GO:get_method("create(System.String)")
local M_GO_DESTROY = T_GO:get_method("destroy(via.GameObject)")
local TYPE_MESH = sdk.typeof("via.render.Mesh")
local TYPE_DUMMYSKEL = sdk.typeof("via.motion.DummySkeleton")
local TYPE_SOUND = sdk.typeof("soundlib.SoundContainer")
local TYPE_POINTLIGHT = sdk.typeof("via.render.PointLight")
local TYPE_SPOTLIGHT = sdk.typeof("via.render.SpotLight")
local TYPE_LIGHTSHAFT = sdk.typeof("via.render.LightShaft")
local TYPE_LENSFLARE = sdk.typeof("via.effect.lensflare.LensflarePlayer")
local TYPE_FLASHLIGHT = sdk.typeof("app.FlashLightController")
local FLAG_FLASHLIGHT = 32
local T_APP = sdk.find_type_definition("via.Application")
local ACT = "System.Action`1<soundlib.SoundManager.RequestInfo>"
local M_SND_FULL = sdk.find_type_definition("soundlib.SoundContainer"):get_method(
    "trigger(System.UInt32, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.UInt32, via.simplewwise.CallbackType, "
    .. ACT .. ", " .. ACT .. ", " .. ACT .. ", " .. ACT .. ")")
local M_SND_AT = sdk.find_type_definition("soundlib.SoundContainer"):get_method(
    "trigger(System.UInt32, via.vec3, via.GameObject, System.UInt32, via.simplewwise.CallbackType, "
    .. ACT .. ", " .. ACT .. ", " .. ACT .. ", " .. ACT .. ")")
local M_MUZZLE = sdk.find_type_definition("app.EPVExpertMuzzleFlashCustom"):get_method(
    "play(via.GameObject, System.Nullable`1<System.Int32>)")

local recent_log = {}
local function say(fmt, ...)
    local s = string.format(fmt, ...)
    log.info(TAG .. s)
    table.insert(recent_log, 1, s)
    if #recent_log > 12 then table.remove(recent_log) end
end

-- The elements of a managed array, or nil when it can't be read. Now and then REFramework hands an
-- array over in a plain-object wrapper (one it made earlier for another object at that address); it
-- is then read through System.Array. A nil must not be taken for "empty".
local function elements(arr)
    if arr == nil then return {} end
    local ok, list = pcall(arr.get_elements, arr)
    if ok and list then return list end
    local okn, n = pcall(arr.call, arr, "get_Length")
    if not okn or type(n) ~= "number" then return nil end
    local out = {}
    for i = 0, n - 1 do
        local okv, v = pcall(arr.call, arr, "GetValue(System.Int32)", i)
        if not okv then return nil end
        out[#out + 1] = v
    end
    return out
end

local function now()
    local app = sdk.get_native_singleton("via.Application")
    if app == nil then return os.clock() end
    return sdk.call_native_func(app, T_APP, "get_UpTimeSecond")
end

local function addr(o)
    if o == nil then return 0 end
    local ok, a = pcall(o.get_address, o)
    return ok and a or 0
end

local function destroy_go(go)
    if go ~= nil then pcall(M_GO_DESTROY.call, M_GO_DESTROY, nil, go) end
end

-- via.Prefab is not a via.ResourceHolder in RE9, so REFramework's create_holder() refuses it.
-- Its layout: +0x10 PrefabResource*, +0x18 System.String path, +0x20 flags (1 = set).
-- Once set_Standby(true) is called the engine's loader keeps a raw pointer to the prefab, so a
-- prefab must never be freed (freeing one crashed the game a few seconds later): one per path,
-- held forever with add_ref_permanent and shared by every puppet. A prefab that only answers
-- get_Exist() and is never put on standby can be a normal, collectable object.
local prefab_cache = {}

local function new_prefab(path, permanent)
    local res = sdk.create_resource("via.PrefabResource", path)
    if res == nil then return nil end
    res:add_ref()
    local pf = sdk.create_instance("via.Prefab", true)
    if pf == nil then return nil end
    local s = sdk.create_managed_string(path)
    if permanent then
        pf:add_ref_permanent()
        s:add_ref_permanent()
    else
        pf, s = pf:add_ref(), s:add_ref()
    end
    pf:write_qword(0x10, res:get_address())
    pf:write_qword(0x18, s:get_address())
    pf:write_qword(0x20, 1)
    return pf
end

local function prefab_exists(path)
    if prefab_cache[path:lower()] then return true end
    local pf = new_prefab(path, false)
    return pf ~= nil and pf:call("get_Exist") == true
end

-- The prefab for a path, loading (standby) and kept forever.
local function load_prefab(path)
    local key = path:lower()
    local pf = prefab_cache[key]
    if pf == nil then
        pf = new_prefab(path, true)
        if pf == nil then return nil end
        pf:call("set_Standby", true)
        prefab_cache[key] = pf
    end
    return pf
end

local function resource_holder(res_type, holder_type, path)
    local res = sdk.create_resource(res_type, path)
    if res == nil then return nil end
    res:add_ref()
    local h = res:create_holder(holder_type)
    return h and h:add_ref() or nil
end

-------------------------------------------------------------------------------------------------
-- the local player
-------------------------------------------------------------------------------------------------
local me = {
    pc = nil, go = nil, go_addr = 0,
    joints = nil, names = nil, j_root = nil, j_hip = nil,
    chapter = "", kind = "",
    appear = nil, appear_blob = nil, appear_key = "", next_appear_check = 0,
    weapon_blob = nil, next_weapon_check = 0,
    weapon_go_addr = 0, weapon_sc = nil, player_sc = nil, sc_addr = 0,
    flashlight = nil,      -- app.FlashLightController under "PlayerFlashLightController"
}

local on_player_lost -- set below: puppets are rebuilt whenever our player object goes away
local in_cutscene -- set in the "story" section: true while a cutscene plays here

local function forget_player()
    if me.go ~= nil and on_player_lost then on_player_lost() end
    me.pc, me.go, me.go_addr = nil, nil, 0
    me.joints, me.names, me.j_root, me.j_hip = nil, nil, nil, nil
    me.weapon_go_addr, me.weapon_sc, me.player_sc, me.flashlight = 0, nil, nil, nil
    me.sc_addr = 0
    me.chapter, me.kind = "", ""
end

local function read_appearance(go)
    local a = { kind = me.kind, skel = "", parts = {} }
    local ds = go:call("getComponent(System.Type)", TYPE_DUMMYSKEL)
    local h = ds and ds:call("get_SkeletonResourceHandle")
    a.skel = h and h:call("get_ResourcePath") or ""
    local c = go:call("get_Transform"):call("get_Child")
    while c do
        local cgo = c:call("get_GameObject")
        local name = cgo and cgo:call("get_Name") or ""
        if name:match("^%d%d$") then
            local mesh = cgo:call("getComponent(System.Type)", TYPE_MESH)
            local mh = mesh and mesh:call("getMesh")
            local mt = mesh and mesh:call("get_Material")
            local mp = mh and mh:call("get_ResourcePath")
            if mp and mp ~= "" then
                a.parts[#a.parts + 1] = { slot = name, mesh = mp, mat = mt and mt:call("get_ResourcePath") or "" }
            end
        end
        c = c:call("get_Next")
    end
    table.sort(a.parts, function(x, y) return x.slot < y.slot end)
    return a
end

local function appearance_key(a)
    local t = { a.kind, a.skel }
    for _, p in ipairs(a.parts) do t[#t + 1] = p.slot .. p.mesh .. p.mat end
    return table.concat(t, "|")
end

-- The weapon in hand: the player's child object named after the equipped WeaponID ("arm0400"),
-- hung on the R_Wep joint. Returns mesh, material ("" when empty-handed).
local function read_weapon(pc, go)
    local ok, id = pcall(function() return pc:call("get_Common"):call("get_EquipWeaponID"):call("ToString") end)
    if not ok or id == nil or not id:match("^arm") then return "", "", nil end
    local c = go:call("get_Transform"):call("get_Child")
    while c do
        local cgo = c:call("get_GameObject")
        if cgo and cgo:call("get_Name") == id then
            local mesh = cgo:call("getComponent(System.Type)", TYPE_MESH)
            local mh = mesh and mesh:call("getMesh")
            local mt = mesh and mesh:call("get_Material")
            return mh and mh:call("get_ResourcePath") or "", mt and mt:call("get_ResourcePath") or "", cgo
        end
        c = c:call("get_Next")
    end
    return "", "", nil
end

-- Called every frame: notices a new player object (load screens, chapter changes, character swaps).
local function refresh_player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local pc = cm and cm:call("get_PlayerContextFast")
    local go = pc and pc:call("get_GameObject")
    if go == nil then
        if me.go ~= nil then forget_player() end
        return false
    end
    local a = addr(go)
    -- a scene change was requested: the old player object is on its way out, leave it alone
    -- (the old object, not just its address: a new player can be made at the very same address, and was
    -- then ignored for a minute, or kept the old joints)
    if me.leaving then
        if a == me.leaving.addr and now() < me.leaving.till then
            local js = go:call("get_Transform"):call("get_Joints")
            local first = js and js:call("get_Length") > 0 and js:call("GetValue(System.Int32)", 0)
            if first == nil or first:get_address() == me.leaving.joint then return false end
            a = -1 -- a new player in the old one's place
        end
        me.leaving = nil
    end
    -- the joints we read are the player's own (checked every second; they are rebuilt with the body)
    if a == me.go_addr and me.joints and now() >= (me.joints_check or 0) then
        me.joints_check = now() + 1
        local js = go:call("get_Transform"):call("get_Joints")
        local n = js and js:call("get_Length") or 0
        local first = n > 0 and js:call("GetValue(System.Int32)", 0) or nil
        if n ~= #me.joints or (first and me.joints[1] and first:get_address() ~= me.joints[1]:get_address()) then a = -1 end
    end
    if a ~= me.go_addr then
        forget_player()
        me.pc, me.go, me.go_addr = pc, go, addr(go)
        local js = go:call("get_Transform"):call("get_Joints")
        if js == nil then forget_player() return false end
        me.joints = js:get_elements()
        me.names = {}
        for i, j in ipairs(me.joints) do
            me.names[i] = j:call("get_Name")
            if me.names[i] == "root" then me.j_root = j end
            if me.names[i] == "Hip" then me.j_hip = j end
        end
        local folder = go:call("get_Folder")
        local path = folder and folder:call("get_Path") or ""
        me.chapter = path:match("^MainGame/([^/]+)") or path
        local ok, kind = pcall(function() return pc:call("get_KindID"):call("ToString") end)
        me.kind = ok and kind or "?"
        me.appear_key = ""
        me.next_appear_check = 0
        me.weapon_blob, me.next_weapon_check = nil, 0
        me.player_sc = go:call("getComponent(System.Type)", TYPE_SOUND)
        me.sc_addr = me.player_sc and me.player_sc:get_address() or 0
        local c = go:call("get_Transform"):call("get_Child")
        while c do
            local cgo = c:call("get_GameObject")
            if cgo and cgo:call("get_Name") == "PlayerFlashLightController" then
                me.flashlight = cgo:call("getComponent(System.Type)", TYPE_FLASHLIGHT)
            end
            c = c:call("get_Next")
        end
        say("player %s in %s (%d joints)", me.kind, me.chapter, #me.joints)
        me.loaded_at, me.announce_load = now(), now() + 10
    end
    return true
end

-------------------------------------------------------------------------------------------------
-- wire format (string.pack, little endian)
-------------------------------------------------------------------------------------------------
local MSG_HELLO, MSG_APPEAR, MSG_POSE, MSG_PING, MSG_PONG, MSG_BYE, MSG_REQ_APPEAR, MSG_WEAPON = 1, 2, 3, 4, 5, 6, 7, 8
local MSG_SHOT, MSG_SOUND = 9, 10
local MSG_ENEMY, MSG_ENEMY_SKEL, MSG_REQ_ENEMY_SKEL, MSG_ENEMY_DAMAGE = 11, 12, 13, 14
local MSG_ENEMY_OWNERS, MSG_ENEMY_PRESENCE = 15, 16
local MSG_DOOR, MSG_ITEM_TAKEN = 17, 18
local MSG_GIMMICK, MSG_GIMMICK_FLAGS = 19, 20
local MSG_STORY = 21
local MSG = { BOX = 22, SAVE = 23, GIMMICK_TRIGGER = 24, REVIVE = 25, RESCUE = 26, RECIPES = 27,
    CUTSCENE = 28, LOADED = 29, STORY_FWD = 30, DROP = 31, DROP_TAKEN = 32, PLAY_REQ = 33, PLAY = 34, KIT = 35, WORLD = 36, CHECK_REQ = 37, CHECK = 38,
    BODY_SOUND = 39, DOOR_ANGLE = 41, GIM_JOINT = 42 }
local FLAG_CUTSCENE = 64
local FLAG_DOWN, FLAG_GRABBED = 128, 256
-- 512 (written as a number where used: the main chunk is at its 200 locals): off the ground, falling or
-- out of the world; nobody's game sends them to us then
local CH_CTRL, CH_POSE, CH_ENEMY = 0, 1, 2

local function q16(v)
    v = math.max(-1.0, math.min(1.0, v))
    return math.floor(v * 32767 + 0.5)
end

local function pack_quat(q, out)
    local s = q.w < 0 and -1 or 1 -- keep w >= 0 so the receiver can slerp the short way
    out[#out + 1] = q16(q.x * s); out[#out + 1] = q16(q.y * s)
    out[#out + 1] = q16(q.z * s); out[#out + 1] = q16(q.w * s)
end

local function unpack_quat(x, y, z, w)
    local q = Quaternion.new(w / 32767, x / 32767, y / 32767, z / 32767)
    return q:normalized()
end

local function msg_hello()
    return string.pack("<BBs2s2", MSG_HELLO, PROTO, VERSION, net and net.my_name() or "?")
end

local function msg_appear(a, names)
    local t = { string.pack("<Bs2s2B", MSG_APPEAR, a.kind, a.skel, #a.parts) }
    for _, p in ipairs(a.parts) do t[#t + 1] = string.pack("<s1s2s2", p.slot, p.mesh, p.mat) end
    t[#t + 1] = string.pack("<B", #names)
    for _, n in ipairs(names) do t[#t + 1] = string.pack("<s1", n) end
    return table.concat(t)
end

local function read_appear(data)
    local a = { parts = {}, names = {} }
    local _, n, pos
    _, a.kind, a.skel, n, pos = string.unpack("<Bs2s2B", data)
    for i = 1, n do
        local p = {}
        p.slot, p.mesh, p.mat, pos = string.unpack("<s1s2s2", data, pos)
        a.parts[i] = p
    end
    n, pos = string.unpack("<B", data, pos)
    for i = 1, n do a.names[i], pos = string.unpack("<s1", data, pos) end
    return a
end

local function local_flags()
    local f = 0
    local ok, common = pcall(function() return me.pc:call("get_Common") end)
    if ok and common then
        if common:call("get_IsCrouch") then f = f | 1 end
        if common:call("get_IsRun") then f = f | 2 end
        if common:call("get_IsHolding") then f = f | 4 end
        if common:call("get_IsShooting") then f = f | 8 end
    end
    if me.pc:call("get_IsFPSCharacter") then f = f | 16 end
    if in_cutscene and in_cutscene() then f = f | FLAG_CUTSCENE end
    if me.down then f = f | FLAG_DOWN end
    -- 1024: dead (on the game over screen until "Continue"): for the partner, as good as down
    if me.dead then f = f | 1024 end
    if me.grabbed then f = f | FLAG_GRABBED end
    if me.falling then f = f | 512 end -- off the ground
    local fc = me.flashlight
    if fc and fc:get_field("_IsLighting") and fc:get_field("_CurrentLightObject") and fc:get_field("_CurrentLight") then
        f = f | FLAG_FLASHLIGHT
    end
    return f
end

local seq = 0
local function msg_pose(t)
    local tr = me.go:call("get_Transform")
    local pos = tr:call("get_Position")
    local rot = tr:call("get_Rotation")
    local rp = me.j_root and me.j_root:call("get_LocalPosition") or Vector3f.new(0, 0, 0)
    local hp = me.j_hip and me.j_hip:call("get_LocalPosition") or Vector3f.new(0, 0, 0)
    local v = {}
    pack_quat(rot, v)
    local head = string.pack("<BHds1fff hhhh ffffff HB", MSG_POSE, seq, t, me.chapter, pos.x, pos.y, pos.z,
        v[1], v[2], v[3], v[4], rp.x, rp.y, rp.z, hp.x, hp.y, hp.z, local_flags(), #me.joints)
    seq = (seq + 1) % 65536
    local q = {}
    for _, j in ipairs(me.joints) do pack_quat(j:call("get_LocalRotation"), q) end
    local msg = head .. string.pack("<" .. string.rep("h", #q), table.unpack(q))
    local hp = me.pc:call("get_HitPoint")
    msg = msg .. string.pack("<i4i4", hp and hp:call("get_CurrentHitPoint") or 0, hp and hp:call("get_CurrentMaximumHitPoint") or 0)
    -- flashlight: where the beam is relative to the body, and how it looks
    local fc = me.flashlight
    if fc and fc:get_field("_IsLighting") then
        local lgo = fc:get_field("_CurrentLightObject")
        local light = fc:get_field("_CurrentLight")
        if lgo and light then
            local lt = lgo:call("get_Transform")
            local inv = rot:inverse()
            local lp = inv * (lt:call("get_Position") - pos)
            local lq = {}
            pack_quat(inv * lt:call("get_Rotation"), lq)
            local cone, spread = 30, 10
            pcall(function() cone, spread = light:call("get_Cone"), light:call("get_Spread") end)
            msg = msg .. string.pack("<fffhhhhfff", lp.x, lp.y, lp.z, lq[1], lq[2], lq[3], lq[4],
                light:call("get_Intensity") or 1500, cone, spread)
        end
    end
    return msg
end

local function read_pose(data)
    local s = {}
    local _, x, y, z, qx, qy, qz, qw, rx, ry, rz, hx, hy, hz, n, pos
    _, s.seq, s.t, s.chapter, x, y, z, qx, qy, qz, qw, rx, ry, rz, hx, hy, hz, s.flags, n, pos =
        string.unpack("<BHds1fff hhhh ffffff HB", data)
    s.pos = Vector3f.new(x, y, z)
    s.rot = unpack_quat(qx, qy, qz, qw)
    s.root = Vector3f.new(rx, ry, rz)
    s.hip = Vector3f.new(hx, hy, hz)
    s.j = {}
    for i = 1, n do
        qx, qy, qz, qw, pos = string.unpack("<hhhh", data, pos)
        s.j[i] = unpack_quat(qx, qy, qz, qw)
    end
    s.hp, s.hp_max, pos = string.unpack("<i4i4", data, pos)
    if s.flags & FLAG_FLASHLIGHT ~= 0 and #data >= pos + 31 then
        local cone, spread
        x, y, z, qx, qy, qz, qw, s.light_intensity, cone, spread, pos = string.unpack("<fffhhhhfff", data, pos)
        s.light_pos, s.light_rot = Vector3f.new(x, y, z), unpack_quat(qx, qy, qz, qw)
        s.light_cone, s.light_spread = cone, spread
    end
    return s
end

-------------------------------------------------------------------------------------------------
-- puppet: the partner's body in our world
-------------------------------------------------------------------------------------------------
local Puppet = {}
Puppet.__index = Puppet

-- "Character/ch/ch02/0200/01/00/ch0200_01_00.mesh" -> part prefab candidates in "Character/ch/ch02/0200/01/"
local function prefab_candidates(mesh)
    local dir, model, slot, var = mesh:match("^(.-/)(%d%d%d%d)/(%d%d)/(%d%d)/[^/]+%.mesh$")
    if not dir then return {} end
    local base = dir .. model .. "/" .. slot .. "/ch" .. model .. "_" .. slot .. "_"
    local c = { base .. var .. "0.pfb", base .. "000.pfb" }
    for i = 1, 12 do c[#c + 1] = base .. string.format("%03d", i) .. ".pfb" end
    return c
end

function Puppet.new(name, appear)
    local p = setmetatable({ name = name, appear = appear, state = "loading", loads = {}, parts = {},
        root = nil, jmap = nil, j_root = nil, j_hip = nil, t0 = now(), visible = true }, Puppet)
    for _, part in ipairs(appear.parts) do
        for _, path in ipairs(prefab_candidates(part.mesh)) do
            if prefab_exists(path) then
                local pf = load_prefab(path)
                if pf then p.loads[#p.loads + 1] = { part = part, pf = pf, path = path } end
                break
            end
        end
    end
    p.skel = resource_holder("via.motion.SkeletonResource", "via.motion.SkeletonResourceHolder", appear.skel)
    if p.skel == nil or #p.loads == 0 then
        p.state = "failed"
        say("can't build %s's character (skeleton %s, %d parts found)", name, appear.skel, #p.loads)
    end
    return p
end

local function set_part_look(go, part)
    local mesh = go:call("getComponent(System.Type)", TYPE_MESH)
    if mesh == nil then return end
    local cur = mesh:call("getMesh")
    if cur and cur:call("get_ResourcePath") == part.mesh then return end
    local mh = resource_holder("via.render.MeshResource", "via.render.MeshResourceHolder", part.mesh)
    local mm = part.mat ~= "" and resource_holder("via.render.MeshMaterialResource", "via.render.MeshMaterialResourceHolder", part.mat)
    if mh then mesh:call("setMesh", mh) end
    if mm then mesh:call("set_Material", mm) end
end

function Puppet:build_step()
    if self.state ~= "loading" then return end
    for _, l in ipairs(self.loads) do
        if not l.pf:call("get_Ready") then
            if now() - self.t0 < 15 then return end
            say("part %s didn't load, skipped", l.path)
            l.skip = true
        end
    end
    local root = M_GO_CREATE:call(nil, "re9coop_" .. self.name)
    if root == nil then self.state = "failed" return end
    self.root = root:add_ref()
    local ds = root:call("createComponent(System.Type)", TYPE_DUMMYSKEL)
    ds:call("set_SkeletonResourceHandle", self.skel)
    local rtr = root:call("get_Transform")
    local origin = Vector3f.new(0, -1000, 0) -- out of sight until the first pose arrives
    rtr:call("set_Position", origin)
    for _, l in ipairs(self.loads) do
        if not l.skip then
            local go = l.pf:call("instantiate(via.vec3)", origin)
            if go then
                go = go:add_ref()
                local t = go:call("get_Transform")
                t:call("setParent(via.Transform, System.Boolean)", rtr, false)
                t:call("set_LocalPosition", Vector3f.new(0, 0, 0))
                t:call("set_LocalRotation", Quaternion.new(1, 0, 0, 0))
                set_part_look(go, l.part)
                self.parts[#self.parts + 1] = go
            end
        end
    end
    self.loads = {}
    pcall(Puppet.bind_strands, self)
    local by_name = {}
    local js = rtr:call("get_Joints")
    for _, j in ipairs(elements(js) or {}) do by_name[j:call("get_Name")] = j end
    self.jmap = {}
    for i, n in ipairs(self.appear.names) do self.jmap[i] = by_name[n] or false end
    self.j_root, self.j_hip = by_name["root"], by_name["Hip"]
    self.state = "ready"
    say("%s's character is ready (%d parts)", self.name, #self.parts)
end

-- Strand hair (Leon's, Grace's): a child "..._Strand_Hair" of the hair part whose GpuStrandsDynamics the
-- game's costume system binds to the part named by its MontageStrandsDynamicsBinder ("10", the face). A
-- puppet has no costume system: its strands stayed unbound, blew up (bounds of 100 km) and the partner
-- looked bald. They are bound here to the puppet's own part, and reset once the puppet stands where it
-- is (the first pose, a teleport), or they would trail from where it was.
Puppet.STRANDS = { dyn = sdk.typeof("via.dynamics.GpuStrandsDynamics"), binder = sdk.typeof("app.MontageStrandsDynamicsBinder"),
    ref = sdk.find_type_definition("via.GameObjectRef") }

function Puppet:bind_strands()
    local T = Puppet.STRANDS
    local by_slot = {}
    for _, go in ipairs(self.parts) do
        local slot = go:call("get_Name"):match("^ch%d%d%d%d_(%d%d)_")
        if slot then by_slot[slot] = go end
    end
    self.strands = {}
    for _, go in ipairs(self.parts) do
        local c = go:call("get_Transform"):call("get_Child")
        while c do
            local g = c:call("get_GameObject")
            local d = g and g:call("getComponent(System.Type)", T.dyn)
            local b = d and g:call("getComponent(System.Type)", T.binder)
            local target = b and by_slot[b:call("get_BindTargetName")]
            if target then
                local ref = ValueType.new(T.ref)
                ref:call(".ctor(via.GameObject)", target)
                d:call("set_BindingGameObject", ref)
                self.strands[#self.strands + 1] = d
            end
            c = c:call("get_Next")
        end
    end
end

function Puppet:apply(pos, rot, s_a, s_b, f)
    local rtr = self.root:call("get_Transform")
    rtr:call("set_Position", pos)
    rtr:call("set_Rotation", rot)
    if self.strands and #self.strands > 0 then
        if self.strand_pos == nil or (pos - self.strand_pos):length() > 3 then self.strand_reset = 2 end
        self.strand_pos = pos
        if self.strand_reset then
            -- two frames later: the joints have taken the new pose by then
            self.strand_reset = self.strand_reset - 1
            if self.strand_reset <= 0 then
                self.strand_reset = nil
                for _, d in ipairs(self.strands) do pcall(d.call, d, "ResetSimulation") end
            end
        end
    end
    local ja, jb = s_a.j, s_b.j
    for i, j in ipairs(self.jmap) do
        if j and ja[i] then
            j:call("set_LocalRotation", (jb[i] and f > 0) and ja[i]:slerp(jb[i], f) or ja[i])
        end
    end
    if self.j_root then self.j_root:call("set_LocalPosition", s_a.root + (s_b.root - s_a.root) * f) end
    if self.j_hip then self.j_hip:call("set_LocalPosition", s_a.hip + (s_b.hip - s_a.hip) * f) end
end

local rig_enable -- below, with the lights

function Puppet:set_visible(v)
    if self.state ~= "ready" or self.visible == v then return end
    self.visible = v
    self.root:call("set_DrawSelf", v)
    for _, go in ipairs(self.parts) do go:call("set_DrawSelf", v) end
    if self.weapon then self.weapon:call("set_DrawSelf", v and self.weapon_mesh ~= "") end
    if not v and self.torch and self.torch_on then
        rig_enable(self.torch, false, false, false)
        self.torch_on = false
    end
end

-- A bare mesh on the R_Wep joint: just the look of the gun, none of its game logic.
function Puppet:set_weapon(mesh_path, mat_path)
    if self.state ~= "ready" or (self.weapon_mesh == mesh_path and self.weapon_mat == mat_path) then return end
    self.weapon_mesh, self.weapon_mat = mesh_path, mat_path
    if self.weapon == nil then
        local go = M_GO_CREATE:call(nil, "re9coop_" .. self.name .. "_weapon")
        if go == nil then return end
        self.weapon = go:add_ref()
        self.weapon_meshc = go:call("createComponent(System.Type)", TYPE_MESH)
        local t = go:call("get_Transform")
        t:call("setParent(via.Transform, System.Boolean)", self.root:call("get_Transform"), false)
        t:call("set_ParentJoint", "R_Wep")
        t:call("set_LocalPosition", Vector3f.new(0, 0, 0))
        t:call("set_LocalRotation", Quaternion.new(1, 0, 0, 0))
    end
    if mesh_path ~= "" then
        local mh = resource_holder("via.render.MeshResource", "via.render.MeshResourceHolder", mesh_path)
        local mm = mat_path ~= "" and resource_holder("via.render.MeshMaterialResource", "via.render.MeshMaterialResourceHolder", mat_path)
        if mh then self.weapon_meshc:call("setMesh", mh) end
        if mm then self.weapon_meshc:call("set_Material", mm) end
    end
    self.weapon:call("set_DrawSelf", self.visible and mesh_path ~= "")
end

-- Lights: a light component made with createComponent() ignores its intensity / cone / spread (they
-- read back 0), so the puppet's lights come from the game's own flashlight pool prefab (a configured
-- SpotLight with a PointLight, light shaft and lens flare under it). One copy is the flashlight, one
-- the muzzle flash.
local LIGHT_RIG_PFB = "AppSystem/Character/CharacterPrefab/PlayerCommon/Prefab/PlayerFlashLightPoolObject.pfb"

local function light_rig(at)
    local pf = load_prefab(LIGHT_RIG_PFB)
    if pf == nil or not pf:call("get_Ready") then return nil end
    local go = pf:call("instantiate(via.vec3)", at)
    if go == nil then return nil end
    local rig = { go = go:add_ref(), spot = go:call("getComponent(System.Type)", TYPE_SPOTLIGHT) }
    local c = go:call("get_Transform"):call("get_Child")
    while c do
        local cgo = c:call("get_GameObject")
        local n = cgo:call("get_Name")
        if n == "PointLight" then rig.point = cgo:call("getComponent(System.Type)", TYPE_POINTLIGHT) end
        if n == "LightShaft" then rig.shaft = cgo:call("getComponent(System.Type)", TYPE_LIGHTSHAFT) end
        if n == "LensFlare" then rig.flare = cgo:call("getComponent(System.Type)", TYPE_LENSFLARE) end
        c = c:call("get_Next")
    end
    return rig
end

rig_enable = function(rig, spot, point, extras)
    if rig == nil then return end
    if rig.spot then rig.spot:call("set_Enabled", spot) end
    if rig.point then rig.point:call("set_Enabled", point) end
    if rig.shaft then pcall(rig.shaft.call, rig.shaft, "set_Enabled", extras) end
    if rig.flare then pcall(rig.flare.call, rig.flare, "set_Enabled", extras) end
end

-- Muzzle flash: a short burst of warm point light at the gun. The game's own muzzle-flash effect
-- can't be used here (handing it the puppet's bare gun object crashed the game).
function Puppet:flash(t_now)
    if self.state ~= "ready" or not self.visible then return end
    local at = self:hand_position()
    if at == nil then return end
    if self.muzzle == nil then
        self.muzzle = light_rig(at)
        if self.muzzle == nil then return end
        rig_enable(self.muzzle, false, false, false)
        if self.muzzle.point then
            self.muzzle.point:call("set_Color", Vector3f.new(1.0, 0.72, 0.38))
            self.muzzle.point:call("set_ShadowEnable", false)
        end
    end
    if self.muzzle.point == nil then return end
    self.muzzle.go:call("get_Transform"):call("set_Position", at)
    self.muzzle.point:call("set_Radius", cfg.flash_radius + 0.0)
    self.muzzle.point:call("set_Intensity", cfg.flash_power + 0.0)
    self.muzzle.point:call("set_Enabled", true)
    self.flash_until = t_now + 0.06
end

-- The partner's flashlight, placed where theirs is relative to their body.
function Puppet:update_flashlight(snap, pos, rot)
    local on = snap ~= nil and snap.light_pos ~= nil and self.visible
    if not on then
        if self.torch and self.torch_on then
            rig_enable(self.torch, false, false, false)
            self.torch_on = false
        end
        return
    end
    if self.torch == nil then
        self.torch = light_rig(pos)
        if self.torch == nil then return end
    end
    local t = self.torch.go:call("get_Transform")
    t:call("set_Position", pos + rot * snap.light_pos)
    t:call("set_Rotation", rot * snap.light_rot)
    local spot = self.torch.spot
    if spot then
        spot:call("set_Intensity", snap.light_intensity + 0.0)
        spot:call("set_Cone", snap.light_cone + 0.0)
        spot:call("set_Spread", snap.light_spread + 0.0)
    end
    if not self.torch_on then
        rig_enable(self.torch, true, true, true)
        self.torch_on = true
    end
end

function Puppet:update_fx(t_now)
    if self.flash_until and t_now >= self.flash_until then
        self.flash_until = nil
        if self.muzzle and self.muzzle.point then self.muzzle.point:call("set_Enabled", false) end
    end
end

function Puppet:hand_position()
    if self.state ~= "ready" then return nil end
    local j = self.root:call("get_Transform"):call("getJointByName", "R_Wep")
    return j and j:call("get_Position") or nil
end

function Puppet:head_position()
    if self.state ~= "ready" then return nil end
    local t = self.root:call("get_Transform")
    local j = t:call("getJointByName", "Head_0") or t:call("getJointByName", "Head")
    return j and j:call("get_Position") or nil
end

function Puppet:destroy()
    self.jmap, self.j_root, self.j_hip, self.weapon_meshc = nil, nil, nil, nil
    if self.muzzle then destroy_go(self.muzzle.go) end
    if self.torch then destroy_go(self.torch.go) end
    self.muzzle, self.torch, self.torch_on = nil, nil, false
    destroy_go(self.weapon)
    for _, go in ipairs(self.parts) do destroy_go(go) end
    destroy_go(self.root)
    self.parts, self.root, self.weapon, self.state = {}, nil, nil, "gone"
end

-------------------------------------------------------------------------------------------------
-- remote peers
-------------------------------------------------------------------------------------------------
local LOOPBACK_ID = "1"
local peers = {}          -- steam id string -> peer
local enemy_ctrl, enemy_recv, enemies_reset -- set in the "shared enemies" section
local world_ctrl, world_reset -- set in the "shared doors and pickups" section
local gimmick_ctrl, gimmick_reset -- set in the "shared gimmick states" section
local story_ctrl, story_reset, go_to_partner_chapter -- set in the "story" section
-- Functions set by the later sections (item box, saves, downed / grabbed), and the jobs that must run
-- inside the game's GUI update: everything that changes the game's world (scene jumps, story steps,
-- doors, pickups, saves, inventories). Done from REFramework's frame callbacks, such changes crashed
-- the game a moment later on one of its worker threads (heap corruption, mostly in its lock-on scan).
local ext = { jobs = {} }
ext.later = function(fn)
    if #ext.jobs < 1024 then ext.jobs[#ext.jobs + 1] = fn end
end
local loopback = false
local stats = { tx = 0, rx = 0, tx_bytes = 0, rx_bytes = 0, rate_t = 0, tx_kbps = 0, rx_kbps = 0 }

local function peer(id)
    local p = peers[id]
    if p == nil then
        p = { id = id, name = id == LOOPBACK_ID and "Echo (you)" or "?", proto = 0, appear = nil, puppet = nil,
              snaps = {}, off = nil, last = 0, rtt = nil, chapter = "", asked = 0 }
        peers[id] = p
    end
    return p
end

local function drop_peer(id)
    local p = peers[id]
    if p == nil then return end
    if p.puppet then p.puppet:destroy() end
    peers[id] = nil
    if ext.on_peer_left then pcall(ext.on_peer_left, id) end
    say("%s left", p.name)
end

-------------------------------------------------------------------------------------------------
-- shots and gun sounds
-------------------------------------------------------------------------------------------------
local fx_out = {}          -- our own shots / gun sounds caught by the hooks, sent from tick_send
local fx_replaying = false -- true while we play a partner's sound, so our own hook ignores it

-- One muzzle flash per shot of our equipped gun.
sdk.hook(M_MUZZLE, function(args)
    if me.weapon_go_addr == 0 or #fx_out >= 32 then return end
    local this = sdk.to_managed_object(args[2])
    local go = this and this:call("get_GameObject")
    if go and go:get_address() == me.weapon_go_addr then fx_out[#fx_out + 1] = string.pack("<B", MSG_SHOT) end
end, nil)

-- Every sound our gun makes (shot, tail, mechanics, raise / lower, empty click): the first
-- GameObject argument is the gun. Compared as raw pointers: this runs for every sound in the game.
sdk.hook(M_SND_FULL, function(args)
    if fx_replaying or me.weapon_go_addr == 0 or #fx_out >= 32 then return end
    if sdk.to_int64(args[4]) == me.weapon_go_addr then
        fx_out[#fx_out + 1] = string.pack("<BI4", MSG_SOUND, sdk.to_int64(args[3]) & 0xFFFFFFFF)
    end
end, nil)

-- The sounds of our body: footsteps (on whatever floor is underfoot), clothes, breathing, hands. Our
-- player's own sound container starts them with our player as the source object; they're caught as
-- they start (every sound in the game passes here: the container is compared first, as a raw pointer).
sdk.hook(sdk.find_type_definition("soundlib.SoundContainer"):get_method(
    "onPostRequestInfoStart(soundlib.SoundManager.RequestInfo)"), function(args)
    if me.sc_addr == 0 or sdk.to_int64(args[2]) ~= me.sc_addr or #fx_out >= 32 or not cfg.body_sounds then return end
    local ri = sdk.to_managed_object(args[3])
    local src = ri and ri:get_field("<SrcGameObj>k__BackingField")
    if src == nil or src:get_address() ~= me.go_addr then return end
    local id = ri:get_field("_TriggerId")
    if id then fx_out[#fx_out + 1] = string.pack("<BI4", MSG.BODY_SOUND, id & 0xFFFFFFFF) end
end, nil)

-- Played through our own player's sound container (the same character: the same trigger list) with the
-- partner's copy as the source object, the way the game starts our own: the trigger's joint (a foot, a
-- hand) is found on the copy's skeleton and the container picks the floor material and our status
-- switches itself. A character other than ours may have triggers we don't know: those are silent.
me.play_body_sound = function(p, id)
    local pup = p.puppet
    if not cfg.body_sounds or pup == nil or pup.state ~= "ready" or not pup.visible or me.player_sc == nil then return end
    fx_replaying = true
    pcall(M_SND_FULL.call, M_SND_FULL, me.player_sc, id, pup.root, nil, 0xFFFFFFFF, false, 0, 1, nil, nil, nil, nil)
    fx_replaying = false
end

-- Played through our own gun's sound container (it has the gun sound banks loaded), placed at the
-- partner's hand. A gun we don't carry may have no bank loaded here; then it's silent.
local function play_partner_sound(p, id)
    local pup = p.puppet
    if not cfg.shot_fx or pup == nil or pup.state ~= "ready" or not pup.visible then return end
    local sc = me.weapon_sc or me.player_sc
    local pos = pup:hand_position()
    if sc == nil or pos == nil then return end
    fx_replaying = true
    pcall(M_SND_AT.call, M_SND_AT, sc, id, pos, nil, 0xFFFFFFFF, 1, nil, nil, nil, nil)
    fx_replaying = false
end

-- A load screen or chapter change can tear down scene objects, ours included; never keep
-- references across it.
on_player_lost = function()
    for _, p in pairs(peers) do
        if p.puppet then p.puppet:destroy() p.puppet = nil end
        p.snaps = {}
    end
    if enemies_reset then enemies_reset(false) end
    if world_reset then world_reset() end
    if gimmick_reset then gimmick_reset() end
    if story_reset then story_reset() end
    if ext.box_reset then ext.box_reset() end
end

local function send_ctrl(data, to)
    if net == nil then return end
    local n = net.send(data, true, CH_CTRL, to)
    stats.tx, stats.tx_bytes = stats.tx + n, stats.tx_bytes + #data * n
end

local function announce(to)
    send_ctrl(msg_hello(), to)
    if me.appear then send_ctrl(me.appear_blob, to) end
    if me.weapon_blob then send_ctrl(me.weapon_blob, to) end
end

local function on_ctrl(from, data)
    local kind = string.byte(data, 1)
    local p = peer(from)
    if kind == MSG_HELLO then
        local _, proto, ver, name = string.unpack("<BBs2s2", data)
        p.proto, p.name = proto, (from == LOOPBACK_ID) and ("Echo of " .. name) or name
        if proto ~= PROTO then say("%s runs co-op %s (protocol %d, we have %d)", name, ver, proto, PROTO) end
    elseif kind == MSG_APPEAR then
        local ok, a = pcall(read_appear, data)
        if not ok then return end
        -- the joint list counts too: the same look on a new player object can come with its joints in
        -- another order, and a copy built for the old order put every pose on the wrong joints (it stood
        -- frozen in an odd pose while it moved about)
        local key = appearance_key(a) .. "|" .. table.concat(a.names, ",")
        if p.appear_key ~= key then
            p.appear, p.appear_key = a, key
            if p.puppet then p.puppet:destroy() p.puppet = nil end
        end
    elseif kind == MSG_WEAPON then
        local _, mesh, mat = string.unpack("<Bs2s2", data)
        p.weapon = { mesh = mesh, mat = mat }
    elseif kind == MSG_SHOT then
        if cfg.shot_fx and p.puppet then p.puppet:flash(now()) end
    elseif kind == MSG_SOUND then
        local _, id = string.unpack("<BI4", data)
        play_partner_sound(p, id)
    elseif kind == MSG.BODY_SOUND then
        local _, id = string.unpack("<BI4", data)
        me.play_body_sound(p, id)
    elseif kind == MSG_REQ_APPEAR then
        if from ~= LOOPBACK_ID then announce(from) end
    elseif kind == MSG_PING then
        local _, t = string.unpack("<Bd", data)
        if from ~= LOOPBACK_ID then send_ctrl(string.pack("<Bd", MSG_PONG, t), from) end
    elseif kind == MSG_PONG then
        local _, t = string.unpack("<Bd", data)
        p.rtt = now() - t
    elseif kind == MSG_BYE then
        drop_peer(from)
    elseif kind >= MSG_ENEMY and kind <= MSG_ENEMY_PRESENCE and enemy_ctrl then
        enemy_ctrl(from, kind, data)
    elseif (kind == MSG_DOOR or kind == MSG_ITEM_TAKEN or kind == MSG.DOOR_ANGLE or kind == MSG.GIM_JOINT) and world_ctrl then
        ext.later(function() world_ctrl(from, kind, data) end)
    elseif (kind == MSG_GIMMICK or kind == MSG_GIMMICK_FLAGS or kind == MSG.GIMMICK_TRIGGER) and gimmick_ctrl then
        gimmick_ctrl(from, kind, data)
    elseif (kind == MSG_STORY or kind == MSG.STORY_FWD) and story_ctrl then
        ext.later(function() story_ctrl(from, kind, data) end)
    elseif kind == MSG.BOX and ext.box_ctrl then
        ext.box_ctrl(from, kind, data)
    elseif kind == MSG.SAVE and ext.saves_ctrl then
        ext.saves_ctrl(from, kind, data)
    elseif (kind == MSG.REVIVE or kind == MSG.RESCUE) and ext.life_ctrl then
        ext.life_ctrl(from, kind, data)
    elseif kind == MSG.RECIPES and ext.recipes_ctrl then
        ext.recipes_ctrl(from, kind, data)
    elseif kind == MSG.LOADED and ext.loaded_ctrl then
        ext.loaded_ctrl(from, kind, data)
    elseif kind == MSG.CUTSCENE and ext.cut_ctrl then
        ext.cut_ctrl(from, kind, data)
    elseif (kind == MSG.DROP or kind == MSG.DROP_TAKEN) and ext.drops_ctrl then
        ext.drops_ctrl(from, kind, data)
    elseif kind >= MSG.PLAY_REQ and kind <= MSG.WORLD and ext.fresh_ctrl then
        ext.fresh_ctrl(from, kind, data)
    elseif (kind == MSG.CHECK_REQ or kind == MSG.CHECK) and ext.check_ctrl then
        ext.check_ctrl(from, kind, data)
    end
end

local function on_pose(from, data, t_now)
    local ok, s = pcall(read_pose, data)
    if not ok then return end
    local p = peer(from)
    -- clock offset = smallest (arrival - send) seen, slowly forgotten so drift is tracked
    local sample = t_now - s.t
    p.off = (p.off == nil) and sample or math.min(p.off + 0.0005, sample)
    p.last = t_now
    p.chapter = s.chapter
    p.flags = s.flags
    local snaps = p.snaps
    if #snaps > 0 and s.t <= snaps[#snaps].t then return end -- old or duplicate
    snaps[#snaps + 1] = s
    while #snaps > 12 do table.remove(snaps, 1) end
    if p.appear == nil and t_now - p.asked > 2 then
        p.asked = t_now
        if from ~= LOOPBACK_ID then send_ctrl(string.pack("<B", MSG_REQ_APPEAR), from) end
    end
end

local function receive()
    if net == nil then return end
    local t_now = now()
    for _, m in ipairs(net.recv(CH_CTRL, 64)) do
        stats.rx, stats.rx_bytes = stats.rx + 1, stats.rx_bytes + #m.data
        pcall(on_ctrl, m.from, m.data)
    end
    for _, m in ipairs(net.recv(CH_POSE, 256)) do
        stats.rx, stats.rx_bytes = stats.rx + 1, stats.rx_bytes + #m.data
        on_pose(m.from, m.data, t_now)
    end
    for _, m in ipairs(net.recv(CH_ENEMY, 512)) do
        stats.rx, stats.rx_bytes = stats.rx + 1, stats.rx_bytes + #m.data
        if enemy_recv then enemy_recv(m.from, m.data, t_now) end
    end
end

-- Sample the snapshot buffer at render time (sender's clock) and drive the puppet.
local function update_peer(p, t_now)
    if p.appear == nil or me.go == nil then return end
    if p.puppet == nil then p.puppet = Puppet.new(p.id == LOOPBACK_ID and "echo" or p.id, p.appear) end
    local pup = p.puppet
    pup:build_step()
    if pup.state ~= "ready" then return end
    if p.weapon then pup:set_weapon(p.weapon.mesh, p.weapon.mat) end
    pup:update_fx(t_now)
    local snaps = p.snaps
    local stale = t_now - p.last > 5
    local same_place = p.chapter == me.chapter
    local last = snaps[#snaps]
    local cutscene = (last and last.flags and last.flags & FLAG_CUTSCENE ~= 0) or (in_cutscene and in_cutscene())
    pup:set_visible(#snaps > 0 and not stale and same_place and not cutscene)
    if #snaps == 0 or stale or not same_place or cutscene then return end
    local rt = t_now - p.off - cfg.interp_delay
    local a, b = snaps[#snaps], snaps[#snaps]
    for i = #snaps - 1, 1, -1 do
        if snaps[i].t <= rt then a, b = snaps[i], snaps[i + 1] break end
        a, b = snaps[i], snaps[i]
    end
    local f = 0
    if b.t > a.t then f = math.max(0, math.min(1, (rt - a.t) / (b.t - a.t))) end
    local pos = a.pos + (b.pos - a.pos) * f
    local rot = a.rot:slerp(b.rot, f)
    if p.id == LOOPBACK_ID then
        pos = pos + rot * Vector3f.new(cfg.loopback_side, 0, cfg.loopback_ahead)
        if cfg.loopback_face then rot = rot * Quaternion.new(0, 0, 1, 0) end -- turned round to face you
    end
    pup:apply(pos, rot, a, b, f)
    pup:update_flashlight(f >= 0.5 and b or a, pos, rot)
end

-------------------------------------------------------------------------------------------------
-- session
-------------------------------------------------------------------------------------------------
local session = { last_members = "", next_ping = 0, next_send = 0, next_join_poll = 0, status = nil,
    was_in = false, left = false, rj = nil }

-------------------------------------------------------------------------------------------------
-- shared enemies: each enemy is run by the player it is closest to
-------------------------------------------------------------------------------------------------
-- Enemy contexts are identified by their scene GUID (app.ContextID), the same on both PCs.
-- Ownership: the lobby owner is the arbiter. Twice a second it gives every spawned enemy to the
--   nearer player (with a few metres of hysteresis; dead enemies keep their owner) and sends the
--   changes (MSG_ENEMY_OWNERS). An enemy nobody assigned yet belongs to whoever spawned it.
-- Owner: the enemy's AI runs normally, so it hunts, grabs and hurts that player for real. Its state
--   goes to the other player 15 times a second (MSG_ENEMY; the nearest few with their full skeleton).
-- Other player: the same enemy is spawned through its own spawn control, its AI (think, lock-on,
--   out-of-area drivers) is switched off, and it is warped and posed from the owner's data. Damage
--   dealt to it is caught before it lands and sent to the owner. The game's own spawn logic is not
--   allowed to put it away while the owner still has it.
-- Ownership moving to us: the copy's health is set to the last value we were sent and it gets its AI
--   back. Ownership moving away: our enemy becomes a puppet.
-- Each player also reports the enemies it has spawned (MSG_ENEMY_PRESENCE) so the arbiter can hand an
--   enemy to the guest even when the host's copy is gone.
local F_SPAWNED, F_DEAD, F_POSE = 1, 2, 4
local T_NV3 = sdk.find_type_definition("System.Nullable`1<via.vec3>")
local T_NQ = sdk.find_type_definition("System.Nullable`1<via.Quaternion>")
local WARP_SIG = "requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)"
local ADD_HP_SIG = "addDamageHitPoint(System.Int32, System.Boolean, System.Boolean)"
local ADD_RHP_SIG = "addDamageReactionHP(System.Int32, System.Boolean, System.Boolean)"
local M_ADD_HP = sdk.find_type_definition("app.HitPoint"):get_method(ADD_HP_SIG)
local M_ADD_RHP = sdk.find_type_definition("app.HitPoint"):get_method(ADD_RHP_SIG)
local TYPE_OUT_OF_AREA = sdk.typeof("app.CharacterOutOfAreaDriver")
local ENEMY_HEAD = "<BHds1s1s1Bfffhhhhi4"
local OWNER_HYSTERESIS = 3.0 -- metres the other player must be closer by before an enemy changes hands

local foes = {
    active = false,        -- sharing enemies with someone right now
    arbiter = false,       -- we decide who owns what (lobby owner)
    peer_id = nil,         -- the other player
    index = {}, index_t = 0, index_chapter = "",  -- id -> { ctx, kind, ctl, orphan_since }
    owner = {},            -- id -> true: ours, false: theirs, nil: not assigned (ours if spawned here)
    -- sending (enemies we own)
    next_send = 0, seq = 0, skel_sent = {}, joints = {},
    next_presence = 0,
    -- receiving (enemies they own)
    states = {},           -- id -> { snaps, last, kind, flags, hp, chapter, next_spawn, tries }
    puppets = {},          -- id -> { e, ctl, go, upd, kind, jmap, j_hip, hp_addr, ctl_addr }
    hp_owner = {},         -- HitPoint address -> enemy id (puppets only)
    ctl_owner = {},        -- spawn control address -> enemy id (puppets only)
    names = {},            -- kind -> joint names sent by the other player
    asked = {},            -- kind -> when we last asked for them
    dmg_out = {},          -- damage caught on puppets, waiting to be sent to the owner
    bypass = false,        -- true while we apply damage ourselves
    self_call = false,     -- true while we call a spawn control ourselves
    -- arbiter
    next_arbitrate = 0, next_full_owners = 0,
    presence = {},         -- id -> { pos, dead, t } enemies the other player has spawned
    -- kind -> true: run by one player for the whole fight (see owner_decision). Picked from the chapter
    -- sweep (one of its kind in a chapter) and their own types: B700 (battle area), C100 (phase
    -- driver), C510 (car throws, parries), C900 (slams, with C901 adds), D100 (rocket launcher,
    -- sandstorm, phases), D110 (weak points, battle cycles), B052 (blood-fog core), C610 (phase attacks)
    bosses = { cp_B700 = true, cp_C100 = true, cp_C510 = true, cp_C900 = true, cp_D100 = true, cp_D110 = true,
        cp_B052 = true, cp_C610 = true },
    stats = { sent = 0, puppets = 0, owned = 0, dmg_sent = 0, dmg_applied = 0, handovers = 0 },
    -- one-PC test (dev bridge only): with the self test on, enemy `src` (ours) is sent through the
    -- loopback and what arrives drives enemy `dst` (theirs), so dst copies src 150 ms late; hits on dst
    -- land on src. { src = id, dst = id, offset = Vector3f? }
    test = nil,
}

local function nullable_vec3(v)
    local n = ValueType.new(T_NV3)
    n:write_byte(0, 1)
    n:write_float(16, v.x); n:write_float(20, v.y); n:write_float(24, v.z)
    return n
end

local function nullable_quat(q)
    local n = ValueType.new(T_NQ)
    n:write_byte(0, 1)
    n:write_float(16, q.x); n:write_float(20, q.y); n:write_float(24, q.z); n:write_float(28, q.w)
    return n
end

local function int32(v)
    v = v & 0xFFFFFFFF
    return v >= 0x80000000 and v - 0x100000000 or v
end

local function character_manager()
    return sdk.get_managed_singleton("app.CharacterManager")
end

local function refresh_index(t_now)
    if t_now < foes.index_t and foes.index_chapter == me.chapter then return end
    foes.index_t, foes.index_chapter = t_now + 2, me.chapter
    local cm = character_manager()
    local list = cm and cm:call("get_EnemyContextList")
    if list == nil then return end
    local old, idx = foes.index, {}
    for i = 0, list:call("get_Count") - 1 do
        local ctx = list:call("get_Item", i)
        local ok, id = pcall(function() return ctx:call("get_ID"):call("ToString") end)
        if ok and id then
            local e = old[id]
            if e == nil or e.ctx:get_address() ~= ctx:get_address() then
                local okk, kind = pcall(function() return ctx:call("get_KindID"):call("ToString") end)
                e = { ctx = ctx, kind = okk and kind or "?" }
            end
            idx[id] = e
        end
    end
    foes.index = idx
end

-- A spawn control loads with its area (a boss's with its arena), often after the enemy's context is
-- indexed: a miss is looked up again a second later, a hit every 5 s (the area may have unloaded).
local function spawn_control(e)
    local t = now()
    if t >= (e.ctl_t or 0) then
        local sd = character_manager():call("getSpawnDataRef", e.ctx:call("get_ID"))
        e.ctl = sd and sd:call("get_SpawnControl") or nil
        e.ctl_t = t + (e.ctl and 5 or 1)
    end
    return e.ctl
end

-- Our own calls on a spawn control (the suspend guard below lets these through).
local function ctl_request(ctl, method)
    foes.self_call = true
    local ok = pcall(ctl.call, ctl, method)
    foes.self_call = false
    return ok
end

local function set_ai(upd, go, on)
    for _, getter in ipairs({ "get_ThinkDriver", "get_LockOnTargetDriver" }) do
        local d = upd:call(getter)
        if d then d:call("set_IsEnable", on) end
    end
    local oa = go:call("getComponent(System.Type)", TYPE_OUT_OF_AREA)
    if oa then oa:call("set_IsEnable", on) end
end

local function release_puppet(id, restore_ai)
    local pup = foes.puppets[id]
    if pup == nil then return end
    if pup.hp_addr ~= 0 then foes.hp_owner[pup.hp_addr] = nil end
    if pup.ctl_addr ~= 0 then foes.ctl_owner[pup.ctl_addr] = nil end
    if restore_ai then pcall(set_ai, pup.upd, pup.go, true) end
    foes.puppets[id] = nil
end

-- scene_alive = false after a load screen: the objects may be gone, so only forget them.
enemies_reset = function(scene_alive)
    for id in pairs(foes.puppets) do
        if scene_alive then release_puppet(id, true) end
    end
    foes.puppets, foes.hp_owner, foes.ctl_owner, foes.states, foes.joints = {}, {}, {}, {}, {}
    foes.index, foes.index_t, foes.skel_sent, foes.owner, foes.presence = {}, 0, {}, {}, {}
end

-- Only after the spawn has completed with its AI on: turning AI off earlier leaves it asleep.
-- wake: the owner's copy is up. A boss spawns asleep and waits for its entrance; when the owner's
-- game has it up and ours doesn't yet (its story a step behind), ours is woken and becomes a puppet.
local function puppetize(id, e, wake)
    local ctl = spawn_control(e)
    local go = ctl and ctl:call("getSpawnInstance")
    if go == nil or not ctl:call("get_HasCompletedSpawn") then return end
    if not go:call("get_UpdateSelf") then
        if wake then go:call("set_UpdateSelf", true) end
        return
    end
    local upd = e.ctx:call("get_CharacterUpdaterBase")
    if upd == nil then return end
    set_ai(upd, go, false)
    local hp = e.ctx:call("get_HitPoint")
    local pup = { e = e, ctl = ctl, go = go, upd = upd, kind = e.kind, hp_addr = addr(hp), ctl_addr = addr(ctl) }
    foes.puppets[id] = pup
    if pup.hp_addr ~= 0 then foes.hp_owner[pup.hp_addr] = id end
    if pup.ctl_addr ~= 0 then foes.ctl_owner[pup.ctl_addr] = id end
end

-- Damage the host of the damage message gets applied without being forwarded again.
local function apply_damage(e, which, dmg, b1, b2)
    local hp = e.ctx:call("get_HitPoint")
    if hp == nil then return end
    foes.bypass = true
    pcall(function() hp:call(which == 0 and ADD_HP_SIG or ADD_RHP_SIG, dmg, b1, b2) end)
    foes.bypass = false
end

-- The enemy comes to us: it keeps the health it had on the other side and gets its AI back.
local function take_over(id)
    local pup = foes.puppets[id]
    local st = foes.states[id]
    local e = foes.index[id]
    if e and st and st.hp then
        local hp = e.ctx:call("get_HitPoint")
        local cur = hp and hp:call("get_CurrentHitPoint") or 0
        if cur > st.hp then apply_damage(e, 0, cur - st.hp, false, false) end
    end
    if pup then release_puppet(id, true) end
    foes.states[id] = nil
    foes.stats.handovers = foes.stats.handovers + 1
end

local function set_owner(id, mine)
    if foes.owner[id] == mine then return end
    foes.owner[id] = mine
    if mine then take_over(id) end
    -- becoming theirs: enemies_tick turns our copy into a puppet
end

-- sending the enemies we own --------------------------------------------------------------------

local function enemy_joints(go, kind)
    local a = go:get_address()
    local j = foes.joints[a]
    if j then return j end
    local js = go:call("get_Transform"):call("get_Joints")
    local list = js and elements(js)
    if list == nil then return nil end
    -- the joint count travels as a byte; big creatures send their first 255 (the body, not the fingers)
    if #list > 255 then list = { table.unpack(list, 1, 255) } end
    j = { list = list, names = {}, kind = kind }
    for i, x in ipairs(j.list) do
        j.names[i] = x:call("get_Name")
        if j.names[i] == "Hip" then j.hip = x end
    end
    foes.joints[a] = j
    return j
end

local function send_skeleton(kind, names, to)
    local t = { string.pack("<Bs1B", MSG_ENEMY_SKEL, kind, #names) }
    for _, n in ipairs(names) do t[#t + 1] = string.pack("<s1", n) end
    send_ctrl(table.concat(t), to)
end

local function peer_position()
    local p = foes.peer_id and peers[foes.peer_id]
    return p and #p.snaps > 0 and p.snaps[#p.snaps].pos or nil, p
end

local function send_owned(t_now)
    if t_now < foes.next_send then return end
    foes.next_send = t_now + 1 / math.max(1, cfg.enemy_hz)
    local ppos = peer_position()
    local live = {}
    for id, e in pairs(foes.index) do
        local ours = foes.test == nil and foes.owner[id] ~= false or (foes.test and id == foes.test.src)
        if ours and e.ctx:call("get_IsSpawn") then
            local go = e.ctx:call("get_GameObject")
            if go then
                local pos = go:call("get_Transform"):call("get_Position")
                -- bosses first: they always get their full skeleton
                local d = foes.bosses[e.kind] and -1 or ppos and (pos - ppos):length() or 0
                live[#live + 1] = { id = id, e = e, go = go, pos = pos, d = d }
            end
        end
    end
    table.sort(live, function(a, b) return a.d < b.d end)
    foes.stats.owned = #live
    for i, x in ipairs(live) do
        local rot = x.go:call("get_Transform"):call("get_Rotation")
        local hp = x.e.ctx:call("get_HitPoint")
        local flags = F_SPAWNED | (x.e.ctx:call("get_IsDead") and F_DEAD or 0)
        local jt = i <= cfg.enemy_posed and enemy_joints(x.go, x.e.kind) or nil
        if jt then flags = flags | F_POSE end
        local q = {}
        pack_quat(rot, q)
        local msg = string.pack(ENEMY_HEAD, MSG_ENEMY, foes.seq, t_now, me.chapter, x.id, x.e.kind, flags,
            x.pos.x, x.pos.y, x.pos.z, q[1], q[2], q[3], q[4], hp and hp:call("get_CurrentHitPoint") or 0)
        if jt then
            local hip = jt.hip and jt.hip:call("get_LocalPosition") or Vector3f.new(0, 0, 0)
            local jq = {}
            for _, j in ipairs(jt.list) do pack_quat(j:call("get_LocalRotation"), jq) end
            msg = msg .. string.pack("<fffB", hip.x, hip.y, hip.z, #jt.list)
                .. string.pack("<" .. string.rep("h", #jq), table.unpack(jq))
            if not foes.skel_sent[x.e.kind] then
                foes.skel_sent[x.e.kind] = true
                send_skeleton(x.e.kind, jt.names, foes.peer_id)
            end
        end
        local n = net.send(msg, false, CH_ENEMY, foes.peer_id)
        stats.tx, stats.tx_bytes = stats.tx + n, stats.tx_bytes + #msg * n
    end
    foes.seq = (foes.seq + 1) % 65536
end

-- The non-arbiter tells the arbiter which enemies it has spawned and where (puppets included).
local function send_presence(t_now)
    if t_now < foes.next_presence then return end
    foes.next_presence = t_now + 0.5
    local t = {}
    local n = 0
    for id, e in pairs(foes.index) do
        if e.ctx:call("get_IsSpawn") and n < 64 then
            local go = e.ctx:call("get_GameObject")
            if go then
                local p = go:call("get_Transform"):call("get_Position")
                t[#t + 1] = string.pack("<s1fffB", id, p.x, p.y, p.z, e.ctx:call("get_IsDead") and 1 or 0)
                n = n + 1
            end
        end
    end
    send_ctrl(string.pack("<Bs1B", MSG_ENEMY_PRESENCE, me.chapter, n) .. table.concat(t), foes.peer_id)
end

-- arbiter ----------------------------------------------------------------------------------------

local function send_owners(changes)
    if #changes == 0 then return end
    local t = { string.pack("<BH", MSG_ENEMY_OWNERS, #changes) }
    for _, c in ipairs(changes) do t[#t + 1] = string.pack("<s1B", c[1], c[2] and 1 or 0) end
    send_ctrl(table.concat(t), foes.peer_id)
end

-- Who should run an enemy (true = the arbiter, false = the other player). cur: current owner or nil.
-- An enemy goes for the player whose game runs it. One player down and the other not (me_down /
-- peer_down: the arbiter's player, the other one): the one standing runs it, or it would stay over a
-- player it can't hurt while the other fights it untouched.
-- boss: otherwise it keeps its owner for the whole fight (a handover restarts its AI, which breaks its
-- phases); it moves when the owner's copy is gone (here / there: spawned on the arbiter's / other
-- side), or when its owner has left it (BOSS_LEFT m off) with the other player at it (BOSS_NEAR m).
-- Pure, so tools/test_owner_decision.lua can check it outside the game.
local function owner_decision(cur, together, dead, dme, dpeer, boss, here, there, me_down, peer_down)
    if not together then return true end
    if dead then
        if cur == nil then return true end
        return cur
    end
    -- (only to a game that has it spawned: given to the other player's game without one, nobody ran
    -- a boss whose arena wasn't loaded there)
    if me_down and not peer_down and there then return false end
    if peer_down and not me_down and here then return true end
    if boss and cur ~= nil then
        if cur and not here and there then return false end
        if not cur and here and not there then return true end
        if cur and dme > 20 and dpeer < 8 then return false end -- BOSS_LEFT, BOSS_NEAR
        if not cur and dpeer > 20 and dme < 8 then return true end
        return cur
    end
    if cur == nil then return dme <= dpeer end
    if cur and dpeer + OWNER_HYSTERESIS < dme then return false end
    if not cur and dme + OWNER_HYSTERESIS < dpeer then return true end
    return cur
end

-- Every spawned enemy (ours, or reported by the guest) goes to whoever is nearer.
local function arbitrate(t_now)
    if t_now < foes.next_arbitrate then return end
    foes.next_arbitrate = t_now + 0.5
    local ppos, p = peer_position()
    local my = me.go:call("get_Transform"):call("get_Position")
    local together = p ~= nil and p.chapter == me.chapter and ppos ~= nil
    local changes = {}
    local seen = {}
    local function decide(id, pos, dead, kind, here)
        seen[id] = true
        local cur = foes.owner[id]
        local pr = foes.presence[id]
        local there = pr ~= nil and t_now - pr.t < 1.5
        local want = owner_decision(cur, together, dead, together and (pos - my):length() or 0, together and (pos - ppos):length() or 0,
            foes.bosses[kind] == true, here, there, me.down == true or me.dead == true,
            p ~= nil and (p.flags or 0) & (FLAG_DOWN | 1024) ~= 0)
        if want ~= cur then
            set_owner(id, want)
            changes[#changes + 1] = { id, not want } -- sent from the guest's point of view
        end
    end
    for id, e in pairs(foes.index) do
        if e.ctx:call("get_IsSpawn") then
            local go = e.ctx:call("get_GameObject")
            if go then decide(id, go:call("get_Transform"):call("get_Position"), e.ctx:call("get_IsDead"), e.kind, true) end
        end
    end
    for id, pr in pairs(foes.presence) do
        if not seen[id] and t_now - pr.t < 1.5 then decide(id, pr.pos, pr.dead, foes.index[id] and foes.index[id].kind, false) end
    end
    -- a full list now and then, in case something was missed
    if t_now >= foes.next_full_owners then
        foes.next_full_owners = t_now + 5
        changes = {}
        for id, mine in pairs(foes.owner) do changes[#changes + 1] = { id, not mine } end
    end
    send_owners(changes)
end

-- receiving --------------------------------------------------------------------------------------

local function read_enemy(data)
    local s = {}
    local _, x, y, z, qx, qy, qz, qw, pos
    _, s.seq, s.t, s.chapter, s.id, s.kind, s.flags, x, y, z, qx, qy, qz, qw, s.hp, pos = string.unpack(ENEMY_HEAD, data)
    s.pos, s.rot = Vector3f.new(x, y, z), unpack_quat(qx, qy, qz, qw)
    if s.flags & F_POSE ~= 0 then
        local n
        x, y, z, n, pos = string.unpack("<fffB", data, pos)
        s.hip, s.j = Vector3f.new(x, y, z), {}
        for i = 1, n do
            qx, qy, qz, qw, pos = string.unpack("<hhhh", data, pos)
            s.j[i] = unpack_quat(qx, qy, qz, qw)
        end
    end
    return s
end

enemy_recv = function(from, data, t_now)
    if not foes.active or from ~= foes.peer_id then return end
    local ok, s = pcall(read_enemy, data)
    if not ok then return end
    if foes.test then
        if s.id ~= foes.test.src then return end
        s.id = foes.test.dst
    elseif foes.owner[s.id] == true then
        return -- ours (a handover is in flight); the arbiter's word stands
    end
    if foes.owner[s.id] == nil then foes.owner[s.id] = false end
    local st = foes.states[s.id]
    if st == nil then
        st = { snaps = {}, last = 0 }
        foes.states[s.id] = st
    end
    st.last, st.kind, st.flags, st.hp, st.chapter = t_now, s.kind, s.flags, s.hp, s.chapter
    local snaps = st.snaps
    if #snaps > 0 and s.t <= snaps[#snaps].t then return end
    snaps[#snaps + 1] = s
    while #snaps > 8 do table.remove(snaps, 1) end
end

enemy_ctrl = function(from, kind, data)
    if not foes.active or from ~= foes.peer_id then return end
    if kind == MSG_ENEMY_SKEL then
        local _, k, n, pos = string.unpack("<Bs1B", data)
        local names = {}
        for i = 1, n do names[i], pos = string.unpack("<s1", data, pos) end
        foes.names[k] = names
        for _, pup in pairs(foes.puppets) do
            if pup.kind == k then pup.jmap = nil end
        end
    elseif kind == MSG_REQ_ENEMY_SKEL then
        local _, k = string.unpack("<Bs1", data)
        for _, j in pairs(foes.joints) do
            if j.kind == k then return send_skeleton(k, j.names, from) end
        end
        foes.skel_sent[k] = nil -- sent with the next pose of that kind
    elseif kind == MSG_ENEMY_DAMAGE then
        local _, id, which, dmg, b1, b2 = string.unpack("<Bs1Bi4BB", data)
        if foes.test and id == foes.test.dst then id = foes.test.src end
        local e = foes.index[id]
        if e and foes.owner[id] ~= false and e.ctx:call("get_IsSpawn") then
            apply_damage(e, which, dmg, b1 == 1, b2 == 1)
            foes.stats.dmg_applied = foes.stats.dmg_applied + 1
            if me.on_partner_hit then pcall(me.on_partner_hit, e) end
        end
    elseif kind == MSG_ENEMY_OWNERS then
        if foes.arbiter or foes.test then return end
        local _, n, pos = string.unpack("<BH", data)
        for _ = 1, n do
            local id, guest
            id, guest, pos = string.unpack("<s1B", data, pos)
            set_owner(id, guest == 1)
        end
    elseif kind == MSG_ENEMY_PRESENCE then
        if not foes.arbiter then return end
        local _, chapter, n, pos = string.unpack("<Bs1B", data)
        if chapter ~= me.chapter then foes.presence = {} return end
        local t = now()
        for _ = 1, n do
            local id, x, y, z, dead
            id, x, y, z, dead, pos = string.unpack("<s1fffB", data, pos)
            foes.presence[id] = { pos = Vector3f.new(x, y, z), dead = dead == 1, t = t }
        end
    end
end

-- Damage dealt to a puppet goes to its owner instead.
local function forward_damage(which)
    return function(args)
        if foes.bypass or not foes.active then return end
        local id = foes.hp_owner[sdk.to_int64(args[2])]
        if id == nil then return end
        if #foes.dmg_out < 64 then
            foes.dmg_out[#foes.dmg_out + 1] = string.pack("<Bs1Bi4BB", MSG_ENEMY_DAMAGE, id, which,
                int32(sdk.to_int64(args[3])), sdk.to_int64(args[4]) & 1, sdk.to_int64(args[5]) & 1)
        end
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end
sdk.hook(M_ADD_HP, forward_damage(0), nil)
sdk.hook(M_ADD_RHP, forward_damage(1), nil)

-- Our own spawn logic puts enemies away by its rules (e.g. a wave spawner every ~10 s, or us being far
-- from the spawn area). While the owner still has the enemy, refuse.
local function guard_suspend(args)
    if foes.self_call or not foes.active then return end
    local id = foes.ctl_owner[sdk.to_int64(args[2])]
    local st = id and foes.states[id]
    if st and st.flags & F_SPAWNED ~= 0 and now() - st.last < 1.0 then
        return sdk.PreHookResult.SKIP_ORIGINAL
    end
end
local T_SPAWN_BASE = sdk.find_type_definition("app.CharacterSpawnParamBase")
sdk.hook(T_SPAWN_BASE:get_method("requestSuspend()"), guard_suspend, nil)
sdk.hook(T_SPAWN_BASE:get_method("requestSuspend(app.ContextID)"), guard_suspend, nil)

local function sample(snaps, rt)
    local a, b = snaps[#snaps], snaps[#snaps]
    for i = #snaps - 1, 1, -1 do
        if snaps[i].t <= rt then a, b = snaps[i], snaps[i + 1] break end
        a, b = snaps[i], snaps[i]
    end
    local f = 0
    if b.t > a.t then f = math.max(0, math.min(1, (rt - a.t) / (b.t - a.t))) end
    return a, b, f
end

local function peer_render_time(t_now)
    local p = foes.peer_id and peers[foes.peer_id]
    if p == nil or p.off == nil then return nil end
    return t_now - p.off - cfg.interp_delay
end

-- Before animation: spawn / put away / puppetize / keep awake / warp the enemies they own.
local function enemies_tick(t_now)
    refresh_index(t_now)
    local cm = character_manager()
    local rt = peer_render_time(t_now)
    for id, st in pairs(foes.states) do
        local e = foes.index[id]
        local fresh = t_now - st.last < 1.0 and st.chapter == me.chapter
        -- the owner's enemy died: ours dies too (its AI back, lethal damage the game's own way), so
        -- this game counts it as dead and plays the death itself. A boss keeps its own no-death on
        -- until its last phase, and our copy never got there (the hit left it standing at 1 HP, its AI
        -- back): cleared in the same frame as the hit, and again until it is down
        if e and foes.owner[id] == false and st.flags & F_DEAD ~= 0 and not st.killed and t_now >= (st.kill_t or 0) then
            st.kill_tries, st.kill_t = (st.kill_tries or 0) + 1, t_now + 0.5
            if foes.puppets[id] then release_puppet(id, true) end
            if e.ctx:call("get_IsSpawn") and not e.ctx:call("get_IsDead") then
                -- what it drops comes from the owner's game (see "enemy drops")
                if cfg.share_drops then pcall(e.ctx.set_field, e.ctx, "<IsPermitedItemDropnOnDead>k__BackingField", false) end
                local hp = e.ctx:call("get_HitPoint")
                if hp then
                    pcall(function()
                        hp:get_field("<NoDeath>k__BackingField"):call("applyRequestHashSet(System.UInt32[])", sdk.create_managed_array("System.UInt32", 0))
                    end)
                    pcall(hp.call, hp, "set_Invincible", false)
                end
                local cur = hp and hp:call("get_CurrentHitPoint") or 0
                apply_damage(e, 0, math.max(1, cur) + 100, false, true)
            end
            if st.kill_tries >= 8 or e.ctx:call("get_IsDead") or not e.ctx:call("get_IsSpawn") then st.killed = true end
        end
        if e and foes.owner[id] == false and not st.killed then
            local pup = foes.puppets[id]
            local spawned = e.ctx:call("get_IsSpawn")
            if pup and not spawned then -- put to sleep anyway: let go, it gets respawned below
                release_puppet(id, false)
                pup = nil
            end
            if fresh and st.flags & F_SPAWNED ~= 0 then
                if not spawned and t_now >= (st.next_spawn or 0) then
                    -- a never-spawned enemy needs requestSpawn, one that was put away needs requestResume
                    st.next_spawn = t_now + 1.5
                    st.tries = (st.tries or 0) + 1
                    local ctl = spawn_control(e)
                    if ctl then
                        ctl_request(ctl, st.tries % 2 == 1 and "requestSpawn" or "requestResume")
                    elseif ext.spawn_by_param then
                        ext.spawn_by_param(id, e, st)
                    end
                end
            elseif not fresh and (pup or spawned) then
                local ctl = spawn_control(e)
                if ctl then ctl_request(ctl, st.flags & F_DEAD ~= 0 and "requestKill" or "requestSuspend") end
                release_puppet(id, false)
            end
        end
        if t_now - st.last > 10 then foes.states[id] = nil end
    end
    -- what's alive here: ours keep their AI; theirs become puppets (put away if they don't send it)
    for id, e in pairs(foes.index) do
        local considered = foes.test == nil or id == foes.test.dst
        if considered and e.ctx:call("get_IsSpawn") then
            if foes.owner[id] == nil and foes.test == nil then foes.owner[id] = true end
            if foes.owner[id] == false and not e.ctx:call("get_IsDead") then
                local st = foes.states[id]
                if foes.puppets[id] == nil then
                    puppetize(id, e, st ~= nil and t_now - st.last < 1.0 and st.flags & F_SPAWNED ~= 0)
                end
                if st == nil or t_now - st.last > 3 then
                    e.orphan_since = e.orphan_since or t_now
                    if t_now - e.orphan_since > 3 then
                        local ctl = spawn_control(e)
                        if ctl then ctl_request(ctl, "requestSuspend") end
                        release_puppet(id, false)
                        e.orphan_since = t_now + 3
                    end
                else
                    e.orphan_since = nil
                end
            end
        end
    end
    local count = 0
    for id, pup in pairs(foes.puppets) do
        count = count + 1
        local st = foes.states[id]
        local has = st ~= nil and #st.snaps > 0 and t_now - st.last < 1.0
        local go = pup.go
        if not go:call("get_UpdateSelf") then go:call("set_UpdateSelf", true) end
        if go:call("get_DrawSelf") ~= has then go:call("set_DrawSelf", has) end
        if has and cm then
            local a, b, f = sample(st.snaps, rt or st.snaps[#st.snaps].t)
            local pos = a.pos + (b.pos - a.pos) * f
            if foes.test and foes.test.offset then pos = pos + foes.test.offset end
            pcall(cm.call, cm, WARP_SIG, pup.e.ctx:call("get_ID"), nullable_vec3(pos), nullable_quat(a.rot:slerp(b.rot, f)))
        end
    end
    foes.stats.puppets = count
end

local function build_jmap(pup)
    local names = foes.names[pup.kind]
    if names == nil then
        local t = now()
        if t - (foes.asked[pup.kind] or 0) > 2 then
            foes.asked[pup.kind] = t
            send_ctrl(string.pack("<Bs1", MSG_REQ_ENEMY_SKEL, pup.kind), foes.peer_id)
        end
        return
    end
    local by = {}
    local js = pup.go:call("get_Transform"):call("get_Joints")
    for _, j in ipairs(elements(js) or {}) do by[j:call("get_Name")] = j end
    pup.jmap = {}
    for i, n in ipairs(names) do pup.jmap[i] = by[n] or false end
    pup.j_hip = by["Hip"]
end

-- After animation: the owner's skeleton over the puppet's own (stepped at the owner's send rate).
local function puppets_pose(t_now)
    local rt = peer_render_time(t_now)
    for id, pup in pairs(foes.puppets) do
        local st = foes.states[id]
        if st and #st.snaps > 0 and t_now - st.last < 1.0 then
            local a, b, f = sample(st.snaps, rt or st.snaps[#st.snaps].t)
            local s = (f >= 0.5 and b.j) and b or (a.j and a or b)
            if s.j then
                if pup.jmap == nil then build_jmap(pup) end
                if pup.jmap then
                    for i, j in ipairs(pup.jmap) do
                        if j and s.j[i] then j:call("set_LocalRotation", s.j[i]) end
                    end
                    if pup.j_hip and s.hip then pup.j_hip:call("set_LocalPosition", s.hip) end
                end
            end
        end
    end
end

local function enemies_session(st_net)
    local active, arbiter, peer_id = false, false, nil
    if cfg.enemy_sync and st_net and st_net.state == "in_lobby" and session.last_members ~= "" then
        for _, m in ipairs(st_net.members or {}) do
            if m.id ~= st_net.me then peer_id = m.id break end
        end
        active, arbiter = peer_id ~= nil, st_net.is_host
    elseif foes.test and loopback then
        active, arbiter, peer_id = true, false, LOOPBACK_ID
    end
    if active ~= foes.active or peer_id ~= foes.peer_id then
        if foes.active then enemies_reset(me.go ~= nil) end
        foes.active, foes.peer_id = active, peer_id
        say("shared enemies: %s", active and (foes.test and "test" or (arbiter and "on (you decide who runs each enemy)" or "on")) or "off")
    end
    foes.arbiter = arbiter
    if foes.test then
        foes.owner[foes.test.src], foes.owner[foes.test.dst] = true, false
    end
end

-- called before animation
local function enemies_update(t_now)
    enemies_session(session.status)
    if foes.active and me.go then enemies_tick(t_now) end
end

-- called after animation
local function enemies_late(t_now)
    if not foes.active or me.go == nil then return end
    local p = peers[foes.peer_id]
    local together = foes.test ~= nil or (p ~= nil and p.chapter == me.chapter)
    if foes.arbiter and not foes.test then arbitrate(t_now) end
    if together then
        send_owned(t_now)
        if not foes.arbiter and not foes.test then send_presence(t_now) end
    end
    puppets_pose(t_now)
    if #foes.dmg_out > 0 then
        local out = foes.dmg_out
        foes.dmg_out = {}
        for _, blob in ipairs(out) do send_ctrl(blob, foes.peer_id) end
        foes.stats.dmg_sent = foes.stats.dmg_sent + #out
    end
end


-------------------------------------------------------------------------------------------------
-- shared doors and pickups
-------------------------------------------------------------------------------------------------
-- Doors (app.GmDoorV3): what is shared is the door's angle (_CurrAngle), not what moved it. A door
-- moves with the player's own body: walked into, it's pushed by contact every frame (hundreds of
-- GmDoorV3.addForce calls); opened with the interact key, it follows the player's hand
-- (IGimmickDoor.requestInteractOpen puts it under external control, the player's motion turns it).
-- Replaying a push on the partner's copy hardly moved it (0.2 degrees) and an interact open not at all,
-- so the partner walked through a closed door. Now the game whose player moves a door sends its angle
-- 15 times a second while it moves and once more when it stops; the partner's game turns its copy to
-- that angle (written into _CurrAngle and _TargetAngle every frame, at most 360 degrees a second: the
-- door's own update turns its hinge joint from them) and holds it while the stream goes on, and a
-- door left open there stays open here (its own auto-close would shut it through the partner). A door our
-- own player is pushing just now is ours: the partner's angle waits. Pickups: when an item (app.ItemCore) is picked up here, the partner's copy of it is
-- despawned through its ItemContext (set_IsSpawn(false)), the way the game removes taken items.
-- Doors and items are matched by their scene GUIDs (GimmickCore / ItemCore context IDs). Items made
-- at runtime (enemy drops) have per-PC IDs and aren't shared. Key-locked doors aren't unlocked for
-- the partner yet.
local world, world_shared, world_late
do
local DOOR_AUTO_CLOSE = 1
-- GmDoorV3.ActionType: only pushes are shared (Normal 0, UniformSpeed 2); Lock 3 is a locked door's
-- rattle (a door still locked in the partner's game made ours rattle shut and not let us through),
-- Const / MotionSync belong to the pusher's own animation
local DOOR_SHARED = { [0] = true, [2] = true }
local T_DOOR_REQUEST = "app.GmDoorV3.RequestInfo"
local M_DOOR_FORCE = sdk.find_type_definition("app.GmDoorV3"):get_method("addForce(app.GmDoorV3.RequestInfo)")
local M_ITEM_PICKED = sdk.find_type_definition("app.ItemCore"):get_method("notifyPickupped(System.Boolean)")
local TYPE_DOOR = sdk.typeof("app.GmDoorV3")
local TYPE_ITEM = sdk.typeof("app.ItemCore")
local TYPE_GIMMICK_CORE = sdk.typeof("app.GimmickCore")
local T_SCENE_MANAGER = sdk.find_type_definition("via.SceneManager")

world = {
    doors = {}, door_ids = {},  -- id -> GmDoorV3, GmDoorV3 address -> id
    items = {}, item_ids = {},  -- id -> ItemCore, ItemCore address -> id
    index_t = 0, index_chapter = "",
    applying = false,           -- true while we push a door / remove an item for the partner
    applied_at = {},            -- door id -> when we last pushed it for the partner (echo guard)
    sent_at = {},               -- door id -> when we last sent a push (rate limit)
    out = {},
    taken = {},                 -- item id -> true: what we picked up in this scene (shared kinds)
    stats = { doors_sent = 0, doors_applied = 0, items_sent = 0, items_applied = 0 },
}

world_reset = function()
    world.doors, world.door_ids, world.items, world.item_ids, world.taken = {}, {}, {}, {}, {}
    world.index_t, world.applied_at, world.sent_at, world.out = 0, {}, {}, {}
end

local function scene_components(type_obj)
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sm and sdk.call_native_func(sm, T_SCENE_MANAGER, "get_CurrentScene")
    local arr = scene and scene:call("findComponents(System.Type)", type_obj)
    -- now and then the call hands back something that isn't an array
    local ok, list = pcall(function() return arr and arr:get_elements() end)
    return ok and list or {}
end

local function id_string(holder)
    local ok, id = pcall(function() return holder:call("get_ContextID"):call("ToString") end)
    return ok and id or nil
end

local function refresh_world(t_now)
    if t_now < world.index_t and world.index_chapter == me.chapter then return end
    world.index_t, world.index_chapter = t_now + 5, me.chapter
    local doors, door_ids, items, item_ids = {}, {}, {}, {}
    for _, d in ipairs(scene_components(TYPE_DOOR)) do
        local core = d:call("get_GameObject"):call("getComponent(System.Type)", TYPE_GIMMICK_CORE)
        local id = core and id_string(core)
        if id then doors[id], door_ids[d:get_address()] = d, id end
    end
    for _, it in ipairs(scene_components(TYPE_ITEM)) do
        local id = id_string(it)
        if id then items[id], item_ids[it:get_address()] = it, id end
    end
    world.doors, world.door_ids, world.items, world.item_ids = doors, door_ids, items, item_ids
end

world.scene_components = scene_components
world.refresh = function(t) return refresh_world(t) end

-- An enemy the owner has up that has no spawn control here yet (a boss before its entrance: C100
-- comes in at its arena through one of its spawn params): through the spawn param of its kind that
-- manages it, the one nearest to where the owner has it.
ext.spawn_by_param = function(id, e, st)
    local kind = e.kind or ""
    local td = kind:sub(1, 3) == "cp_" and sdk.find_type_definition("app.Cp_" .. kind:sub(4) .. "SpawnParam")
    if not td then return end
    local s = st.snaps and st.snaps[#st.snaps]
    -- the params of a kind, looked up once per 3 s (several of its enemies may be waiting)
    ext.param_cache = ext.param_cache or {}
    local c = ext.param_cache[kind]
    local t = now()
    if c == nil or t > c.t or c.chapter ~= me.chapter then -- never objects of a chapter left behind
        c = { t = t + 3, chapter = me.chapter, list = scene_components(td:get_runtime_type()) }
        ext.param_cache[kind] = c
    end
    local best, best_d
    for _, prm in ipairs(c.list) do
        local ok, mid = pcall(function() return prm:call("get_ManagedContextID"):call("ToString") end)
        if ok and mid == id then
            local d = 0
            if s and s.pos then
                local okp, pp = pcall(function() return prm:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
                d = okp and (pp - s.pos):length() or 1e9
            end
            if best == nil or d < best_d then best, best_d = prm, d end
        end
    end
    if best then
        pcall(best.call, best, "permitSpawn(System.Boolean)", true)
        if pcall(best.call, best, "requestSpawn") then foes.stats.param_spawns = (foes.stats.param_spawns or 0) + 1 end
    end
end

world_shared = function()
    if me.go == nil or not cfg.world_sync then return false end
    if _G.re9coop_test_shared then return true end -- dev bridge only
    if loopback then return true end
    if ext.fresh_hold and ext.fresh_hold() then return false end -- a guest on their own save
    local st_net = session.status
    return st_net ~= nil and st_net.state == "in_lobby" and session.last_members ~= ""
end

-- our own player moving a door: it's ours for a moment (the partner's angle for it waits). Walked
-- into: pushes of ActionType Normal; opened with the interact key: requestInteractOpen with our
-- player next to it. Not UniformSpeed pushes: a closing door pushes itself with those every frame
-- (force 3000, direction -1), and counted as ours they threw away every angle the partner sent.
sdk.hook(M_DOOR_FORCE, function(args)
    if world.applying or not world_shared() then return end
    local id = world.door_ids[sdk.to_int64(args[2])]
    if id == nil then return end
    local info = sdk.to_managed_object(args[3])
    if info == nil or (info:get_field("ActionType") or 0) ~= 0 then return end
    world.mine_at = world.mine_at or {}
    world.mine_at[id] = now()
end, nil)
for _, m in ipairs(sdk.find_type_definition("app.GmDoorV3"):get_methods()) do
    if m:get_name():find("requestInteractOpen", 1, true) then
        sdk.hook(m, function(args)
            if world.applying or me.go == nil then return end
            local id = world.door_ids[sdk.to_int64(args[2])]
            local d = id and world.doors[id]
            if d == nil then return end
            local dp = d:call("get_GameObject"):call("get_Transform"):call("get_Position")
            if (dp - me.go:call("get_Transform"):call("get_Position")):length() < 2.5 then
                world.mine_at = world.mine_at or {}
                world.mine_at[id] = now() + 1.5 -- the hand's turn takes a while
            end
        end, nil)
    end
end

-- the angles of the doors moving here, and the partner's we turn our copies to
world.angle = { last = {}, moving = {}, sent_at = {}, drive = {}, next = 0, late_t = nil }
local DOOR_SEND_HZ, DOOR_DEG_PER_S = 15, 360
world.angle_scan = function(t_now)
    local A = world.angle
    if t_now < A.next then return end
    A.next = t_now + 1 / DOOR_SEND_HZ
    for id, d in pairs(world.doors) do
        local ok, a = pcall(d.get_field, d, "_CurrAngle")
        if ok and type(a) == "number" then
            local la = A.last[id]
            A.last[id] = a
            if A.drive[id] == nil and t_now - (A.driven_at and A.driven_at[id] or -10) > 0.5 and #world.out < 48 then
                if la and math.abs(a - la) > 0.3 then
                    A.moving[id] = t_now
                    world.out[#world.out + 1] = string.pack("<Bs1s1fB", MSG.DOOR_ANGLE, me.chapter, id, a, 0)
                elseif A.moving[id] and t_now - A.moving[id] > 0.3 then
                    A.moving[id] = nil
                    world.out[#world.out + 1] = string.pack("<Bs1s1fB", MSG.DOOR_ANGLE, me.chapter, id, a, 1)
                end
            end
        end
    end
end

world.angle_ctrl = function(data)
    local _, chapter, id, a, final = string.unpack("<Bs1s1fB", data)
    if chapter ~= me.chapter or world.doors[id] == nil then return end
    if now() - ((world.mine_at or {})[id] or -10) < 1.0 then return end -- ours just now
    world.angle.drive[id] = { target = a, t = now(), final = final == 1 }
    world.stats.doors_applied = world.stats.doors_applied + 1
end

-- every frame: our copies of the doors the partner moves, turned toward the partner's angle
re.on_application_entry("LateUpdateBehavior", function()
    local A = world.angle
    local t = now()
    local dt = math.min(0.1, t - (A.late_t or t))
    A.late_t = t
    if next(A.drive) == nil then return end
    A.driven_at = A.driven_at or {}
    for id, dv in pairs(A.drive) do
        local d = world.doors[id]
        local ok, cur = pcall(function() return d and d:get_field("_CurrAngle") end)
        -- let go: our own player moves it, the stream stopped mid-move (3 s), or a door left open there
        -- for 30 s (a door held open there by the partner standing in it stays open here meanwhile)
        local quiet = t - dv.t
        if not ok or type(cur) ~= "number" or quiet > (dv.final and 30 or 3) or t - ((world.mine_at or {})[id] or -10) < 1.0 then
            A.drive[id] = nil
        else
            local step = DOOR_DEG_PER_S * math.max(dt, 1 / 120)
            local new = cur + math.max(-step, math.min(step, dv.target - cur))
            pcall(d.set_field, d, "_CurrAngle", new)
            pcall(d.set_field, d, "_TargetAngle", new)
            A.driven_at[id] = t
            A.last[id] = new
            if dv.final and math.abs(dv.target) < 1 and math.abs(new - dv.target) < 0.5 and quiet > 0.5 then A.drive[id] = nil end
        end
    end
end)

-- Items each player gets their own copy of: picking one up here leaves the partner's copy for them
-- (weapons, key items, files, maps, upgrades...). Ammo, healing and crafting materials are shared:
-- whoever takes them first (unless "each player picks up their own" is on).
local PERSONAL = { Weapon = true, SubWeapon = true, Armor = true, Attachment = true, Charm = true, KeyItem = true,
    Map = true, Procedure = true, Storage = true, Flag = true, Other = true }
local item_cats = {}

local function item_category(core)
    local ok, id = pcall(core.call, core, "get_ItemID")
    local name = ok and id and id:get_field("_Name")
    if not name then return nil end
    local cat = item_cats[name]
    if cat == nil then
        local m = sdk.get_managed_singleton("app.ItemManager")
        local catalog = m and m:get_field("_ItemCatalog")
        local okd, d = pcall(function() return catalog:call("getValue(app.ItemID, app.ItemDetailData)", id, nil) end)
        local okc, c = pcall(function() return d:get_field("_ItemCategory"):call("ToString") end)
        cat = (okd and okc and c) or false
        item_cats[name] = cat
    end
    return cat or nil
end
world.item_category = item_category

sdk.hook(M_ITEM_PICKED, function(args)
    if world.applying or not world_shared() or (sdk.to_int64(args[3]) & 1) == 0 then return end
    if cfg.pickups_for_both then return end
    local core = sdk.to_managed_object(args[2])
    if core and PERSONAL[item_category(core) or ""] then return end
    local id = world.item_ids[sdk.to_int64(args[2])]
    if id and #world.out < 32 then
        world.out[#world.out + 1] = string.pack("<Bs1s1", MSG_ITEM_TAKEN, me.chapter, id)
        world.taken[id] = true
    end
end, nil)

world_ctrl = function(from, kind, data)
    if not world_shared() then return end
    refresh_world(now())
    if kind == MSG.DOOR_ANGLE then
        world.angle_ctrl(data)
    elseif kind == MSG.GIM_JOINT then
        if ext.joint_ctrl then ext.joint_ctrl(data) end
    elseif kind == MSG_DOOR then
        local _, chapter, id, action, force, dir = string.unpack("<Bs1s1BfI4", data)
        local door = chapter == me.chapter and world.doors[id]
        if not door or not DOOR_SHARED[action] then return end
        -- a door we're pushing ourselves just now: ours (two pushes fighting held it half open)
        if now() - ((world.mine_at or {})[id] or -10) < 1.5 then return end
        local info = sdk.create_instance(T_DOOR_REQUEST)
        if info == nil then return end
        info:set_field("ActionType", action)
        info:set_field("Force", force)
        info:set_field("ForceDir", int32(dir))
        world.applying = true
        pcall(door.call, door, "addForce(app.GmDoorV3.RequestInfo)", info)
        world.applying = false
        world.applied_at[id] = now()
        world.stats.doors_applied = world.stats.doors_applied + 1
    elseif kind == MSG_ITEM_TAKEN then
        local _, chapter, id = string.unpack("<Bs1s1", data)
        local item = chapter == me.chapter and world.items[id]
        if not item then return end
        local ctx = item:get_field("_Context")
        if ctx and ctx:call("get_IsSpawn") then
            world.applying = true
            pcall(ctx.call, ctx, "set_IsSpawn", false)
            world.applying = false
            world.stats.items_applied = world.stats.items_applied + 1
        end
    end
end

world_late = function(t_now)
    if not world_shared() then return end
    refresh_world(t_now)
    world.angle_scan(t_now)
    if ext.joint_scan then pcall(ext.joint_scan, t_now) end
    if #world.out == 0 then return end
    local out = world.out
    world.out = {}
    for _, blob in ipairs(out) do
        local kind = string.byte(blob, 1)
        send_ctrl(blob)
        if kind == MSG_DOOR or kind == MSG.DOOR_ANGLE then
            world.stats.doors_sent = world.stats.doors_sent + 1
        else
            world.stats.items_sent = world.stats.items_sent + 1
        end
    end
end
end


-- Teleport our player 1 m behind the partner (same chapter only), like walking up to them.
local function partner_to_follow()
    for id, p in pairs(peers) do
        if id ~= LOOPBACK_ID and #p.snaps > 0 then return p end
    end
    local echo = peers[LOOPBACK_ID]
    return echo and #echo.snaps > 0 and echo or nil
end

local function teleport_to_partner()
    local p = partner_to_follow()
    if p == nil or me.pc == nil then return "no partner to go to" end
    if p.chapter ~= me.chapter then return "your partner is in " .. p.chapter end
    local s = p.snaps[#p.snaps]
    -- not to a partner whose game isn't sending a live player standing somewhere (dead, a game over,
    -- loading, off the ground): a host that came to next to a guest on their game-over screen fell
    -- through the map to where that guest's last pose was, and the guest then loaded the host's world
    -- down there too
    if now() - (p.last or 0) > 1.5 or (p.flags or 0) & 512 ~= 0 then -- 512: off the ground
        return "your partner isn't standing anywhere right now"
    end
    local pos = s.pos + s.rot * Vector3f.new(0, 0, -1.0)
    local cm = character_manager()
    local ok = pcall(cm.call, cm, WARP_SIG, me.pc:call("get_ID"), nullable_vec3(pos), nullable_quat(s.rot))
    return ok and ("went to " .. p.name) or "couldn't move you"
end
-------------------------------------------------------------------------------------------------
-- out of the world
-------------------------------------------------------------------------------------------------
-- The spots our player stood on (its CharacterController touching something, and not moving down
-- fast: get_Ground and get_NumGroundContactPoints stay false / 0 here even standing, while
-- get_NumContactPrimitives is 1 standing and 0 falling), per chapter and kept across loads and game
-- overs (the player object changes, the chapter doesn't). Off the ground 40 m below where the fall
-- began, outside a cutscene, we're out of the world: back to a spot from 3 s before it (a spot just
-- before can be the ledge it began on: a guest warped past a wall went back there four times), or,
-- with none, next to a partner who stands somewhere. Off the ground at all, the partner is told (flag 512), so nobody's game
-- sends them to us then.
;(function()
local T_CC = sdk.typeof("via.physics.CharacterController")
local OUT_OF_WORLD = 40
local ground = { by_chapter = {}, t = 0, cc = nil, cc_go = 0, back_t = 0, since = nil, fall_from = nil, backs = {} }
ext.ground = ground
local SPOTS, STEADY, OLDER = 12, 1.0, 3.0

-- standing spots of this chapter, newest last (one every 0.5 s while standing steadily for 1 s:
-- a touch of a ledge on the way down isn't one)
local function remember(t_now, p)
    local list = ground.by_chapter[me.chapter]
    if list == nil then list = {} ground.by_chapter[me.chapter] = list end
    local last = list[#list]
    if last and t_now - last.t < 0.5 then return end
    list[#list + 1] = { t = t_now, pos = Vector3f.new(p.x, p.y, p.z) }
    if #list > SPOTS then table.remove(list, 1) end
end

-- the spot to go back to: one from before the fall began, 3 s earlier than it at least (the oldest
-- kept if none is); a second fall out of the world within 20 s goes back further
local function spot_before(t_from)
    local list = ground.by_chapter[me.chapter]
    if list == nil or #list == 0 then return nil end
    local recent = 0
    for _, t in ipairs(ground.backs) do if t_from - t < 20 then recent = recent + 1 end end
    local cut = t_from - OLDER * (1 + recent * 3)
    for i = #list, 1, -1 do
        if list[i].t <= cut then return list[i].pos end
    end
    return list[1].pos
end

ext.ground_tick = function(t_now)
    if me.go == nil or t_now < ground.t then return end
    ground.t = t_now + 0.25
    if in_cutscene() then
        me.falling, ground.since = false, nil
        return
    end
    if ground.cc_go ~= me.go_addr then
        ground.cc, ground.cc_go = me.go:call("getComponent(System.Type)", T_CC), me.go_addr
        ground.since, ground.fall_from = nil, nil
    end
    local p = me.go:call("get_Transform"):call("get_Position")
    local okg, contacts = pcall(ground.cc.call, ground.cc, "get_NumContactPrimitives")
    local vy = ground.last_y and ground.last_t and (p.y - ground.last_y) / math.max(0.05, t_now - ground.last_t) or 0
    ground.last_y, ground.last_t = p.y, t_now
    if okg and contacts and contacts > 0 and vy > -3 then
        ground.since = ground.since or t_now
        ground.fall_from = nil
        me.falling = false
        if t_now - ground.since >= STEADY then remember(t_now, p) end
        return
    end
    ground.since = nil
    ground.fall_from = ground.fall_from or { t = t_now, y = p.y }
    me.falling = true
    if t_now < ground.back_t then return end
    local target
    local list = ground.by_chapter[me.chapter]
    local ref = list and list[#list] and list[#list].pos
    if ref and p.y < math.min(ref.y, ground.fall_from.y) - OUT_OF_WORLD then
        target = spot_before(ground.fall_from.t)
    elseif ref == nil and p.y < -OUT_OF_WORLD - 60 then
        local pt = partner_to_follow()
        local s = pt and pt.snaps[#pt.snaps]
        if s and pt.chapter == me.chapter and t_now - (pt.last or 0) < 1.5 and (pt.flags or 0) & 512 == 0 then -- on the ground
            target = s.pos
        end
    end
    if target == nil then return end
    ground.back_t = t_now + 3
    ground.backs[#ground.backs + 1] = t_now
    if #ground.backs > 4 then table.remove(ground.backs, 1) end
    local to = Vector3f.new(target.x, target.y + 0.3, target.z)
    ext.later(function()
        local cm = character_manager()
        -- (a warp needs both: with no rotation given it doesn't move the player)
        local rot = me.go and me.go:call("get_Transform"):call("get_Rotation")
        if cm and me.pc and rot then pcall(cm.call, cm, WARP_SIG, me.pc:call("get_ID"), nullable_vec3(to), nullable_quat(rot)) end
    end)
    say("you fell out of the world: back where you stood")
end
end)()


-------------------------------------------------------------------------------------------------
-- shared gimmick states: locks, puzzles, switches, used keys, solved locks...
-------------------------------------------------------------------------------------------------
-- Every gimmick (app.GimmickContext, ~700 per chapter) keeps its state in typed StructureData
-- objects; app.structure.GmBaseData has the common progress fields (_IsLock, _IsDone,
-- _IsInteracted, _IsOperable, _ProgressIndex...). We scan the contexts a slice per frame and
-- fingerprint their logical fields (bools and integers; positions, rates and map-icon data are left
-- out). A change is sent to the partner, whose game writes the fields straight into that context's
-- live StructureData objects (the very objects the running gimmick reads: a switch moves to the new
-- position, a lock's data opens). store()/restore() would swap in copies the running gimmick never
-- sees. A gimmick that isn't loaded there picks the state up when its area loads. Doors are left to
-- the door pushes above.
-- Locks opened, keys and items used: the interact triggers a lock (GmLockV2) unlocks on (its
-- _UnlockParams: "UseKeyItem_Success", or "TurnOff" sent at the end of the key scene...) and the
-- KeyItemInventory success triggers ("UseKeyItem_Success...", "UseKeyItem_Use...") are fired on the
-- partner's copy of that gimmick too (InteractTrigger.onProcessEvent): the gimmick runs its own
-- reaction (the lock opens, the slot takes the item) with no player action there. Player input
-- triggers ("Interact"...) are never replayed.
-- Puzzles that hand out their result in the solver's own scene (a safe or a container opened, with the
-- items inside): when the partner's data says one got done, ours is finished the game's way too
-- (GmSafe / GmContainer.forceOpen: it opens and drops its own copy of the items). Collectibles
-- (GmFragileSymbol: breakable symbols counted for achievements) are each player's own: not shared.
-- All of this is applied inside the game's GUI update (see the item box section). On joining, the
-- lobby owner sends every gimmick's state once. The gimmick global bit flags are OR-ed.
local gim, gimmicks_late
do
local GIMMICK_SKIP_TYPES = {
    ["app.structure.PostureData"] = true,
    ["app.structure.StaySectionData"] = true,
    ["app.structure.GmMapIconStatusV2"] = true,
}
local GIMMICK_PER_FRAME = 60
local T_BOOL, T_INT = 1, 2
local PERSONAL_DATA = "app.structure.GmFragileSymbolData" -- collectibles: each player breaks their own
local T_BASE_DATA = "app.structure.GmBaseData"
local FINISHERS = { { sdk.typeof("app.GmSafe"), "forceOpen" }, { sdk.typeof("app.GmContainer"), "forceOpen" } }

gim = {
    -- settings store() leaves out of its copy (there they read 0 / false): never sent, never written.
    -- Sent, they set the partner's lock to "0 keys needed" and their switches and motions to 0 positions.
    unsaved = {
        ["app.structure.GmLockData._MaxUnlockCount"] = true,
        ["app.structure.GmMotionData._IndexCount"] = true,
        ["app.structure.GmSwitchData._IndexCount"] = true,
        ["app.structure.GmDoorData._IsDoubleDoorClose"] = true,
        -- an event's hold on a door (it follows the event's motion and can't be pushed): each game's own
        -- event sets it and lets go of it. Sent, a guest's opening event held the host's doors for good
        ["app.structure.GmDoorData._IsConstMode"] = true,
        ["app.structure.GmDoorData._IsMotionFollowMode"] = true,
        ["app.structure.GmElevatorButtonData._IsButtonInteractable"] = true,
        ["app.structure.GmSafeData._PlaceIDHash"] = true,
        ["app.structure.GmContainerData._PlaceIDHash"] = true,
        ["app.structure.GmFragileSymbolData._PlaceIDHash"] = true,
    },
    lock_data = { "app.structure.GmLockData", sdk.typeof("app.structure.GmLockData") },
    -- puzzles whose running copy reads its data only when it starts (as after a load): when the partner's
    -- data is ahead of ours, ours is started again from that data, re-reads it ("assign") or reforms itself.
    -- { component, data type, data field, runtime field (nil: once per chapter), method, lowest number };
    -- a true data field catches up a false runtime one, a number (from the lowest on) any other number
    catch_up = {
        -- coin lockers: the glass door opens and the item inside can be taken
        { sdk.typeof("app.Gm02_032"), "app.structure.Gm02_032Data", "_Unlock", "_Unlock", "onStart" },
        -- the safe with the sun quartz: its door opens
        { sdk.typeof("app.Gm99_102"), "app.structure.Gm99_102Data", "_Success", nil, "reformOpenState" },
        -- the pencil rubbing: the notebook opens shaded, with the note
        { sdk.typeof("app.Gm99_108"), "app.structure.Gm99_108Data", "_Success", "_Success", "assign" },
        -- the sun / moon / star door: the emblems put in show in its window
        { sdk.typeof("app.Gm02_016"), "app.structure.Gm02_016Data", "_SetType", "_SetType", "onStart" },
        -- the talking pilot in the hospital: dead (Dead 5, DeadCrash 6) once shot dead there
        { sdk.typeof("app.Gm99_099"), "app.structure.Gm99_099Data", "_State", "_State", "onStart", 5 },
    },
    caught = {},          -- context id -> caught up already (catch_up entries with no runtime field)
    fields = {},          -- structure type name -> { {name, tag}, ... } (logical fields only)
    sig = {},             -- context id -> last known fingerprint
    sent_at = {},         -- context id -> last send time (rate limit)
    applied_at = {},      -- context id -> when we applied the partner's state (our game's rewrite isn't news)
    hold = {},            -- context id -> until when the partner's data for it waits (a lock taking an unlock)
    cursor = 1, contexts = nil, contexts_t = 0, chapter = "",
    full_pending = nil,   -- list of context ids still to send in the initial full sync (lobby owner)
    full_done_for = nil,  -- peer id we did the full sync for
    flags_sent = { -1, -1 },
    out = {},
    applying = false,
    queue = {},           -- the partner's messages, applied in the GUI update
    triggers = { by_addr = {}, by_key = {}, t = 0, chapter = "", forced = 0 },
    trigger_applying = false,
    trig_sent = {},       -- "context id|trigger" -> when we sent it
    stats = { sent = 0, applied = 0, live_sent = 0, live_applied = 0 },
}

local function gimmick_manager()
    return sdk.get_managed_singleton("app.GimmickManager")
end

local function logical_fields(obj)
    local td = obj:get_type_definition()
    local tname = td:get_full_name()
    local f = gim.fields[tname]
    if f then return tname, f end
    f = {}
    if not GIMMICK_SKIP_TYPES[tname] and not tname:find("MapIcon", 1, true) then
        local t = td
        while t and t:get_full_name() ~= "app.StructureData" and t:get_full_name() ~= "System.Object" do
            for _, fl in ipairs(t:get_fields()) do
                if not fl:is_static() and not gim.unsaved[tname .. "." .. fl:get_name()] then
                    local ft = fl:get_type()
                    local fname = ft:get_full_name()
                    if fname == "System.Boolean" then
                        f[#f + 1] = { fl:get_name(), T_BOOL }
                    elseif fname == "System.Int32" or fname == "System.UInt32" or fname == "System.Int16"
                        or fname == "System.UInt16" or fname == "System.Byte" or fname == "System.SByte"
                        or (ft:is_enum()) then
                        f[#f + 1] = { fl:get_name(), T_INT }
                    end
                end
            end
            t = t:get_parent_type()
        end
    end
    gim.fields[tname] = f
    return tname, f
end

-- { {type, field, tag, value}, ... } of a context's live state, and its fingerprint
local function gimmick_state(gc)
    local save = gc:call("store")
    local arr = save and save:get_field("_StructureDatas")
    local entries, parts = {}, {}
    local list = elements(arr)
    if list == nil then error("unreadable") end -- skipped this time, not taken for a change
    for _, x in ipairs(list) do
        local tname, fields = logical_fields(x)
        -- an open coin locker adds to its lock's count every frame: counted up to what the lock needs,
        -- or it would be sent twice a second for good
        local cap
        if tname == gim.lock_data[1] then
            local okc, live = pcall(function() return gc:call("get_SDC"):call("getStructureData(System.Type)", gim.lock_data[2]) end)
            cap = okc and live and live:get_field("_MaxUnlockCount")
        end
        for _, fd in ipairs(fields) do
            local ok, v = pcall(x.get_field, x, fd[1])
            if ok and v ~= nil then
                local num = fd[2] == T_BOOL and (v and 1 or 0) or (type(v) == "number" and math.floor(v) or 0)
                if cap and cap > 0 and num > cap and fd[1] == "_UnlockCount" then num = cap end
                entries[#entries + 1] = { tname, fd[1], fd[2], num }
                parts[#parts + 1] = num
            end
        end
    end
    return entries, table.concat(parts, ",")
end

local function context_id(gc)
    local id = gim.ids and gim.ids[gc:get_address()]
    if id then return id end
    local ok, s = pcall(function() return gc:call("get_ContextID"):call("ToString") end)
    return ok and s or nil
end

local function gimmick_contexts(t_now)
    if gim.contexts == nil or t_now >= gim.contexts_t or gim.chapter ~= me.chapter then
        local gm = gimmick_manager()
        local arr = gm and gm:get_field("_GimmickContextCache")
        gim.contexts = elements(arr) or gim.contexts or {}
        gim.contexts_t, gim.chapter = t_now + 10, me.chapter
        gim.ids, gim.by_id = {}, {}
        for _, gc in ipairs(gim.contexts) do
            local ok, id = pcall(function() return gc:call("get_ContextID"):call("ToString") end)
            if ok and id then gim.ids[gc:get_address()], gim.by_id[id] = id, gc end
        end
        if gim.cursor > #gim.contexts then gim.cursor = 1 end
    end
    return gim.contexts
end

local function pack_gimmick(id, entries, full)
    local t = { string.pack("<Bs1s1BH", MSG_GIMMICK, me.chapter, id, full and 1 or 0, #entries) }
    for _, e in ipairs(entries) do t[#t + 1] = string.pack("<s1s1Bi8", e[1], e[2], e[3], e[4]) end
    return table.concat(t)
end

local function gimmick_scan(t_now)
    local list = gimmick_contexts(t_now)
    local n = #list
    if n == 0 then return end
    for _ = 1, math.min(GIMMICK_PER_FRAME, n) do
        if gim.cursor > n then gim.cursor = 1 end
        local gc = list[gim.cursor]
        gim.cursor = gim.cursor + 1
        local id = gc and context_id(gc)
        if id then
            local ok, entries, sig = pcall(gimmick_state, gc)
            if ok then
                local old = gim.sig[id]
                gim.sig[id] = sig
                -- a gimmick that is running here rewrites its data from its own state right after we
                -- restore the partner's; that is not a change of ours, so it isn't sent back
                local echo = t_now - (gim.applied_at[id] or -10) < 3
                local personal = false
                for _, e in ipairs(entries) do if e[1] == PERSONAL_DATA then personal = true break end end
                if old ~= nil and old ~= sig and not echo and not personal and #entries > 0 and t_now - (gim.sent_at[id] or -10) > 0.5 and #gim.out < 64 then
                    gim.sent_at[id] = t_now
                    gim.out[#gim.out + 1] = pack_gimmick(id, entries, false)
                end
            end
        end
    end
end


-- what a guest's game may not do to the host's: lock again, undo, take back keys. A guest's gimmick that
-- starts from its own (earlier) data sends that data as a change; the host's open locks and doors went
-- shut and stayed so in the host's save
local GIMMICK_NO_UNDO = { _IsLock = "up", _IsDone = "down", _IsInteracted = "down", _UnlockCount = "down" }

local function apply_gimmick(data, guest)
    local _, chapter, id, full, n, pos = string.unpack("<Bs1s1BH", data)
    if chapter ~= me.chapter then return end
    if (gim.hold[id] or 0) > now() then return "held" end
    local want = {}
    for _ = 1, n do
        local tname, fname, tag, v
        tname, fname, tag, v, pos = string.unpack("<s1s1Bi8", data, pos)
        want[tname] = want[tname] or {}
        -- not `tag == T_BOOL and (v ~= 0) or v`: for a false that gives 0, and a 0 written into a
        -- System.Boolean field reads back true (v0.5.0 to v0.12.0: every false the partner sent came out
        -- true here: locks shut again, doors held, puzzles done)
        if tag == T_BOOL then want[tname][fname] = v ~= 0 else want[tname][fname] = v end
    end
    if want[PERSONAL_DATA] then return end
    gimmick_contexts(now())
    local gc = gim.by_id[id]
    if gc == nil or (world.doors[id] and not full) then return end
    local sdc = gc:call("get_SDC")
    local list = sdc and sdc:get_field("_Structures")
    local count = list and list:call("get_Count") or 0
    local changed = false
    gim.applying = true
    -- done there, not here: a safe / container is opened the game's way first
    if want[T_BASE_DATA] and want[T_BASE_DATA]._IsDone == true then
        for i = 0, count - 1 do
            local x = list:call("get_Item", i)
            if x and x:get_type_definition():get_full_name() == T_BASE_DATA and x:get_field("_IsDone") == false then
                local body = gc:call("get_BodyGameObject")
                for _, f in ipairs(FINISHERS) do
                    local comp = body and body:call("getComponent(System.Type)", f[1])
                    if comp and pcall(comp.call, comp, f[2]) then
                        -- its own opening sets its data (and drops its items): ours to write isn't needed,
                        -- and the partner's drop flags would tell it the items are out already
                        gim.applying = false
                        gim.applied_at[id] = now()
                        gim.stats.finished = (gim.stats.finished or 0) + 1
                        return
                    end
                end
                break
            end
        end
    end
    for i = 0, count - 1 do
        local x = list:call("get_Item", i)
        local xt = x and x:get_type_definition():get_full_name()
        local w = xt and want[xt]
        if w then
            local dirty = false
            for fname, v in pairs(w) do
                local ok, cur = pcall(x.get_field, x, fname)
                local undo = guest and GIMMICK_NO_UNDO[fname]
                if undo and ok then
                    local a, b = cur == true and 1 or tonumber(cur) or 0, v == true and 1 or tonumber(v) or 0
                    if (undo == "up" and b > a) or (undo == "down" and b < a) then
                        gim.stats.kept = (gim.stats.kept or 0) + 1
                        ok = false
                    end
                end
                if ok and cur ~= v and not gim.unsaved[xt .. "." .. fname] then
                    x:set_field(fname, v)
                    dirty = true
                end
            end
            if dirty then
                pcall(x.call, x, "onDirty")
                changed = true
            end
        end
    end
    gim.applying = false
    if changed then
        gim.applied_at[id] = now()
        gim.stats.applied = gim.stats.applied + 1
    end
    local body = gc:call("get_BodyGameObject")
    for _, cu in ipairs(gim.catch_up) do
        local v = want[cu[2]] and want[cu[2]][cu[3]]
        local comp = v and v ~= 0 and (cu[6] == nil or v >= cu[6]) and body and body:call("getComponent(System.Type)", cu[1])
        -- set up already, nobody busy with it here (if it has steps), and behind the data
        local okst, step = pcall(function() return comp and comp:get_field("_StepType") end)
        if comp and comp:call("get_IsAlreadySetup") == true and (not okst or step == nil or step == 0) then
            local behind
            if cu[4] == nil then behind = not gim.caught[id]
            elseif v == true then behind = comp:get_field(cu[4]) == false
            else behind = comp:get_field(cu[4]) ~= v end
            if behind then
                gim.caught[id] = true
                local ok
                if cu[5] == "assign" then
                    local m = comp:get_type_definition():get_method("app.IStructureDataUser.assignDataContainer(app.StructureDataContainer)")
                    ok = m ~= nil and pcall(m.call, m, comp, gc:call("get_SDC"))
                else
                    ok = pcall(comp.call, comp, cu[5])
                end
                if ok then gim.stats.caught = (gim.stats.caught or 0) + 1 end
            end
        end
    end
    local ok, _, sig = pcall(gimmick_state, gc)
    if ok then gim.sig[id] = sig end -- what we now have is not a change of ours
end

-- key-item triggers worth replaying: the outcome of using an item, never player input
local function key_outcome(name)
    return type(name) == "string" and (name:find("^UseKeyItem_Success") or name:find("^UseKeyItem_Use")) ~= nil
end

local TYPE_KEY_HOLDER = sdk.typeof("app.InteractTriggerKeyItemInventoryHolder")
local TYPE_LOCK = sdk.typeof("app.GmLockV2")
local TYPE_ITEM_SLOTS = sdk.typeof("app.GmMultipleUseKeyItem")
local TYPE_CORE = sdk.typeof("app.GimmickCore")
local M_TRIGGER_PROCESS = sdk.find_type_definition("app.InteractTrigger"):get_method("onProcessEvent(via.GameObject)")
local SIG_TRIGGER_PROCESS = "onProcessEvent(via.GameObject)"

-- A partner's own interaction with a gimmick that moves only itself (no scene, camera, inventory or
-- action of the player): replayed on our copy, so it switches, breaks and sounds here the game's way
-- instead of jumping to the partner's data. Checked in game: a light switch's InteractOn and a crate's
-- Broken change only the gimmick (its data, its debris) and leave our player alone. Never on anything
-- with a player action (a situation, an item used, a file, a lock, a door, a ladder, a puzzle of its
-- own class) or on the collectibles each player breaks for themselves. A drawer's Interact isn't
-- either: replayed, it changed its data but didn't open (the player's hand opens it).
gim.interaction = {
    -- trigger -> the part a gimmick must have for it
    names = { InteractOn = "app.GmStructureDataSwitcher", InteractOff = "app.GmStructureDataSwitcher", Broken = "app.GmDurabilityV2" },
    unsafe = {
        ["app.GmSituationInteractable"] = true, ["app.GmLockV2"] = true, ["app.GmDoorV3"] = true,
        ["app.GmDoubleDoorV3"] = true, ["app.GmSlideDoorV2"] = true, ["app.GmDoorCrash"] = true,
        ["app.GmItemBoxV2"] = true, ["app.GmTypewriterV3"] = true, ["app.GmFileV2"] = true,
        ["app.GmDetailSearch"] = true, ["app.GmUseKeyItemV3"] = true, ["app.GmLadderV2"] = true,
        ["app.GmJackActionV2"] = true, ["app.GmFragileSymbol"] = true, ["app.GmSafe"] = true,
        ["app.GmContainer"] = true, ["app.GmMultipleUseKeyItem"] = true, ["app.GmMultipleUseKeyItemTarget"] = true,
        ["app.GmWristTagAuthenticator"] = true, ["app.GmCRControl"] = true, ["app.GmTimer"] = true,
        ["app.GmBulldozerBreakObject"] = true, ["app.GmBulldozerBreakObjectController"] = true,
        ["app.GmStorageV2"] = true,
    },
}
-- the interaction triggers of a gimmick that may be replayed ({name = true}), or nil
gim.interaction_names = function(body)
    local parts, unsafe = {}, false
    local function scan(go)
        local okc, comps = pcall(function() return go:call("get_Components"):get_elements() end)
        for _, c in ipairs(okc and comps or {}) do
            local tn = c:get_type_definition():get_full_name()
            if tn:find("^app%.Gm") then
                parts[tn] = true
                -- a class of its own (Gm02_032, Gm99_108...): a puzzle with its own scene
                if gim.interaction.unsafe[tn] or tn:find("^app%.Gm%d") then unsafe = true end
            end
        end
    end
    scan(body)
    local ch = body:call("get_Transform"):call("get_Child")
    while ch and not unsafe do
        scan(ch:call("get_GameObject"))
        ch = ch:call("get_Next")
    end
    if unsafe then return nil end
    local want
    for name, part in pairs(gim.interaction.names) do
        if parts[part] then
            want = want or {}
            want[name] = true
        end
    end
    return want
end

-- the replayable triggers here, by address and by "context id|name"
local function trigger_index(t_now, force)
    local ti = gim.triggers
    if force then
        if t_now < ti.forced then return ti end -- not more than once in 2 s
        ti.forced = t_now + 2
    elseif ti.chapter == me.chapter and t_now < ti.t then
        return ti
    end
    ti.t, ti.chapter, ti.by_addr, ti.by_key = t_now + 30, me.chapter, {}, {}
    ti.names = ti.names or {} -- every name replayed so far (a miss on one of these rebuilds the index)
    -- the triggers on `go` (every holder on it) whose names pass `want`
    local function add(go, want, ctx_id, interaction)
        local core = go and not ctx_id and go:call("getComponent(System.Type)", TYPE_CORE)
        local ok, id = true, ctx_id
        if not ctx_id then ok, id = pcall(function() return core:call("get_ContextID"):call("ToString") end) end
        -- right after a load the gimmicks' IDs aren't assigned yet (all zeros): index them later
        if not ok or not id or id:find("^00000000%-0000") then return end
        local lock = go:call("getComponent(System.Type)", TYPE_LOCK)
        -- now and then get_Components hands back something that isn't an array
        local okc, comps = pcall(function() return go:call("get_Components"):get_elements() end)
        for _, c in ipairs(okc and comps or {}) do
            local okt, trs = pcall(function() return c:get_field("_Triggers"):get_elements() end)
            for _, t in ipairs(okt and trs or {}) do
                local name = t:get_field("_Name")
                if want(name) then
                    ti.by_addr[t:get_address()] = { id = id, name = name, interaction = interaction }
                    ti.by_key[id .. "|" .. name] = { trig = t, go = go, lock = lock, interaction = interaction }
                    ti.names[name] = true
                end
            end
        end
    end
    for _, h in ipairs(world.scene_components(TYPE_KEY_HOLDER)) do
        -- An item used is replayed only where it goes into item slots (the heart and lung). Anywhere
        -- else it starts the gimmick's own scene or puzzle (a key turned, the microscope's molecules,
        -- the pencil rubbing): replayed on the partner's side that takes the partner's camera and
        -- controls. Locks open on their own unlock triggers below; other outcomes come with the state.
        local go = h:call("get_GameObject")
        local okf, slots = pcall(function() return go:call("getComponent(System.Type)", TYPE_ITEM_SLOTS) ~= nil end)
        if okf and slots then add(go, key_outcome) end
    end
    for _, lock in ipairs(world.scene_components(TYPE_LOCK)) do
        local names = {}
        local okp, params = pcall(function() return lock:get_field("_UnlockParams"):get_elements() end)
        for _, prm in ipairs(okp and params or {}) do
            local n = prm:get_field("_TriggerName")
            if n and n ~= "" and n ~= "Interact" then names[n] = true end
        end
        if next(names) then add(lock:call("get_GameObject"), function(n) return names[n] == true end) end
    end
    -- interactions that move only the gimmick (its body and the parts right under it)
    for _, gc in ipairs(gimmick_contexts(t_now)) do
        local okb, body = pcall(gc.call, gc, "get_BodyGameObject")
        local oki, want = pcall(function() return body and gim.interaction_names(body) end)
        local id = okb and oki and want and context_id(gc)
        if id then
            local function is_wanted(n) return want[n] == true end
            add(body, is_wanted, id, true)
            local ch = body:call("get_Transform"):call("get_Child")
            while ch do
                add(ch:call("get_GameObject"), is_wanted, id, true)
                ch = ch:call("get_Next")
            end
        end
    end
    return ti
end

local function replayable(name)
    return key_outcome(name) or (gim.triggers.names or {})[name] == true
end
gim.trigger_index = trigger_index

sdk.hook(M_TRIGGER_PROCESS, function(args)
    if gim.trigger_applying or not cfg.gimmick_sync or not world_shared() then return end
    local addr = sdk.to_int64(args[2])
    local t_now = now()
    local e = trigger_index(t_now).by_addr[addr]
    if e == nil then
        -- not indexed: rebuild only for names that look like an outcome
        local t = sdk.to_managed_object(args[2])
        local ok, name = pcall(function() return t:get_field("_Name") end)
        if not ok or not replayable(name) then return end
        e = trigger_index(t_now, true).by_addr[addr]
    end
    if e == nil then return end
    -- our game's own reaction to a replay (its chain fires more triggers) isn't news; one send per
    -- trigger is enough
    local key = e.id .. "|" .. e.name
    if t_now - (gim.applied_at[e.id] or -10) < 5 or t_now - (gim.trig_sent[key] or -10) < 10 then return end
    gim.trig_sent[key] = t_now
    -- an interaction carries the gimmick's state before it: the partner replays it only from the same
    -- state (where the result came first, the data has done it already)
    local before = ""
    if e.interaction then
        local ok, _, sig = pcall(gimmick_state, gim.by_id and gim.by_id[e.id])
        if not ok then return end
        before = sig
    end
    if #gim.out < 64 then
        gim.out[#gim.out + 1] = string.pack("<Bs1s1s1s2", MSG.GIMMICK_TRIGGER, me.chapter, e.id, e.name, before)
        gim.stats.live_sent = gim.stats.live_sent + 1
    end
end, nil)

-- a lock that is open already isn't opened again. Its own state says so (_IsCurrLock), not its data:
-- the partner's data (open, one more unlock) arrives before the trigger and the lock doesn't follow it
local function lock_open(lock)
    local ok, locked = pcall(lock.get_field, lock, "_IsCurrLock")
    return ok and locked == false
end

local function apply_trigger(data)
    local _, chapter, id, name, pos = string.unpack("<Bs1s1s1", data)
    if chapter ~= me.chapter then return end
    local before = #data >= pos + 1 and string.unpack("<s2", data, pos) or nil
    local key = id .. "|" .. name
    local t_now = now()
    local e = trigger_index(t_now).by_key[key] or trigger_index(t_now, true).by_key[key]
    if e == nil then return "missing" end -- not indexed (yet), or not loaded here
    if e.lock and lock_open(e.lock) then return end
    if e.interaction then
        local ok, _, sig = pcall(gimmick_state, gim.by_id and gim.by_id[id])
        if not ok or before == nil or before == "" or sig ~= before then
            gim.stats.interact_skipped = (gim.stats.interact_skipped or 0) + 1
            return
        end
    end
    -- the partner's data has counted this unlock already, and the lock counts it again when the trigger
    -- fires (on its next update): one off first, so it lands on the partner's count (a lock that wants
    -- two keys must not open on one)
    local d = e.lock and e.lock:get_field("_GmLockData")
    local count = d and d:get_field("_UnlockCount")
    local unlocks = false
    local okp, params = pcall(function() return e.lock:get_field("_UnlockParams"):get_elements() end)
    for _, prm in ipairs(okp and params or {}) do
        if prm:get_field("_TriggerName") == name then unlocks = true end
    end
    if unlocks then
        -- The partner's data for this lock, written just now, makes the lock drop the unlock: it waits
        -- until the lock has written its own state back (half a second), and the partner's data after
        -- it waits until the lock has opened.
        if t_now - (gim.applied_at[id] or -10) < 0.5 then return "wait" end
        if count and count > 0 then
            d:set_field("_UnlockCount", count - 1)
            pcall(d.call, d, "onDirty")
        end
        gim.hold[id] = t_now + 1.0
    end
    gim.trigger_applying = true
    pcall(e.trig.call, e.trig, SIG_TRIGGER_PROCESS, e.go)
    gim.trigger_applying = false
    gim.applied_at[id] = now()
    gim.stats.live_applied = gim.stats.live_applied + 1
    if e.interaction then gim.stats.interact_applied = (gim.stats.interact_applied or 0) + 1 end
end

-- the lobby owner sends every gimmick once when a partner shows up in the same chapter
local function gimmick_full_sync(t_now, peer_id)
    if gim.full_done_for ~= peer_id then
        gim.full_done_for = peer_id
        gim.full_pending = {}
        for _, gc in ipairs(gimmick_contexts(t_now)) do gim.full_pending[#gim.full_pending + 1] = gc end
        say("sending %d gimmick states to your partner", #gim.full_pending)
    end
    local pending = gim.full_pending
    if pending == nil or #pending == 0 then return end
    for _ = 1, 20 do
        local gc = table.remove(pending)
        if gc == nil then break end
        local id = context_id(gc)
        local ok, entries, sig = pcall(gimmick_state, gc)
        if id and ok and #entries > 0 then
            gim.sig[id] = sig
            send_ctrl(pack_gimmick(id, entries, true), peer_id)
            gim.stats.sent = gim.stats.sent + 1
        end
    end
end

local function gimmick_flags()
    local gm = gimmick_manager()
    if gm == nil then return end
    local f1, f2 = gm:get_field("_GlobalBitFlags") or 0, gm:get_field("_GlobalBitFlags2") or 0
    if f1 ~= gim.flags_sent[1] or f2 ~= gim.flags_sent[2] then
        gim.flags_sent = { f1, f2 }
        send_ctrl(string.pack("<Bs1I4I4", MSG_GIMMICK_FLAGS, me.chapter, f1, f2))
    end
end

local function apply_gimmick_flags(data)
    local _, chapter, f1, f2 = string.unpack("<Bs1I4I4", data)
    local gm = gimmick_manager()
    if gm == nil or chapter ~= me.chapter then return end
    local c1, c2 = gm:get_field("_GlobalBitFlags") or 0, gm:get_field("_GlobalBitFlags2") or 0
    if c1 | f1 ~= c1 then pcall(gm.call, gm, "enableGlobalBitFlags", f1 & ~c1) end
    if c2 | f2 ~= c2 then pcall(gm.call, gm, "enableGlobalBitFlags2", f2 & ~c2) end
    gim.flags_sent = { gm:get_field("_GlobalBitFlags") or 0, gm:get_field("_GlobalBitFlags2") or 0 }
end

gimmick_ctrl = function(from, kind, data)
    if not world_shared() or not cfg.gimmick_sync or #gim.queue >= 2048 then return end
    local st_net = session.status
    gim.queue[#gim.queue + 1] = { kind = kind, data = data, guest = not (st_net and from == st_net.owner) }
end

-- the partner's gimmick messages, applied inside the game's GUI update
gim.state_of, gim.contexts_of, gim.id_of = gimmick_state, gimmick_contexts, context_id

gim.gui_tick = function()
    if #gim.queue == 0 or not world_shared() then return end
    if ext.settled and not ext.settled() then return end -- (see the story's wait)
    local queue = gim.queue
    gim.queue = {}
    for i, m in ipairs(queue) do
        if i > 40 then -- the rest next frame (a full sync is ~500 messages)
            for j = i, #queue do gim.queue[#gim.queue + 1] = queue[j] end
            break
        end
        local ok, err
        if m.kind == MSG_GIMMICK then
            ok, err = pcall(apply_gimmick, m.data, m.guest)
            if ok and err == "held" then gim.queue[#gim.queue + 1] = m end
        elseif m.kind == MSG_GIMMICK_FLAGS then
            ok, err = pcall(apply_gimmick_flags, m.data)
        elseif m.kind == MSG.GIMMICK_TRIGGER then
            ok, err = pcall(apply_trigger, m.data)
            -- the gimmick may not be indexed yet: try again for 10 s (if it isn't loaded here at all,
            -- its data follows with the state sync)
            if ok and (err == "missing" or err == "wait") then
                m.till = m.till or now() + 10
                if now() < m.till then gim.queue[#gim.queue + 1] = m end
            end
        end
        if ok == false then say("gimmick error: %s", tostring(err)) end
    end
end

gimmick_reset = function()
    gim.sig, gim.sent_at, gim.applied_at, gim.contexts, gim.cursor, gim.out, gim.hold = {}, {}, {}, nil, 1, {}, {}
    gim.caught = {}
    gim.queue, gim.triggers, gim.trig_sent = {}, { by_addr = {}, by_key = {}, t = 0, chapter = "", forced = 0 }, {}
    gim.ids, gim.by_id = {}, {}
    gim.full_pending, gim.full_done_for, gim.flags_sent = nil, nil, { -1, -1 }
end

gimmicks_late = function(t_now)
    if not world_shared() or not cfg.gimmick_sync then return end
    gimmick_scan(t_now)
    local st_net = session.status
    local partner = partner_to_follow and partner_to_follow()
    if partner and partner.id ~= LOOPBACK_ID and partner.chapter == me.chapter
        and (gim.full_done_for == partner.id or ext.may_full_sync(st_net, partner.id)) then
        gimmick_full_sync(t_now, partner.id)
    end
    if #gim.out > 0 then
        local out = gim.out
        gim.out = {}
        for _, blob in ipairs(out) do send_ctrl(blob) end
        gim.stats.sent = gim.stats.sent + #out
    end
    if t_now >= (gim.next_flags or 0) then
        gim.next_flags = t_now + 1
        gimmick_flags()
    end
end
end
-- Drawers, cabinet doors, levers: moved with the player's hand. A gimmick of this kind keeps, for each
-- of its positions, the joints it moves and where to (GmStorageV2 / GmSwitchV2 _Params: GimmickParam
-- with GimmickInterpolationParam entries: _JointName "Drawer", the target _Position / _Rotation); the
-- player's action takes the joint there (InteractActionPlayerAction, its _TargetJointName the same).
-- The partner's game got only the gimmick's data, which moves nothing (its index, its action type,
-- its interpolation timer written: the drawer stayed shut). So the game whose player moves such a
-- joint sends its local position and rotation 15 times a second while it moves, and once more when
-- it stops; the partner's game takes its copy's joint there (written every frame, eased) and holds it
-- 5 s more: a drawer near a player is put back to its data's pose by its own update every frame while
-- its data says closed (GmStorageData._ActionType 0), and stays wherever its joint is once the data
-- says opened (2), which comes with the gimmick states. Only gimmicks within 8 m of a player are watched.
;(function()
local NEAR, HZ = 8, 15
local J = { index = {}, index_t = 0, index_chapter = "", near = {}, near_t = 0, last = {}, moving = {}, drive = {},
    driven_at = {}, next = 0, late_t = nil, stats = { sent = 0, applied = 0 } }
ext.gim_joints = J

-- the moving joints of the gimmicks within 16 m of a player: id -> { body, joints, storage }; looked
-- at every 2 s (a gimmick's area loads when a player comes near), each body's parts read once
local function joints_of(body)
    local joints, storage = {}, nil
    local okc, comps = pcall(function() return body:call("get_Components"):get_elements() end)
    for _, c in ipairs(okc and comps or {}) do
        local tn = c:get_type_definition():get_full_name()
        if tn == "app.GmStorageV2" then storage = c end
        if tn == "app.GmStorageV2" or tn == "app.GmSwitchV2" then
            local okp, params = pcall(function() return c:get_field("_Params"):get_elements() end)
            for _, prm in ipairs(okp and params or {}) do
                local oki, inner = pcall(function() return prm:get_field("_Params"):get_elements() end)
                for _, q in ipairs(oki and inner or {}) do
                    local okj, j = pcall(q.get_field, q, "_Joint")
                    if okj and j then
                        local a = j:get_address()
                        local dup = false
                        for _, x in ipairs(joints) do if x:get_address() == a then dup = true end end
                        if not dup then joints[#joints + 1] = j end
                    end
                end
            end
        end
    end
    return #joints > 0 and { joints = joints, storage = storage } or false
end

local function build_index(t_now, force)
    if not force and t_now < J.index_t and J.index_chapter == me.chapter then return end
    J.index_t = t_now + 2
    if J.index_chapter ~= me.chapter then J.cache, J.index_chapter = {}, me.chapter end
    J.cache = J.cache or {}
    local here = me.go and me.go:call("get_Transform"):call("get_Position")
    local there = peer_position and peer_position()
    if here == nil then return end
    local idx = {}
    for _, gc in ipairs(gim.contexts_of(t_now)) do
        local okb, body = pcall(gc.call, gc, "get_BodyGameObject")
        if okb and body then
            local okp, p = pcall(function() return body:call("get_Transform"):call("get_Position") end)
            if okp and ((p - here):length() < NEAR * 2 or (there and (p - there):length() < NEAR * 2)) then
                local a = body:get_address()
                local c = J.cache[a]
                if c == nil then
                    c = joints_of(body)
                    J.cache[a] = c
                end
                local id = c and gim.id_of(gc)
                if id then idx[id] = { body = body, joints = c.joints, storage = c.storage } end
            end
        end
    end
    J.index = idx
end

-- the ones near a player (every second)
local function near_list(t_now)
    if t_now < J.near_t then return J.near end
    J.near_t = t_now + 1
    local here = me.go:call("get_Transform"):call("get_Position")
    local there = peer_position and peer_position()
    local list = {}
    for id, g in pairs(J.index) do
        local ok, p = pcall(function() return g.body:call("get_Transform"):call("get_Position") end)
        if ok and ((p - here):length() < NEAR or (there and (p - there):length() < NEAR)) then list[#list + 1] = id end
    end
    J.near = list
    return list
end

local function moved(a, b)
    return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]) > 0.002
        or math.abs(a[4] - b[4]) + math.abs(a[5] - b[5]) + math.abs(a[6] - b[6]) + math.abs(a[7] - b[7]) > 0.002
end

ext.joint_scan = function(t_now)
    if me.go == nil or t_now < J.next then return end
    J.next = t_now + 1 / HZ
    build_index(t_now)
    for _, id in ipairs(near_list(t_now)) do
        local g = J.index[id]
        -- a drawer's open / closed state (GmStorageData._ActionType) isn't in the gimmick's stored state
        -- (store() leaves GmStorageData out): it goes with the joint, or the partner's copy is shut
        -- again by its own update once the hold ends
        local okd, act = pcall(function() return g.storage and g.storage:get_field("_GmStorageData"):get_field("_ActionType") end)
        act = okd and type(act) == "number" and act or 255
        for k, j in ipairs(g and g.joints or {}) do
            local key = id .. ":" .. k
            local ok, lp, lr = pcall(function() return j:call("get_LocalPosition"), j:call("get_LocalRotation") end)
            if ok and lp and lr then
                local v = { lp.x, lp.y, lp.z, lr.x, lr.y, lr.z, lr.w }
                local last = J.last[key]
                J.last[key] = v
                local ours = J.drive[key] == nil and t_now - (J.driven_at[key] or -10) > 0.5
                if ours and last and moved(v, last) then
                    J.moving[key] = t_now
                    world.out[#world.out + 1] = string.pack("<Bs1s1Bfffffff BB", MSG.GIM_JOINT, me.chapter, id, k, v[1], v[2], v[3], v[4], v[5], v[6], v[7], 0, act)
                    J.stats.sent = J.stats.sent + 1
                elseif ours and J.moving[key] and t_now - J.moving[key] > 0.3 then
                    J.moving[key] = nil
                    world.out[#world.out + 1] = string.pack("<Bs1s1Bfffffff BB", MSG.GIM_JOINT, me.chapter, id, k, v[1], v[2], v[3], v[4], v[5], v[6], v[7], 1, act)
                end
            end
        end
    end
end

ext.joint_ctrl = function(data)
    local _, chapter, id, k, x, y, z, qx, qy, qz, qw, final, act = string.unpack("<Bs1s1Bfffffff BB", data)
    if chapter ~= me.chapter then return end
    build_index(now())
    if J.index[id] == nil and now() - (J.forced_t or -10) > 1 then
        J.forced_t = now()
        build_index(now(), true)
    end
    local g = J.index[id]
    local j = g and g.joints[k]
    if j == nil then return end
    if g.storage and act ~= 255 then
        pcall(function() g.storage:get_field("_GmStorageData"):set_field("_ActionType", act) end)
    end
    J.drive[id .. ":" .. k] = { j = j, pos = Vector3f.new(x, y, z), rot = Quaternion.new(qw, qx, qy, qz), t = now(), final = final == 1 }
    J.stats.applied = J.stats.applied + 1
end

-- every frame: our copies' joints eased toward the partner's
re.on_application_entry("LateUpdateBehavior", function()
    if next(J.drive) == nil then return end
    local t = now()
    local dt = math.min(0.1, t - (J.late_t or t))
    J.late_t = t
    local f = math.min(1, math.max(dt, 1 / 120) * HZ)
    for key, dv in pairs(J.drive) do
        local ok = pcall(function()
            local lp, lr = dv.j:call("get_LocalPosition"), dv.j:call("get_LocalRotation")
            local np = lp + (dv.pos - lp) * f
            local nr = lr:slerp(dv.rot, f)
            dv.j:call("set_LocalPosition", np)
            dv.j:call("set_LocalRotation", nr)
            J.driven_at[key] = t
            J.last[key] = { np.x, np.y, np.z, nr.x, nr.y, nr.z, nr.w }
            -- held 5 s after the last: a drawer whose data still says closed is put back shut by its own
            -- update every frame (near a player), until the partner's data ("opened") arrives; then it
            -- stays where the joint is
            if t - dv.t > (dv.final and 5 or 3) then
                dv.j:call("set_LocalPosition", dv.pos)
                dv.j:call("set_LocalRotation", dv.rot)
                J.drive[key] = nil
            end
        end)
        if not ok then J.drive[key] = nil end
    end
end)
end)()


-------------------------------------------------------------------------------------------------
-- shared story progress and chapters
-------------------------------------------------------------------------------------------------
-- The chapter's level flows (app.LevelFlowManager, ~640 per chapter) each keep a progress number
-- (_ProgressiveNumberList: flow hash -> step). Every step either game takes
-- (LevelFlowManager.setProgressiveNumber) is sent to the partner, whose game takes the same step
-- through requestChangeProgressiveNumber, the game's own way to move a flow on. On joining, the lobby
-- owner sends every flow that has moved. Chapters: when the lobby owner is in another chapter, the
-- guest's game jumps there (MainGameFlowManager.setOverrideNextJumpScene + requestGameJump) after
-- a 5 s countdown, unless "Follow the host to new chapters" is off.
local story, story_late
do
local M_SET_PROGRESS = sdk.find_type_definition("app.LevelFlowManager"):get_method("setProgressiveNumber(System.UInt32, System.Int32)")
local T_MEDIATOR = "app.TimelineEventMediator"

story = {
    expect = {},          -- flow hash -> value we asked for (its echo isn't sent back)
    out = {},
    wait = {},            -- the partner's steps that came while our game was still setting up
    full_done_for = nil,
    follow = { target = nil, at = 0, tries = 0 },
    stats = { sent = 0, applied = 0, jumps = 0 },
}

local function level_flow()
    return sdk.get_managed_singleton("app.LevelFlowManager")
end

-- true while a cutscene plays here (cached per frame)
local cutscene_cache = { t = -1, v = false }
in_cutscene = function()
    local t = now()
    if t ~= cutscene_cache.t then
        cutscene_cache.t = t
        local m = sdk.get_managed_singleton(T_MEDIATOR)
        local ok, v = pcall(function() return m and m:call("get_IsPlayingCutScene") end)
        cutscene_cache.v = ok and v == true
    end
    return cutscene_cache.v
end

local progress_list
story.flows = function() return progress_list() end
progress_list = function()
    local lf = level_flow()
    local d = lf and lf:get_field("_ProgressiveNumberList")
    local entries = d and d:get_field("_entries")
    local n = d and d:get_field("_count") or 0
    local out = {}
    if entries then
        for i, e in ipairs(elements(entries) or {}) do
            if i > n then break end
            local h = e:get_field("hashCode")
            if h and h >= 0 then out[e:get_field("key")] = e:get_field("value") end
        end
    end
    return out
end

sdk.hook(M_SET_PROGRESS, function(args)
    if not world_shared() or not cfg.story_sync then return end
    local hash = sdk.to_int64(args[3]) & 0xFFFFFFFF
    local value = int32(sdk.to_int64(args[4]))
    if story.expect[hash] == value then
        story.expect[hash] = nil
        return
    end
    if #story.out < 128 then
        story.out[#story.out + 1] = string.pack("<Bs1I4i4", MSG_STORY, me.chapter, hash, value)
    end
end, nil)

local function apply_story(data, from)
    local kind, chapter, hash, value = string.unpack("<Bs1I4i4", data)
    if chapter ~= me.chapter then return end
    local lf = level_flow()
    if lf == nil then return end
    local ok, cur = pcall(lf.call, lf, "getProgressiveNumber", hash)
    if ok and cur == value then return end
    -- a whole-chapter catch-up only moves flows on, never back; and so do the guest's steps: a guest whose
    -- world was behind (a new game in the chapter) sent its earlier steps, the host's flows went back and
    -- the game locked again the doors those steps lock (found in a host's save after a session)
    local st_net = session.status
    local from_owner = st_net and from ~= nil and from == st_net.owner
    if (kind == MSG.STORY_FWD or not from_owner) and ok and type(cur) == "number" and cur > value then
        story.stats.back = (story.stats.back or 0) + 1
        return
    end
    story.expect[hash] = value
    pcall(lf.call, lf, "requestChangeProgressiveNumber", hash, value)
    story.stats.applied = story.stats.applied + 1
end

local function jump_to_chapter(name)
    local mg = sdk.get_managed_singleton("app.MainGameFlowManager")
    local lf = level_flow()
    if mg == nil or lf == nil then return false end
    ext.later(function()
        pcall(mg.call, mg, "setOverrideNextJumpScene", name)
        pcall(lf.call, lf, "requestGameJump")
    end)
    story.stats.jumps = story.stats.jumps + 1
    if ext.fade_arm then ext.fade_arm() end
    say("going to %s", name)
    return true
end

-- "Chap3_0304" is a folder; if jumping to it doesn't work, try the chapter it belongs to ("Chap3_03")
local function chapter_jump_name(folder, tries)
    if tries % 2 == 0 then return folder end
    return folder:match("^(Chap%d+_%d%d)%d%d$") or folder
end

-- "Chap3_03" and "Chap3_0304" (the folder a player was made in) are the same chapter
local function same_chapter(a, b)
    return a == b or (a:match("^(Chap%d+_%d%d)") or a) == (b:match("^(Chap%d+_%d%d)") or b)
end

local function host_peer()
    if _G.re9coop_test_host then return _G.re9coop_test_host end -- dev bridge only
    local st_net = session.status
    return st_net and st_net.owner ~= st_net.me and peers[st_net.owner] or nil
end

go_to_partner_chapter = function()
    local p = partner_to_follow and partner_to_follow()
    if p == nil or p.chapter == "" then return "no partner" end
    if p.chapter == me.chapter then return "you're already in " .. me.chapter end
    story.follow.tries = story.follow.tries + 1
    jump_to_chapter(chapter_jump_name(p.chapter, story.follow.tries - 1))
    return "going to " .. p.chapter
end

-- The partner's steps wait while our game is still setting a scene up (no player yet, a cutscene,
-- a fade): the host's whole-chapter catch-up applied while a co-op playthrough's chapter was still
-- loading moved its flows past the chapter's opening event, which then never ran: a black screen,
-- and no moving or looking around. Applied once we've been free for 3 s, they leave it alone.
story_ctrl = function(from, kind, data)
    if not world_shared() or not cfg.story_sync then return end
    if kind ~= MSG_STORY and kind ~= MSG.STORY_FWD then return end
    if ext.settled and not ext.settled() then
        if #story.wait < 4096 then story.wait[#story.wait + 1] = { data, from } end
        return
    end
    pcall(apply_story, data, from)
end

story_reset = function()
    story.expect, story.out, story.full_done_for, story.wait = {}, {}, nil, {}
end

story_late = function(t_now)
    if not world_shared() and not _G.re9coop_test_host then return end
    local st_net = session.status
    -- the lobby owner sends every flow that has moved, once per partner per chapter
    local partner = partner_to_follow and partner_to_follow()
    if cfg.story_sync and partner and partner.id ~= LOOPBACK_ID and partner.chapter == me.chapter
        and story.full_done_for ~= partner.id and ext.may_full_sync(st_net, partner.id) then
        story.full_done_for = partner.id
        local n = 0
        for hash, value in pairs(progress_list()) do
            if value ~= 0 then
                send_ctrl(string.pack("<Bs1I4i4", MSG.STORY_FWD, me.chapter, hash, value), partner.id)
                n = n + 1
            end
        end
        say("sent %d story steps to your partner", n)
        story.stats.sent = story.stats.sent + n
        if ext.send_pickups then
            local np = ext.send_pickups(partner.id)
            if np > 0 then say("sent %d pickups made here to your partner", np) end
        end
    end
    if #story.wait > 0 and (ext.settled == nil or ext.settled()) then
        local wait = story.wait
        story.wait = {}
        ext.later(function()
            for _, d in ipairs(wait) do pcall(apply_story, d[1], d[2]) end
        end)
        say("caught up with %d story steps from your partner", #wait)
    end
    if #story.out > 0 then
        local out = story.out
        story.out = {}
        for _, blob in ipairs(out) do send_ctrl(blob) end
        story.stats.sent = story.stats.sent + #out
    end
    -- follow the host into its chapter
    local hp = host_peer()
    local f = story.follow
    if cfg.follow_host and hp and hp.chapter ~= "" and me.chapter ~= "" and not same_chapter(hp.chapter, me.chapter)
        and #hp.snaps > 0 and t_now - hp.last < 3 and not in_cutscene() then
        if f.target ~= hp.chapter then
            f.target, f.at, f.tries = hp.chapter, t_now + 5, 0
            say("the host is in %s: following in 5 s", hp.chapter)
        elseif t_now >= f.at then
            jump_to_chapter(chapter_jump_name(f.target, f.tries))
            f.tries = f.tries + 1
            f.at = t_now + 25 -- if we're still not there by then, try the other name
        end
    elseif f.target and (hp == nil or same_chapter(hp.chapter, me.chapter)) then
        f.target = nil
    end
end
end

-------------------------------------------------------------------------------------------------
-- shared item box
-------------------------------------------------------------------------------------------------
-- The item boxes (app.Inventory of board type ItemBox or ShareItemBox, a 1 x 100 list) hold the same
-- things in both games, so what one player puts in, the other can take out. Twice a second each box
-- is read (getPanelStates: item, count, loaded ammo) and what changed since the last look goes to
-- the partner as operations: "+panel" (put in) and "-panel" (taken out). The partner's game does the
-- same to its box (addPanel + reloadDirect for a gun's ammo, removePanel), but not while that player
-- has a box open: then it waits until they close it. Operations never lose an item: if both players
-- take the same thing at the same moment, both get it. On joining, the lobby owner sends its boxes;
-- the guest's game puts in what it lacks and sends back what the owner lacks.
-- Only changes made while the player uses an item box are sent (its GmItemBoxV2 isn't idle, or the
-- box screen's GuiItemBoxModel is at work): the game also fills boxes itself when a chapter starts,
-- and both games do that on their own.
local box
do
local BOX_BOARDS = { [1] = true, [2] = true } -- app.InventoryType: ItemBox, ShareItemBox
local SIG_ADD = "addPanel(app.ItemID, System.Int32, via.Int2, app.InventoryPanelRotateType, app.ItemStockChangedEventType)"
local SIG_CAN_ADD = "canAddPanel(app.ItemID, System.Int32, via.Int2, app.InventoryPanelRotateType)"
local SIG_REMOVE = "removePanel(app.Inventory.PanelKey, app.ItemStockChangedEventType)"
local SIG_RELOAD = "reloadDirect(app.Inventory.PanelKey, System.Int32, app.ItemID)"
local T_ITEM_ID = sdk.find_type_definition("app.ItemID")
local T_INT2 = sdk.find_type_definition("via.Int2")
local TYPE_BOX_GIMMICK = sdk.typeof("app.GmItemBoxV2")
local FLAG_OPS, FLAG_JOIN = 0, 1
-- the stock event our box changes carry: "moved", as when the game's box moves an item
local EVENT_MOVED = sdk.find_type_definition("app.ItemStockChangedEventType"):get_field("Moved"):get_data(nil)
if EVENT_MOVED then EVENT_MOVED:add_ref_permanent() end

box = {
    known = {},         -- box key ("User00/1") -> { panel -> count } as we last saw it
    queue = {},         -- { {key, ops}, ... } from the partner, waiting for our box to be closed
    next_scan = 0,
    gimmicks = {}, gimmicks_t = 0, gimmicks_chapter = "",
    full_done_for = nil,
    my_takes = {},      -- "box key|panel" -> when we took that out (both taking it: see apply_ops)
    stats = { sent = 0, applied = 0, races = 0 },
}

local function box_inventories()
    local m = sdk.get_managed_singleton("app.InventoryManager")
    local d = m and m:get_field("_Inventories")
    local entries = d and d:get_field("_entries")
    local n = d and d:get_field("_count") or 0
    local out = {}
    if entries == nil then return out end
    for i, e in ipairs(elements(entries) or {}) do
        if i > n then break end
        local inv = (e:get_field("hashCode") or -1) >= 0 and e:get_field("value") or nil
        local k = inv and inv:get_field("_InventoryKey")
        local board = k and k:get_field("_BoardType")
        local user = k and k:get_field("_User")
        if board and BOX_BOARDS[board] and user and not k:get_field("_IsTemporal") then
            local ok, uname = pcall(user.call, user, "ToString")
            if ok and uname then out[uname .. "/" .. board] = inv end
        end
    end
    return out
end

-- A panel as "item|count|rotation|ammo:count,...@x,y": the part before "@" is what panels are matched
-- by (a box may move its panels around), the slot is only where we try to put it.
local function panel_entry(st)
    local id = st:call("get_ItemID")
    local name = id and id:get_field("_Name")
    if not name then return nil end
    local loads = {}
    local li = st:call("get_LoadingItems")
    for _, c in ipairs(elements(li) or {}) do
        local ad = c:get_field("_AmountData")
        local an, as = ad and ad:get_field("_ItemID"), ad and ad:get_field("_Stock")
        if an and as and as > 0 then loads[#loads + 1] = an .. ":" .. as end
    end
    local p = st:call("get_Position")
    return string.format("%s|%d|%d|%s@%d,%d", name, st:call("get_Stock") or 0, st:call("get_RotateType") or 0,
        table.concat(loads, ","), p and p.x or 0, p and p.y or 0)
end

local function ident(e) return e:match("^[^@]*") end

-- { {e = entry, id = ident, key = PanelKey}, ... } and { ident -> count }
local function read_box(inv)
    local list, counts = {}, {}
    local states = elements(inv:call("getPanelStates"))
    -- an unreadable box must not look empty (that would take everything out of the partner's box)
    if states == nil then error("unreadable box") end
    for _, st in ipairs(states) do
        local e = panel_entry(st)
        if e then
            local id = ident(e)
            list[#list + 1] = { e = e, id = id, key = st:call("get_Key") }
            counts[id] = (counts[id] or 0) + 1
        end
    end
    return list, counts
end

local function pack_box(key, flag, ops)
    local t = { string.pack("<Bs1BH", MSG.BOX, key, flag, #ops) }
    for _, op in ipairs(ops) do t[#t + 1] = string.pack("<s2", op) end
    return table.concat(t)
end

local function item_id(name)
    local f = T_ITEM_ID:get_field(name)
    if f == nil then return nil end
    local ok, v = pcall(f.get_data, f, nil)
    return ok and v or nil
end

local function int2(x, y)
    local v = ValueType.new(T_INT2)
    v.x, v.y = x, y
    return v
end

-- where a panel can go: its own slot if free, else the first free one
local function free_slot(inv, id, stock, rot, x, y)
    local ok, can = pcall(inv.call, inv, SIG_CAN_ADD, id, stock, int2(x, y), rot)
    if ok and can then return int2(x, y) end
    local size = inv:get_field("_UnlockSlotSize")
    for yy = 0, (size and size.y or 100) - 1 do
        for xx = 0, (size and size.x or 1) - 1 do
            ok, can = pcall(inv.call, inv, SIG_CAN_ADD, id, stock, int2(xx, yy), rot)
            if ok and can then return int2(xx, yy) end
        end
    end
    return nil
end

local function add_entry(inv, e)
    local name, stock, rot, loads, x, y = e:match("^([^|]+)|(-?%d+)|(%d+)|([^@]*)@(-?%d+),(-?%d+)$")
    local id = name and item_id(name)
    if id == nil then return false end
    stock, rot = tonumber(stock), tonumber(rot)
    local pos = free_slot(inv, id, stock, rot, tonumber(x), tonumber(y))
    if pos == nil then return false end
    local ok, key = pcall(inv.call, inv, SIG_ADD, id, stock, pos, rot, EVENT_MOVED)
    if not ok or key == nil then return false end
    for an, as in loads:gmatch("([^:,]+):(%d+)") do
        local aid = item_id(an)
        if aid then pcall(inv.call, inv, SIG_RELOAD, key, tonumber(as), aid) end
    end
    return true
end

local function apply_ops(inv, ops, key)
    local list = read_box(inv)
    for _, op in ipairs(ops) do
        local sign, body = op:sub(1, 1), op:sub(2)
        if sign == "-" then
            local found = false
            for i, x in ipairs(list) do
                if x.id == body then
                    pcall(inv.call, inv, SIG_REMOVE, x.key, EVENT_MOVED)
                    table.remove(list, i)
                    found = true
                    break
                end
            end
            if not found and key then box.race(key, body) end
        elseif sign == "+" and not add_entry(inv, body) then
            say("couldn't put %s in the box", body:match("^[^|]*"))
        end
    end
    box.stats.applied = box.stats.applied + 1
end

-- The partner took out what isn't in our box any more because we took it out too, a moment ago:
-- both got it. The lobby owner keeps it; the guest's copy goes from their hands (the same panel,
-- if it is still there as it came out of the box).
box.race = function(key, body)
    local mine = box.my_takes[key .. "|" .. body]
    if mine == nil or now() - mine > 10 then return end
    box.my_takes[key .. "|" .. body] = nil
    box.stats.races = box.stats.races + 1
    local item = body:match("^[^|]*")
    local st_net = session.status
    if st_net and st_net.is_host then
        say("you and your partner took %s from the box at the same time: it's yours", item)
        return
    end
    local user = key:match("^(.-)/")
    local m = sdk.get_managed_singleton("app.InventoryManager")
    local d = m and m:get_field("_Inventories")
    local n = d and d:get_field("_count") or 0
    for i, e in ipairs(elements(d and d:get_field("_entries")) or {}) do
        if i > n then break end
        local inv = (e:get_field("hashCode") or -1) >= 0 and e:get_field("value") or nil
        local k = inv and inv:get_field("_InventoryKey")
        local u = k and k:get_field("_User")
        if k and k:get_field("_BoardType") == 0 and not k:get_field("_IsTemporal") and u and u:call("ToString") == user then
            for _, x in ipairs(read_box(inv)) do
                if x.id == body then
                    pcall(inv.call, inv, SIG_REMOVE, x.key, EVENT_MOVED)
                    say("your partner took %s from the box first: it's theirs", item)
                    return
                end
            end
        end
    end
    say("you and your partner both took %s from the box", item)
end

-- what changed in a box since we last looked, as operations
local function diff_ops(old, list, counts)
    local ops, seen = {}, {}
    for _, x in ipairs(list) do
        seen[x.id] = (seen[x.id] or 0) + 1
        if seen[x.id] > (old[x.id] or 0) then ops[#ops + 1] = "+" .. x.e end
    end
    for id, c in pairs(old) do
        for _ = (counts[id] or 0) + 1, c do ops[#ops + 1] = "-" .. id end
    end
    return ops
end

-- the box screen at work
for _, m in ipairs(sdk.find_type_definition("app.GuiItemBoxModel"):get_methods()) do
    if ({ setup = 1, canStore = 1, collectHasItem = 1, makeItemData = 1 })[m:get_name()] then
        sdk.hook(m, function() box.used_t = now() end, nil)
    end
end

-- true while one of the item boxes here is in use (its menu may be open)
local function box_in_use(t_now)
    if t_now >= box.gimmicks_t or box.gimmicks_chapter ~= me.chapter then
        box.gimmicks_t, box.gimmicks_chapter = t_now + 5, me.chapter
        box.gimmicks = world.scene_components(TYPE_BOX_GIMMICK)
    end
    for _, g in ipairs(box.gimmicks) do
        local ok, idle = pcall(g.call, g, "get_IsStepTypeNone")
        if ok and idle == false then
            box.used_t = t_now
            return true
        end
    end
    return false
end

-- the lobby owner's box as we join: put in what we lack, send back what it lacks
local function join_merge(key, inv, entries, from)
    local list, counts = read_box(inv)
    local mine, ops_here, ops_there = {}, {}, {}
    for id, c in pairs(counts) do mine[id] = c end
    for _, e in ipairs(entries) do
        local id = ident(e)
        if (mine[id] or 0) > 0 then mine[id] = mine[id] - 1 else ops_here[#ops_here + 1] = "+" .. e end
    end
    for _, x in ipairs(list) do
        if (mine[x.id] or 0) > 0 then
            mine[x.id] = mine[x.id] - 1
            ops_there[#ops_there + 1] = "+" .. x.e
        end
    end
    -- a guest in a co-op playthrough takes the owner's box as it is: what the new game put in theirs
    -- (a chapter's starting things) goes, nothing goes back
    if ext.fresh and ext.fresh.active then
        for _, x in ipairs(list) do
            if (mine[x.id] or 0) > 0 then
                mine[x.id] = mine[x.id] - 1
                pcall(inv.call, inv, SIG_REMOVE, x.key, EVENT_MOVED)
            end
        end
        ops_there = {}
    end
    if #ops_here > 0 then apply_ops(inv, ops_here) end
    if #ops_there > 0 then send_ctrl(pack_box(key, FLAG_OPS, ops_there), from) end
    say("item box %s: got %d, sent %d", key, #ops_here, #ops_there)
end

ext.box_ctrl = function(from, kind, data)
    -- our own echo (self test) would put everything in twice
    if from == LOOPBACK_ID or not world_shared() or not cfg.box_sync then return end
    local _, key, flag, n, pos = string.unpack("<Bs1BH", data)
    local ops = {}
    for i = 1, n do ops[i], pos = string.unpack("<s2", data, pos) end
    if #box.queue < 256 then box.queue[#box.queue + 1] = { key = key, flag = flag, ops = ops, from = from } end
end

ext.box_reset = function()
    box.gimmicks, box.gimmicks_t = {}, 0
    box.known, box.my_takes = {}, {} -- the next scene starts from what its boxes hold
end

box.late = function(t_now)
    if not world_shared() or not cfg.box_sync or EVENT_MOVED == nil or t_now < box.next_scan then return end
    box.next_scan = t_now + 0.5
    local invs = box_inventories()
    -- our own changes first, so the partner's below aren't taken for ours (sent only when the player
    -- used a box just now)
    local in_use = box_in_use(t_now) or t_now - (box.used_t or -10) < 3
    for key, inv in pairs(invs) do
        local list, counts = read_box(inv)
        local old = box.known[key]
        box.known[key] = counts
        if old and in_use then
            local ops = diff_ops(old, list, counts)
            if #ops > 0 then
                send_ctrl(pack_box(key, FLAG_OPS, ops))
                box.stats.sent = box.stats.sent + 1
                for _, op in ipairs(ops) do
                    if op:sub(1, 1) == "-" then box.my_takes[key .. "|" .. op:sub(2)] = t_now end
                end
            end
        end
    end
    -- the partner's, when no box is open here
    if #box.queue > 0 and not box_in_use(t_now) and t_now - (box.used_t or -10) > 0.5 then
        local queue = box.queue
        box.queue = {}
        for _, m in ipairs(queue) do
            local inv = invs[m.key]
            if inv then
                local ok, err
                if m.flag == FLAG_JOIN then
                    ok, err = pcall(join_merge, m.key, inv, m.ops, m.from)
                else
                    ok, err = pcall(apply_ops, inv, m.ops, m.key)
                end
                if not ok and tostring(err):find("unreadable", 1, true) then
                    box.queue[#box.queue + 1] = m -- nothing was applied: next time
                else
                    if not ok then say("box error: %s", tostring(err)) end
                    local _, counts = read_box(inv)
                    box.known[m.key] = counts
                end
            end
        end
    end
    -- the lobby owner sends its boxes once to a partner who joins
    local st_net = session.status
    local partner = partner_to_follow and partner_to_follow()
    if partner and partner.id ~= LOOPBACK_ID and box.full_done_for ~= partner.id and ext.may_full_sync(st_net, partner.id) then
        box.full_done_for = partner.id
        for key, inv in pairs(invs) do
            local entries = {}
            for _, x in ipairs((read_box(inv))) do entries[#entries + 1] = x.e end
            send_ctrl(pack_box(key, FLAG_JOIN, entries), partner.id)
            box.stats.sent = box.stats.sent + 1
        end
    end
end

-- Boxes are read and changed only inside the game's GUI update (GuiAutoSaveFlowController.update runs
-- every frame), where the game's own item box moves items: changing an inventory from REFramework's
-- frame callbacks crashed the game a moment later on one of its worker threads. The partner's gimmick
-- changes are applied here too.
local M_GUI_UPDATE = sdk.find_type_definition("app.GuiAutoSaveFlowController"):get_method("update")
if M_GUI_UPDATE then
    sdk.hook(M_GUI_UPDATE, function()
        local ok, err = pcall(box.late, now())
        if not ok then say("item box error: %s", tostring(err)) end
        ok, err = pcall(gim.gui_tick)
        if not ok then say("gimmick error: %s", tostring(err)) end
        if #ext.jobs > 0 then
            local jobs = ext.jobs
            ext.jobs = {}
            for _, fn in ipairs(jobs) do
                ok, err = pcall(fn)
                if not ok then say("error: %s", tostring(err)) end
            end
        end
        if ext.life_gui then
            ok, err = pcall(ext.life_gui)
            if not ok then say("grab error: %s", tostring(err)) end
        end
        if ext.recipes_gui then
            ok, err = pcall(ext.recipes_gui)
            if not ok then say("recipe error: %s", tostring(err)) end
        end
        if ext.cut_gui then
            ok, err = pcall(ext.cut_gui)
            if not ok then say("cutscene error: %s", tostring(err)) end
        end
    end, nil)
end

box.read_box, box.panel_entry, box.add_entry = read_box, panel_entry, add_entry
box.remove_panel = function(inv, key) return pcall(inv.call, inv, SIG_REMOVE, key, EVENT_MOVED) end
-- dev
box.box_inventories, box.pack_box = box_inventories, pack_box
end

-------------------------------------------------------------------------------------------------
-- crafting recipes
-------------------------------------------------------------------------------------------------
-- A recipe one player unlocks (a recipe file, the microscope's blood analysis) is unlocked for both.
-- The analysis only runs on the solver's side, and the partner's microscope then shows it done, so
-- the partner could never get those recipes. Each game sends the names of its unlocked recipes when
-- that list grows (and once to a partner who shows up); the other unlocks the ones it lacks, inside
-- the game's GUI update.
do
local T_RECIPE_ID = sdk.find_type_definition("app.CraftRecipeID")
local SIG_UNSEAL = "unsealCraftRecipe(app.CraftRecipeID, System.Boolean)"
local recipes = { n = -1, t = 0, peer = nil, pending = nil, stats = { sent = 0, applied = 0 } }
ext.recipes = recipes

local function recipe_set()
    local im = sdk.get_managed_singleton("app.ItemManager")
    return im, im and im:get_field("_UnlockedCraftRecipeIDSet")
end

local function recipe_names(set)
    local out = {}
    local en = set:call("GetEnumerator")
    while en:call("MoveNext") do
        local v = en:call("get_Current")
        local name = v and v:call("ToString")
        if name then out[#out + 1] = name end
    end
    return out
end

ext.recipes_late = function(t_now)
    if not world_shared() or not cfg.recipe_sync or t_now < recipes.t then return end
    recipes.t = t_now + 2
    local _, set = recipe_set()
    if set == nil then return end
    local n = set:call("get_Count")
    local partner = partner_to_follow and partner_to_follow()
    local pid = partner and partner.id
    if n == recipes.n and pid == recipes.peer then return end
    recipes.n, recipes.peer = n, pid
    if n == 0 or pid == nil then return end
    local t = { "" }
    local count = 0
    for _, name in ipairs(recipe_names(set)) do
        if count < 1000 then t[#t + 1] = string.pack("<s1", name) count = count + 1 end
    end
    t[1] = string.pack("<BH", MSG.RECIPES, count)
    send_ctrl(table.concat(t))
    recipes.stats.sent = recipes.stats.sent + 1
end

ext.recipes_ctrl = function(_, _, data)
    if not world_shared() or not cfg.recipe_sync then return end
    local _, n, pos = string.unpack("<BH", data)
    local names = {}
    for _ = 1, n do
        local name
        name, pos = string.unpack("<s1", data, pos)
        names[#names + 1] = name
    end
    recipes.pending = names
end

ext.recipes_gui = function()
    local names = recipes.pending
    if names == nil then return end
    recipes.pending = nil
    local im, set = recipe_set()
    if set == nil then return end
    local have = {}
    for _, name in ipairs(recipe_names(set)) do have[name] = true end
    local added = 0
    for _, name in ipairs(names) do
        local f = not have[name] and T_RECIPE_ID:get_field(name)
        local id = f and f:get_data(nil)
        if id and pcall(im.call, im, SIG_UNSEAL, id, true) then added = added + 1 end
    end
    if added > 0 then
        recipes.stats.applied = recipes.stats.applied + added
        say("%d crafting recipe(s) from your partner", added)
    end
end
end

-------------------------------------------------------------------------------------------------
-- cutscenes together
-------------------------------------------------------------------------------------------------
-- A cutscene one player skips is skipped in the partner's game too when it plays the same one: the
-- game's own TimelineEventMediator.skip (what the pause menu's "skip" calls), matched by the event's
-- TimelineEventId. The partner's skip may come just before ours starts: it waits 5 s for it.
do
local T_MEDIATOR = "app.TimelineEventMediator" -- the story section's is local to it
local cut = { pending = nil, until_t = 0, replaying = false, fade_check = nil, stats = { sent = 0, applied = 0 } }
ext.cut = cut

local function mediator()
    return sdk.get_managed_singleton(T_MEDIATOR)
end

-- the id of the cutscene playing here, or nil
local function current_event(m)
    local list = m and m:get_field("_ActiveEvents")
    local n = list and list:call("get_Count") or 0
    for i = 0, n - 1 do
        local e = list:call("get_Item", i)
        local ok, id = pcall(e.get_field, e, "<TimelineEventId>k__BackingField")
        if ok and id then return id end
    end
    return nil
end
cut.current_event = current_event

sdk.hook(sdk.find_type_definition(T_MEDIATOR):get_method("skip(System.Object)"), function()
    if cut.replaying or ext.cut_quiet or not cfg.skip_together or not world_shared() then return end
    local id = current_event(mediator())
    if id then
        send_ctrl(string.pack("<Bs1i4", MSG.CUTSCENE, me.chapter, id))
        cut.stats.sent = cut.stats.sent + 1
    end
end, nil)

ext.cut_ctrl = function(_, _, data)
    if not cfg.skip_together or not world_shared() then return end
    local _, chapter, id = string.unpack("<Bs1i4", data)
    if chapter == me.chapter then cut.pending, cut.until_t = id, now() + 5 end
end

-- inside the game's GUI update
ext.cut_gui = function()
    local t = now()
    if cut.pending then
        local m = mediator()
        if t > cut.until_t then
            cut.pending = nil
        elseif m and m:call("get_IsPlayingCutScene") and m:call("get_IsSkippable") and current_event(m) == cut.pending then
            cut.pending, cut.replaying = nil, true
            local ok, done = pcall(m.call, m, "skip(System.Object)", m) -- the caller can't be null
            cut.replaying = false
            if ok and done then
                cut.stats.applied, cut.fade_check = cut.stats.applied + 1, t + 8
                if ext.fade_arm then ext.fade_arm() end
                say("your partner skipped the cutscene")
            end
        end
    end
    -- backstop: the cutscene layer's fade comes back once no cutscene plays (the game does it itself)
    if cut.fade_check and t > cut.fade_check then
        cut.fade_check = nil
        local m, fm = mediator(), sdk.get_managed_singleton("app.FadeManager")
        if fm and m and me.go and not m:call("get_IsPlayingCutScene") and fm:call("isFadeOut", 4) then
            pcall(fm.call, fm, "requestFadeIn", 4, 0.5, nil, nil)
        end
    end
end
end

-------------------------------------------------------------------------------------------------
-- after a game over
-------------------------------------------------------------------------------------------------
-- A game over sends a player back to a checkpoint, behind the partner. When our game has loaded (a
-- retry, a save) it tells the partner; a partner who stayed in this chapter all along answers so and
-- sends its world again, as to a player who joins: story steps (only forward), gimmicks, the item
-- box, recipes and the pickups it made here. A lobby owner whose own game just loaded waits 4 s for
-- that answer before it sends its world, so it never winds a partner who stayed back.
do
local STAYED = 1
local sync = { partner_stayed = false, resync_to = nil, stats = { resyncs = 0 } }
ext.sync = sync

-- may we send `pid` our whole world now?
ext.may_full_sync = function(st_net, pid)
    if sync.resync_to == pid then return true end
    if not (st_net and st_net.is_host) or sync.partner_stayed then return false end
    return now() >= (me.loaded_at or -100) + 4
end

ext.sync_scene = function()
    sync.partner_stayed, sync.resync_to = false, nil
end

-- someone we sent our world to left, or starts afresh (a co-op playthrough): when they're back in this
-- chapter they get the whole world again (story, gimmicks, box, recipes, our pickups here), as on a
-- first join. (A rejoining guest got nothing: the owner still had them down as synced.)
ext.on_peer_left = function(id)
    if gim.full_done_for == id then gim.full_done_for = nil end
    if story.full_done_for == id then story.full_done_for = nil end
    if box.full_done_for == id then box.full_done_for = nil end
    if ext.recipes and ext.recipes.peer == id then ext.recipes.peer = nil end
    if sync.resync_to == id then sync.resync_to = nil end
    sync.pickups_sent = sync.pickups_sent or {}
    sync.pickups_sent[id] = nil
end

-- our pickups in this chapter, once to a partner who gets our whole world
ext.send_pickups = function(to)
    sync.pickups_sent = sync.pickups_sent or {}
    if sync.pickups_sent[to] == me.chapter then return 0 end
    sync.pickups_sent[to] = me.chapter
    local n = 0
    for id in pairs(world.taken) do
        send_ctrl(string.pack("<Bs1s1", MSG_ITEM_TAKEN, me.chapter, id), to)
        n = n + 1
    end
    return n
end

ext.loaded_ctrl = function(from, _, data)
    if not world_shared() then return end
    local _, chapter, flag = string.unpack("<Bs1B", data)
    if chapter ~= me.chapter or me.go == nil then return end
    if flag == STAYED then
        sync.partner_stayed = true
        return
    end
    if now() - (me.loaded_at or -100) < 10 then return end -- we've just loaded too
    sync.resync_to = from
    sync.stats.resyncs = sync.stats.resyncs + 1
    gim.full_done_for, story.full_done_for, box.full_done_for = nil, nil, nil
    if ext.recipes then ext.recipes.peer = nil end
    send_ctrl(string.pack("<Bs1B", MSG.LOADED, me.chapter, STAYED), from)
    if sync.pickups_sent then sync.pickups_sent[from] = nil end
    local n = ext.send_pickups(from)
    say("your partner is back at a checkpoint: sending them this chapter as it is here (%d pickups)", n)
end

-- tell the partner once our game has loaded (up to 10 s, until they're there)
ext.sync_late = function(t_now)
    if me.announce_load == nil or me.go == nil then return end
    if t_now > me.announce_load then
        me.announce_load = nil
        return
    end
    local p = partner_to_follow and partner_to_follow()
    if not world_shared() or p == nil or p.id == LOOPBACK_ID then return end
    me.announce_load = nil
    send_ctrl(string.pack("<Bs1B", MSG.LOADED, me.chapter, 0), p.id)
end
end

-------------------------------------------------------------------------------------------------
-- where the partner is
-------------------------------------------------------------------------------------------------
-- On the game's map (app.UI2500GuiBehavior; open while its GameObject draws): a dot and the name
-- where the partner is, placed from our own icon's GUI position by the offset between us in the
-- world: the floor maps are 20.48 map units (GUI pixels at zoom 1) per metre, x to the right and z
-- down. Over 2.5 m up or down is another floor: the label says which. In play: when the partner's
-- puppet isn't in view, their name and distance where they are, or at the screen's edge toward them.
do
local MAP_SCALE, FLOOR_STEP = 20.48, 2.5
local T_MAP = sdk.typeof("app.UI2500GuiBehavior")
local mark = { map = nil, map_t = 0 }
ext.mark = mark

local function screen_size()
    local ok, s = pcall(imgui.get_display_size)
    if ok and s and s.x > 0 then return s.x, s.y end
    return 1920, 1080
end

local function find_map(t)
    if mark.map == nil and t > mark.map_t then
        mark.map_t = t + 3
        mark.map = world.scene_components(T_MAP)[1]
    end
    return mark.map
end

local function floor_tag(dy)
    if dy > FLOOR_STEP then return " (above)" end
    if dy < -FLOOR_STEP then return " (below)" end
    return ""
end

-- true when the map is open (whether or not the partner could be shown on it)
local function draw_on_map(m, p, ppos, mpos, sw, sh)
    if not m:call("get_GameObject"):call("get_DrawSelf") then return false end
    if m:get_field("_IsWorldMapMode") then return true end
    local g = m:get_field("_PlayerIconControl"):call("get_GlobalPosition")
    local zoom = m:get_field("_ZoomMagnification") or 1
    local d = ppos - mpos
    local x, y = g.x + d.x * MAP_SCALE * zoom, g.y + d.z * MAP_SCALE * zoom
    -- kept inside the map's frame (a rect around its centre)
    local okr, r = pcall(m.get_field, m, "_DisplayRange")
    if okr and r then
        local c, size = r:call("get_GlobalPosition"), r:call("get_Size")
        local hw, hh = size.w / 2 - 14, size.h / 2 - 24
        x, y = math.max(c.x - hw, math.min(c.x + hw, x)), math.max(c.y - hh, math.min(c.y + hh, y))
    end
    x, y = x * sw / 1920, y * sh / 1080
    draw.filled_circle(x, y, 9, 0xFF30A0FF, 16)
    draw.outline_circle(x, y, 10, 0xFF000000, 16)
    local label = p.name .. floor_tag(d.y)
    draw.text(label, x - #label * 3.5, y + 12, 0xFF30A0FF)
    return true
end

local function draw_edge(p, ppos, mpos, sw, sh, why)
    local dist = (ppos - mpos):length()
    local label = string.format("%s  %d m%s%s", p.name, math.floor(dist + 0.5), floor_tag(ppos.y - mpos.y), why)
    local sp = draw.world_to_screen(ppos + Vector3f.new(0, 1.0, 0))
    if sp and sp.x > 40 and sp.x < sw - 40 and sp.y > 40 and sp.y < sh - 40 then
        draw.text(label, sp.x - #label * 3.5, sp.y, 0xC0FFFFFF)
        return
    end
    local cam = sdk.get_primary_camera():call("get_GameObject"):call("get_Transform")
    local rot = cam:call("get_Rotation")
    local d = ppos - cam:call("get_Position")
    local a = math.atan(d:dot(rot * Vector3f.new(1, 0, 0)), d:dot(rot * Vector3f.new(0, 0, -1)))
    local x = sw / 2 + math.sin(a) * (sw / 2 - 90)
    local y = sh / 2 - math.cos(a) * (sh / 2 - 50)
    draw.filled_circle(x, y, 7, 0xFF30A0FF, 12)
    draw.text(label, math.max(4, math.min(sw - #label * 7 - 4, x - #label * 3.5)), y + 10, 0xFF30A0FF)
end

ext.mark_draw = function()
    if not cfg.partner_marker or me.go == nil then return end
    local t = now()
    local sw, sh = screen_size()
    local mpos = me.go:call("get_Transform"):call("get_Position")
    local m = find_map(t)
    for _, p in pairs(peers) do
        local s = p.snaps[#p.snaps]
        if s and p.chapter == me.chapter and t - p.last < 3 then
            -- where the puppet stands (the self test's echo is placed off our own position)
            local pup = p.puppet
            local ready = pup and pup.state == "ready" and pup.root
            local ppos = ready and pup.root:call("get_Transform"):call("get_Position") or s.pos
            local open = false
            if m then
                local okm, o = pcall(draw_on_map, m, p, ppos, mpos, sw, sh)
                if okm then open = o else mark.map = nil end
            end
            local in_view = ready and pup.visible and (ppos - mpos):length() < 25
            if not open and not in_view then
                local cutscene = p.flags and p.flags & FLAG_CUTSCENE ~= 0
                pcall(draw_edge, p, ppos, mpos, sw, sh, cutscene and "  (cutscene)" or "")
            end
        end
    end
end

ext.mark_scene = function()
    mark.map, mark.map_t = nil, 0
end
end

-------------------------------------------------------------------------------------------------
-- enemy drops
-------------------------------------------------------------------------------------------------
-- What an enemy leaves when it dies (ItemManager.requestGenerateItem with ReliefCh, made in the game
-- of the player who runs that enemy) is made in the partner's game too, at the same spot; the
-- partner's copy of the enemy drops nothing of its own (its IsPermitedItemDropnOnDead is cleared
-- before it dies there). Picking one up takes the partner's copy away, unless each player picks up
-- their own: generated items have per-PC IDs, so they're matched by item and place (1.5 m). The
-- amount data is a copy of one of our own stocks (PanelState.deployAmountData) given the item and
-- count: app.ItemAmountData can't be created from Lua.
do
local SIG_GEN = "requestGenerateItem(app.ItemAmountData, via.Position, via.Quaternion, app.ItemGenerateRequestType, System.Action`1<app.ItemContext>, System.Action`1<app.ItemCore>)"
local T_ITEM_CORE = sdk.typeof("app.ItemCore")
local drops = { applying = false, relief = nil, stats = { sent = 0, made = 0, taken = 0 } }
ext.drops = drops

local function relief()
    if drops.relief == nil then
        drops.relief = sdk.find_type_definition("app.ItemGenerateRequestType"):get_field("ReliefCh"):get_data(nil) or false
    end
    return drops.relief or nil
end

local function is_relief(obj_or_addr)
    local r = relief()
    if r == nil or obj_or_addr == nil then return false end
    local a = type(obj_or_addr) == "number" and obj_or_addr or obj_or_addr:get_address()
    return a == r:get_address()
end

local function share()
    return cfg.share_drops and world_shared()
end

sdk.hook(sdk.find_type_definition("app.ItemManager"):get_method(SIG_GEN), function(args)
    if drops.applying or not share() or not is_relief(sdk.to_int64(args[6])) then return end
    local a = sdk.to_managed_object(args[3])
    local okp, pos = pcall(sdk.to_valuetype, args[4], "via.Position")
    if a == nil or not okp or pos == nil then return end
    local item = a:get_field("_ItemID")
    local okc, count = pcall(a.get_field, a, "_Stock")
    if type(item) ~= "string" then return end
    send_ctrl(string.pack("<Bs1s1i4ddd", MSG.DROP, me.chapter, item, okc and count or 1,
        pos:get_field("x"), pos:get_field("y"), pos:get_field("z")))
    drops.stats.sent = drops.stats.sent + 1
end, nil)

sdk.hook(sdk.find_type_definition("app.ItemCore"):get_method("notifyPickupped(System.Boolean)"), function(args)
    if drops.applying or not share() or cfg.pickups_for_both or (sdk.to_int64(args[3]) & 1) == 0 then return end
    local core = sdk.to_managed_object(args[2])
    local ok, gt = pcall(core.get_field, core, "_GenerateType")
    if not ok or not is_relief(gt) then return end
    local name = core:call("get_ItemID"):get_field("_Name")
    local p = core:call("get_GameObject"):call("get_Transform"):call("get_Position")
    send_ctrl(string.pack("<Bs1s1ddd", MSG.DROP_TAKEN, me.chapter, name, p.x, p.y, p.z))
end, nil)

-- an ItemAmountData to fill in: a copy of the first stock in our hands
local function amount_data()
    local m = sdk.get_managed_singleton("app.InventoryManager")
    local d = m and m:get_field("_Inventories")
    local n = d and d:get_field("_count") or 0
    for i, e in ipairs(elements(d and d:get_field("_entries")) or {}) do
        if i > n then break end
        local inv = (e:get_field("hashCode") or -1) >= 0 and e:get_field("value") or nil
        local k = inv and inv:get_field("_InventoryKey")
        if k and k:get_field("_BoardType") == 0 and not k:get_field("_IsTemporal") then
            local st = (elements(inv:call("getPanelStates")) or {})[1]
            if st then return st:call("deployAmountData") end
        end
    end
    return nil
end

local function make_drop(item, count, x, y, z)
    local f = sdk.find_type_definition("app.ItemID"):get_field(item)
    local id = f and f:get_data(nil)
    local a = id and amount_data()
    if a == nil then return end
    a:call("set_ItemID", id)
    pcall(a.set_field, a, "_Stock", count)
    local pos = ValueType.new(sdk.find_type_definition("via.Position"))
    pos:set_field("x", x)
    pos:set_field("y", y)
    pos:set_field("z", z)
    local im = sdk.get_managed_singleton("app.ItemManager")
    drops.applying = true
    local ok = pcall(im.call, im, SIG_GEN, a, pos, Quaternion.new(1, 0, 0, 0), relief(), nil, nil)
    drops.applying = false
    if ok then drops.stats.made = drops.stats.made + 1 end
end

local function take_drop(item, x, y, z)
    local at = Vector3f.new(x, y, z)
    for _, core in ipairs(world.scene_components(T_ITEM_CORE)) do
        local ok, gt = pcall(core.get_field, core, "_GenerateType")
        if ok and is_relief(gt) and core:call("get_ItemID"):get_field("_Name") == item then
            local p = core:call("get_GameObject"):call("get_Transform"):call("get_Position")
            local ctx = core:get_field("_Context")
            if (p - at):length() < 1.5 and ctx and ctx:call("get_IsSpawn") then
                drops.applying = true
                pcall(ctx.call, ctx, "set_IsSpawn", false)
                drops.applying = false
                drops.stats.taken = drops.stats.taken + 1
                return
            end
        end
    end
end

ext.drops_ctrl = function(_, kind, data)
    if not share() then return end
    if kind == MSG.DROP then
        local _, chapter, item, count, x, y, z = string.unpack("<Bs1s1i4ddd", data)
        if chapter == me.chapter then ext.later(function() make_drop(item, count, x, y, z) end) end
    else
        local _, chapter, item, x, y, z = string.unpack("<Bs1s1ddd", data)
        if chapter == me.chapter then ext.later(function() take_drop(item, x, y, z) end) end
    end
end
end

-------------------------------------------------------------------------------------------------
-- the game's world as data
-------------------------------------------------------------------------------------------------
-- The save data objects the game's save handlers create (what a save holds: story flows, gimmicks, items
-- picked up, enemies, events seen...) to a plain table and back, so one game's world can be loaded by
-- another (see the co-op playthrough). Same game build on both sides.
-- Non-reference data (numbers, enums, structs without references) is copied as raw bytes (field offsets
-- from the type info; array elements from 0x20); strings and references are set through set_field so the
-- engine's reference counting stays right.
ext.worldx = (function()
local W = {}

local function skip_type_name(n)
    return n == "System.Type" or n == "System.RuntimeType" or n:find("Comparer", 1, true) or n:find("^via%.threading%.")
        or n:find("^System%.Action") or n:find("^System%.Func") or n:find("Delegate", 1, true) or n:find("EventHandler", 1, true)
        or n:find("^via%.GameObject") or n:find("^via%.Component") or n:find("^via%.Transform")
end

-- "A`2.Entry[[X, asm, ...],[Y, asm, ...]]" (an array's element name) -> "A`2.Entry<X,Y>"
local function normalize(name)
    local i, n = 1, #name
    local function parse_args()
        local args = {}
        i = i + 1 -- the outer "["
        while i <= n and name:sub(i, i) == "[" do
            i = i + 1
            local parts, start = {}, i
            while i <= n do
                local c = name:sub(i, i)
                if c == "[" and name:sub(i + 1, i + 1) == "[" then
                    parts[#parts + 1] = name:sub(start, i - 1)
                    parts[#parts + 1] = parse_args()
                    start = i
                elseif c == "]" then
                    parts[#parts + 1] = name:sub(start, i - 1)
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            local a = table.concat(parts):gsub(",%s*[%w%.]+,%s*Version=[^,%]]*,%s*Culture=[^,%]]*,%s*PublicKeyToken=%w+", "")
            args[#args + 1] = (a:gsub("^%s+", ""):gsub("%s+$", ""))
            if name:sub(i, i) == "," then i = i + 1 end
        end
        i = i + 1 -- the outer "]"
        return "<" .. table.concat(args, ",") .. ">"
    end
    local out = {}
    while i <= n do
        if name:sub(i, i + 1) == "[[" then
            out[#out + 1] = parse_args()
        else
            out[#out + 1] = name:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end
W.normalize = normalize

local PRIM = { ["System.Boolean"] = true, ["System.Byte"] = true, ["System.SByte"] = true, ["System.Int16"] = true,
    ["System.UInt16"] = true, ["System.Int32"] = true, ["System.UInt32"] = true, ["System.Int64"] = true,
    ["System.UInt64"] = true, ["System.Single"] = true, ["System.Double"] = true, ["System.Char"] = true,
    ["System.IntPtr"] = true, ["System.UIntPtr"] = true }

local blit_cache = {}
local function blittable(td)
    local n = td:get_full_name()
    local b = blit_cache[n]
    if b ~= nil then return b end
    blit_cache[n] = true
    b = true
    for _, f in ipairs(td:get_fields()) do
        if not f:is_static() then
            local ft = f:get_type()
            if not (PRIM[ft:get_full_name()] or ft:is_enum() or (ft:is_value_type() and blittable(ft))) then b = false break end
        end
    end
    blit_cache[n] = b
    return b
end

-- "p" raw bytes (numbers, enums, structs without references), "s" string, "v" struct with references, "r" reference
local function kind_of(ft)
    local fn = ft:get_full_name()
    if PRIM[fn] or ft:is_enum() then return "p" end
    if fn == "System.String" then return "s" end
    if ft:is_value_type() then return blittable(ft) and "p" or "v" end
    return "r"
end
W.kind_of = kind_of

local size_cache = {}
local function vsize(td)
    local n = td:get_full_name()
    local s = size_cache[n]
    if s == nil then
        s = td:get_valuetype_size()
        size_cache[n] = s
    end
    return s
end

local HEX = {}
for b = 0, 255 do HEX[b] = string.format("%02x", b) end

-- raw bytes of `o` at [off, off + size) as hex
local function read_hex(o, off, size)
    local t = {}
    local i = 0
    while i + 8 <= size do
        local s = string.pack("<i8", o:read_qword(off + i))
        for k = 1, 8 do t[#t + 1] = HEX[s:byte(k)] end
        i = i + 8
    end
    while i < size do
        t[#t + 1] = HEX[o:read_byte(off + i) & 0xFF]
        i = i + 1
    end
    return table.concat(t)
end
local function write_hex(o, off, hex)
    local size = #hex // 2
    local i = 0
    while i + 8 <= size do
        local s = hex:sub(i * 2 + 1, i * 2 + 16):gsub("..", function(h) return string.char(tonumber(h, 16)) end)
        o:write_qword(off + i, (string.unpack("<i8", s)))
        i = i + 8
    end
    while i < size do
        o:write_byte(off + i, tonumber(hex:sub(i * 2 + 1, i * 2 + 2), 16))
        i = i + 1
    end
end
W.read_hex, W.write_hex = read_hex, write_hex

local ARRAY_DATA = 0x20

-- classes used as named constants (static fields holding instances of the class itself, like
-- GameDifficultyID.ID0030): such an object is sent by the static's name and is that same static on
-- the other side (a copy would be another object: lookups by identity would miss it)
local statics_cache = {}
local function static_names(td)
    local n = td:get_full_name()
    local m = statics_cache[n]
    if m then return m end
    m = {}
    local t = td
    while t and t:get_full_name() ~= "System.Object" do
        for _, f in ipairs(t:get_fields()) do
            if f:is_static() and f:get_type():get_full_name() == n then
                local ok, v = pcall(f.get_data, f, nil)
                if ok and type(v) == "userdata" then m[v:get_address()] = f:get_name() end
            end
        end
        t = t:get_parent_type()
    end
    statics_cache[n] = m
    return m
end

function W.encode(roots)
    local types, type_idx = {}, {}
    local descs = {}  -- type index -> { {name, kind, field type index, offset}, ... }
    local nodes, node_of = {}, {}
    local function tidx(td)
        local n = td:get_full_name()
        local i = type_idx[n]
        if i then return i end
        types[#types + 1] = n
        i = #types
        type_idx[n] = i
        return i
    end
    -- instance fields (base types first); offsets from the object start (objects) or the data (structs)
    local function desc(td, is_struct)
        local i = tidx(td)
        if descs[i] then return descs[i], i end
        local d = {}
        descs[i] = d
        local chain, t = {}, td
        while t and t:get_full_name() ~= "System.Object" and t:get_full_name() ~= "System.ValueType" do
            chain[#chain + 1] = t
            t = t:get_parent_type()
        end
        for c = #chain, 1, -1 do
            for _, f in ipairs(chain[c]:get_fields()) do
                if not f:is_static() then
                    local ft = f:get_type()
                    if not skip_type_name(ft:get_full_name()) then
                        local off = is_struct and f:get_offset_from_fieldptr() or f:get_offset_from_base()
                        d[#d + 1] = { f:get_name(), kind_of(ft), tidx(ft), off }
                    end
                end
            end
        end
        return d, i
    end
    local enc_obj
    local function tdi(i) return sdk.find_type_definition(normalize(types[i])) end
    -- a struct with references: `src` is a ValueType (data at 0) or a boxed struct (data at 0x10)
    local function enc_struct(src, base, std)
        local d = desc(std, true)
        local out = {}
        for k, fd in ipairs(d) do
            local kind = fd[2]
            if kind == "p" then
                out[k] = read_hex(src, base + fd[4], vsize(tdi(fd[3])))
            else
                local okf, v = pcall(src.get_field, src, fd[1])
                if not okf or v == nil then out[k] = false
                elseif kind == "v" then out[k] = enc_struct(v, 0, tdi(fd[3]))
                elseif kind == "s" then out[k] = type(v) == "userdata" and v:call("ToString") or tostring(v)
                else out[k] = type(v) == "userdata" and enc_obj(v) or false end
            end
        end
        return out
    end
    enc_obj = function(o)
        local addr = o:get_address()
        if node_of[addr] then return node_of[addr] end
        local td = o:get_type_definition()
        local tn = td:get_full_name()
        if skip_type_name(tn) then return false end
        local node = {}
        nodes[#nodes + 1] = node
        local id = #nodes
        node_of[addr] = id
        node[1] = tidx(td)
        if not td:is_value_type() and tn:sub(-2) ~= "[]" then
            local sn = static_names(td)[addr]
            if sn then
                node[2], node[3] = "S", sn
                return id
            end
        end
        if tn:sub(-2) == "[]" then
            local etd = sdk.find_type_definition(normalize(tn:sub(1, -3)))
            local len = o:call("get_Length")
            if etd == nil then node[2] = "a?" return id end
            local ek = kind_of(etd)
            node[2], node[3], node[4], node[5] = "a", ek, tidx(etd), len
            if ek == "p" then
                node[6] = read_hex(o, ARRAY_DATA, len * vsize(etd))
            elseif ek == "v" then
                local items = {}
                for i = 0, len - 1 do
                    local okv, b = pcall(o.call, o, "GetValue(System.Int32)", i)
                    items[i + 1] = (okv and b) and enc_struct(b, 0x10, etd) or false
                end
                node[6] = items
            else
                local items = {}
                for i = 0, len - 1 do
                    local okv, v = pcall(o.call, o, "GetValue(System.Int32)", i)
                    if not okv or v == nil then items[i + 1] = false
                    elseif ek == "s" then items[i + 1] = v:call("ToString")
                    else items[i + 1] = enc_obj(v) end
                end
                node[6] = items
            end
            return id
        end
        local d = desc(td, false)
        local vals = {}
        for k, fd in ipairs(d) do
            local kind = fd[2]
            if kind == "p" then
                vals[k] = read_hex(o, fd[4], vsize(tdi(fd[3])))
            elseif kind == "v" then
                local okf, v = pcall(o.get_field, o, fd[1])
                vals[k] = (okf and v) and enc_struct(v, 0, tdi(fd[3])) or false
            else
                local okf, v = pcall(o.get_field, o, fd[1])
                if not okf or v == nil then vals[k] = false
                elseif kind == "s" then vals[k] = type(v) == "userdata" and v:call("ToString") or tostring(v)
                else vals[k] = type(v) == "userdata" and enc_obj(v) or false end
            end
        end
        node[2] = vals
        return id
    end
    local root_ids = {}
    for key, obj in pairs(roots) do root_ids[key] = enc_obj(obj) end
    local dl = {}
    for i, d in pairs(descs) do dl[#dl + 1] = { i, d } end
    return { v = 2, types = types, descs = dl, nodes = nodes, roots = root_ids }
end

function W.decode(data)
    local types = data.types
    local descs = {}
    for _, e in ipairs(data.descs) do descs[e[1]] = e[2] end
    local tds = {}
    local function td_of(i)
        local t = tds[i]
        if t == nil then
            t = sdk.find_type_definition(normalize(types[i])) or false
            tds[i] = t
        end
        return t or nil
    end
    local objs, missing = {}, {}
    for id, node in ipairs(data.nodes) do
        if node[2] == "a" then
            local arr = sdk.create_managed_array(normalize(types[node[4]]), node[5])
            if arr then objs[id] = arr:add_ref() else missing[#missing + 1] = types[node[1]] end
        elseif node[2] == "S" then
            local td = td_of(node[1])
            local f = td and td:get_field(node[3])
            local ok, v = pcall(function() return f:get_data(nil) end)
            if ok and v then objs[id] = v else missing[#missing + 1] = types[node[1]] .. "." .. tostring(node[3]) end
        elseif node[2] ~= "a?" then
            local o = sdk.create_instance(normalize(types[node[1]]))
            if o then objs[id] = o:add_ref() else missing[#missing + 1] = types[node[1]] end
        end
    end
    -- a struct with references as a ValueType
    local function build_struct(ti, vals)
        local std = td_of(ti)
        local vt = ValueType.new(std)
        local d = descs[ti] or {}
        for k, fd in ipairs(d) do
            local v = vals[k]
            if fd[2] == "p" then
                if v then write_hex(vt, fd[4], v) end
            elseif fd[2] == "v" then
                if v then pcall(vt.set_field, vt, fd[1], build_struct(fd[3], v)) end
            elseif fd[2] == "s" then
                if v then pcall(vt.set_field, vt, fd[1], sdk.create_managed_string(v)) end
            else
                if v then pcall(vt.set_field, vt, fd[1], objs[v]) end
            end
        end
        return vt
    end
    for id, node in ipairs(data.nodes) do
        local o = objs[id]
        if o and node[2] ~= "S" then
            if node[2] == "a" then
                local ek, eti, len, items = node[3], node[4], node[5], node[6]
                if ek == "p" then
                    if len > 0 then write_hex(o, ARRAY_DATA, items) end
                elseif ek == "v" then
                    for i = 0, len - 1 do
                        if items[i + 1] then
                            local vt = build_struct(eti, items[i + 1])
                            pcall(function() o[i] = vt end)
                        end
                    end
                else
                    for i = 0, len - 1 do
                        local v = items[i + 1]
                        if v then
                            local x = ek == "s" and sdk.create_managed_string(v) or objs[v]
                            if x then pcall(function() o[i] = x end) end
                        end
                    end
                end
            else
                local d = descs[node[1]] or {}
                local vals = node[2]
                for k, fd in ipairs(d) do
                    local v = vals[k]
                    if fd[2] == "p" then
                        if v then write_hex(o, fd[4], v) end
                    elseif fd[2] == "v" then
                        if v then pcall(o.set_field, o, fd[1], build_struct(fd[3], v)) end
                    elseif fd[2] == "s" then
                        pcall(o.set_field, o, fd[1], v and sdk.create_managed_string(v) or nil)
                    else
                        pcall(o.set_field, o, fd[1], v and objs[v] or nil)
                    end
                end
            end
        end
    end
    local roots = {}
    for key, id in pairs(data.roots) do roots[key] = id and objs[id] or nil end
    return roots, missing, objs
end

return W
end)()

-------------------------------------------------------------------------------------------------
-- the guest's co-op playthrough
-------------------------------------------------------------------------------------------------
-- A guest who brings their own save into the host's world clashes with it: their story, chapter and
-- item box are their own (a guest from Chap4 jumped back into Chap3_02 got a black screen, and their
-- item box went into the host's). With "Join as a co-op playthrough" (on by default) the guest joins
-- from the main menu: their game starts a new game right in the host's chapter on the host's
-- difficulty (GameDifficultyManager.setNewGameDifficulty, TitleFlowController.onNewGame, then
-- MainGameFlowManager.setNewGameSceneName: onNewGame sets it back to Chap1_00; the scene loads after
-- the fade), and the host's world comes in as on any join (story, locks, puzzles, item box, recipes).
-- While it lasts the guest's game saves nothing into game slots (save requests are skipped; the
-- system slot with settings and achievements still saves), so their own saves are never touched.
-- What the guest carries (both characters' hands: items, the ammo in guns, money, the pouch level,
-- equipped weapons and shortcuts) is kept by the mod in re9coop_coop_<host's Steam ID>.json, written
-- when the host's game saves, every 2 minutes and when the guest leaves, and put back the next time
-- they join that host; the first time they get a copy of what the host carries. A guest who joins
-- while playing their own save is asked to go to the main menu first; until then nothing of the two
-- worlds is shared.
-- The host's world: the host's game also sends its whole world as save data (every save handler's
-- createGameSlotSavedata, through ext.worldx, ~0.7 MB in 60 KB pieces): what a save of it would hold
-- now (story, gimmicks, items taken, enemies, events seen, the chapter and the spot it's at), but not
-- the inventories (the guest's own things are put in their hands, the box is the host's through the box
-- sync), achievements or the flashlight settings. A guest with a save of their own loads it ("Continue")
-- while every handler's restoreGameSlotSavedata gets the host's data instead: their game comes up in
-- the host's world, at the host's spot, as if it were their save (their save file is only read). A
-- guest without a save gets the new game in the host's chapter. The host sends its world again each
-- time it saves; a load in the co-op playthrough (a game over, "Restart") loads the host's last world
-- the same way.
-- (a function of its own: the main chunk is at Lua's limit of 200 locals)
;(function()
local T_TITLE = sdk.typeof("app.TitleFlowController")
local T_DIFFICULTY = sdk.find_type_definition("app.GameDifficultyID")
local T_EQUIP = sdk.find_type_definition("app.InventoryEquipSlot")
local T_SHORTCUT = sdk.find_type_definition("app.InventoryShortcutSlot")
local EQUIP = { "Primary", "Secondary" }
local SHORTCUTS = { "Equip_Up", "Equip_Up2", "Equip_Down", "Equip_Down2", "Equip_Left", "Equip_Left2", "Equip_Right", "Equip_Right2" }
local PLAY_START, PLAY_KIT, PLAY_WORLD = 1, 2, 3
-- not taken from the host's world: inventories (the guest's own things), achievements, flashlight settings
local WORLD_KEEP = { InventoryManager = true, AchievementManager = true, LayeredParamManager = true }
local WORLD_CHUNK = 60000
local CAT_SYSTEM = 1 -- app.SaveSlotCategory.System
local title_controller -- below
local fresh = {
    active = false,     -- in a co-op playthrough: our game slots don't save
    phase = nil,        -- "asked" (the host's chapter), "starting", "arrived", "await_kit", "playing"
    host = nil, chapter = nil, t = 0, title_t = 0, title = false, saved_t = 0,
    fade_since = nil, fade_t = 0,
    world = nil,        -- the host's world, decoded: save handler key -> save data object
    world_on = false,   -- the save handlers' restores get the host's world
    world_tag = 0, out = nil, parts = nil, subs = 0, via = nil,
}
ext.fresh = fresh

-- the game's save handlers: key -> handler object
local function save_handlers()
    local ssm = sdk.get_managed_singleton("app.SaveServiceManager")
    local d = ssm and ssm:get_field("_GameSlotSaveHandlers")
    local n = d and d:get_field("_count") or 0
    local out = {}
    for i, e in ipairs(elements(d and d:get_field("_entries")) or {}) do
        if i > n then break end
        if (e:get_field("hashCode") or -1) >= 0 then out[e:get_field("key")] = e:get_field("value"):get_field("_Handler") end
    end
    return out
end

-- our world as the save handlers would save it now, encoded (inside the game's GUI update)
local function world_blob()
    local roots = {}
    for key, h in pairs(save_handlers()) do
        if not WORLD_KEEP[key] then
            local args = sdk.create_instance("app.GameSlotSaveEventArgs")
            local m = h:get_type_definition():get_method("app.IGameSlotSaveHandler.createGameSlotSavedata(app.GameSlotSaveEventArgs)")
            if args and m then
                args:call("set_KeyName", key)
                local ok, data = pcall(m.call, m, h, args)
                if ok and data then roots[key] = data end
            end
        end
    end
    return json.dump_string(ext.worldx.encode(roots))
end

-- send our world to `to` (a few pieces a frame; a piece Steam can't take yet is tried again)
local function send_world(to)
    ext.later(function()
        local ok, blob = pcall(world_blob)
        if not ok then say("couldn't pack the world: %s", tostring(blob)) return end
        fresh.world_tag = (fresh.world_tag % 60000) + 1
        local chunks = {}
        for i = 1, #blob, WORLD_CHUNK do chunks[#chunks + 1] = blob:sub(i, i + WORLD_CHUNK - 1) end
        fresh.out = { to = to, tag = fresh.world_tag, chunks = chunks, next = 1, size = #blob }
    end)
end
ext.fresh_send_world = send_world

local function pump_world()
    local o = fresh.out
    if o == nil or net == nil then return end
    for _ = 1, 2 do
        local c = o.chunks[o.next]
        if c == nil then
            fresh.out = nil
            say("sent your world to your partner (%d KB)", o.size // 1024)
            return
        end
        local n = net.send(string.pack("<BI2I2I2s4", MSG.WORLD, o.tag, o.next, #o.chunks, c), true, CH_CTRL, o.to)
        if (n or 0) <= 0 then return end -- Steam's queue is full: this piece again next frame
        o.next = o.next + 1
    end
end

-- does this game have a save to load ("Continue")?
local function has_own_save()
    local ssm = sdk.get_managed_singleton("app.SaveServiceManager")
    local d = ssm and ssm:get_field("_SaveSlotInfoDict")
    local n = d and d:get_field("_count") or 0
    for i, e in ipairs(elements(d and d:get_field("_entries")) or {}) do
        if i > n then break end
        local k = (e:get_field("hashCode") or -1) >= 0 and e:get_field("key")
        if k and (k:get_field("_SlotId") or -1) >= 0 then return true end
    end
    return false
end

-- every save handler's restore takes the host's world instead while fresh.world_on (hooked once the
-- handlers exist)
local function hook_restores()
    if fresh.restores_hooked then return end
    local hs = save_handlers()
    if next(hs) == nil then return end
    fresh.restores_hooked = true
    for key, h in pairs(hs) do
        local m = h:get_type_definition():get_method("app.IGameSlotSaveHandler.restoreGameSlotSavedata(app.SavedataObjectBase, app.GameSlotRestoreEventArgs)")
        if m and not WORLD_KEEP[key] then
            sdk.hook(m, function(args)
                local sub = fresh.world_on and fresh.world and fresh.world[key]
                if sub then
                    args[3] = sdk.to_ptr(sub)
                    fresh.subs = fresh.subs + 1
                end
            end, nil)
        end
    end
end

-- at the main menu: "Continue" with the host's world in place of ours (GUI update)
local function start_world_load()
    local tfc = title_controller()
    if tfc == nil or fresh.world == nil then return false end
    hook_restores()
    fresh.world_on, fresh.subs, fresh.via, fresh.load_go = true, 0, "world", me.go_addr
    tfc:call("onContinue")
    return true
end

title_controller = function()
    local sm = sdk.get_native_singleton("via.SceneManager")
    local scene = sm and sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local list = scene and scene:call("findComponents(System.Type)", T_TITLE)
    local all = elements(list)
    return all and all[1] or nil
end

local function guest_session()
    if _G.re9coop_test_guest then return _G.re9coop_test_guest end -- dev bridge only
    local st = session.status
    if st == nil or st.state ~= "in_lobby" or st.is_host or not st.owner or st.owner == "" or st.owner == st.me then return nil end
    return st
end

-- the guest plays their own save in someone's lobby: nothing is shared until they're in the
-- co-op playthrough
ext.fresh_hold = function()
    return cfg.fresh_join and not fresh.active and guest_session() ~= nil
end

local function static_of(t, name)
    local f = t and t:get_field(name)
    local ok, v = pcall(function() return f and f:get_data(nil) end)
    return ok and v or nil
end

-- our hands, one inventory per character (board type 0)
local function hand_inventories()
    local m = sdk.get_managed_singleton("app.InventoryManager")
    local d = m and m:get_field("_Inventories")
    local n = d and d:get_field("_count") or 0
    local out = {}
    for i, e in ipairs(elements(d and d:get_field("_entries")) or {}) do
        if i > n then break end
        local inv = (e:get_field("hashCode") or -1) >= 0 and e:get_field("value") or nil
        local k = inv and inv:get_field("_InventoryKey")
        local u = k and k:get_field("_User")
        if k and u and k:get_field("_BoardType") == 0 and not k:get_field("_IsTemporal") then
            local ok, name = pcall(u.call, u, "ToString")
            if ok and name then out[name] = inv end
        end
    end
    return out
end

local function position_of(st)
    local p = st and st:call("get_Position")
    return p and (p.x .. "," .. p.y) or nil
end

-- what we carry, for both characters
local function read_kit()
    local kit = {}
    for user, inv in pairs(hand_inventories()) do
        local u = { level = inv:call("get_Level"), money = inv:call("get_Moneys"), panels = {}, equip = {}, shortcuts = {} }
        for _, st in ipairs(elements(inv:call("getPanelStates")) or {}) do
            local e = box.panel_entry(st)
            if e then u.panels[#u.panels + 1] = e end
        end
        for _, s in ipairs(EQUIP) do
            local ok, st = pcall(inv.call, inv, "getEquipPanelState", static_of(T_EQUIP, s), false)
            u.equip[s] = ok and position_of(st) or nil
        end
        for _, s in ipairs(SHORTCUTS) do
            local ok, st = pcall(inv.call, inv, "getShortcutPanelState", static_of(T_SHORTCUT, s), false)
            u.shortcuts[s] = ok and position_of(st) or nil
        end
        kit[user] = u
    end
    return kit
end

-- make our hands hold exactly that (inside the game's GUI update)
local function apply_kit(kit)
    local invs = hand_inventories()
    local n = 0
    for user, u in pairs(kit) do
        local inv = invs[user]
        if inv then
            if u.level then pcall(inv.call, inv, "setLevel", u.level) end
            local money = inv:call("get_Moneys") or 0
            if u.money and u.money ~= money then pcall(inv.call, inv, "mergeMoneys", u.money - money) end
            for _, x in ipairs(box.read_box(inv)) do box.remove_panel(inv, x.key) end
            for _, e in ipairs(u.panels or {}) do
                if box.add_entry(inv, e) then n = n + 1 else say("couldn't put %s in your hands", e:match("^[^|]*")) end
            end
            local at = {}
            for _, st in ipairs(elements(inv:call("getPanelStates")) or {}) do
                local pos = position_of(st)
                if pos then at[pos] = st:call("get_Key") end
            end
            for _, s in ipairs(EQUIP) do
                local pos = (u.equip or {})[s]
                if pos and at[pos] then pcall(inv.call, inv, "setEquip", at[pos], static_of(T_EQUIP, s))
                elseif not pos then pcall(inv.call, inv, "resetEquip", static_of(T_EQUIP, s)) end
            end
            for s, pos in pairs(u.shortcuts or {}) do
                if at[pos] then pcall(inv.call, inv, "setShortcut", at[pos], static_of(T_SHORTCUT, s), false) end
            end
        end
    end
    return n
end

local function kit_file(host)
    return "re9coop_coop_" .. tostring(host) .. ".json"
end

local function store_kit(why)
    if not fresh.active or fresh.host == nil or me.go == nil or fresh.phase ~= "playing" then return end
    local ok, kit = pcall(read_kit)
    if not ok or next(kit) == nil then return end
    fresh.saved_t = now()
    fs.write(kit_file(fresh.host), json.dump_string({ kit = kit, chapter = me.chapter, t = os.time() }))
    if why then say("your things in the co-op playthrough are kept (%s)", why) end
end
ext.fresh_store = store_kit

local function load_kit(host)
    local ok, s = pcall(fs.read, kit_file(host))
    if not ok or s == nil or s == "" then return nil end
    local ok2, d = pcall(json.load_string, s)
    return ok2 and type(d) == "table" and type(d.kit) == "table" and d.kit or nil
end

local function end_playthrough(why)
    if not fresh.active then return end
    fresh.active, fresh.phase = false, nil
    say("co-op playthrough over (%s): your game saves as usual again", why)
end

-- at the main menu: a new game, right in the host's chapter, on the host's difficulty (GUI update)
local function start_new_game(chapter, difficulty)
    local tfc = title_controller()
    local mg = sdk.get_managed_singleton("app.MainGameFlowManager")
    if tfc == nil or mg == nil then return false end
    local dm = sdk.get_managed_singleton("app.GameDifficultyManager")
    local id = static_of(T_DIFFICULTY, difficulty)
    if dm and id then pcall(dm.call, dm, "setNewGameDifficulty", id) end
    tfc:call("onNewGame")
    mg:call("setNewGameSceneName", chapter)
    return true
end

-- game-slot saves are skipped during a co-op playthrough
do
    local T_SSM = sdk.find_type_definition("app.SaveServiceManager")
    local skipped = false
    local function post(retval)
        if skipped then
            skipped = false
            return sdk.to_ptr(0)
        end
        return retval
    end
    for _, sig in ipairs({
        "requestSave(app.SaveSlotCategory, app.SaveSlotSelectionMethod, System.Nullable`1<app.SavedataSaveRequestArgs>)",
        "requestSave(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataSaveRequestArgs>)",
        "requestSaveCore(app.SaveSlotCategory, System.Int32, System.Nullable`1<app.SavedataSaveRequestArgs>)",
        "requestSave(app.SaveSlotIndex, System.Nullable`1<app.SavedataSaveRequestArgs>)",
        "requestSave(app.SaveSlotAddress, System.Nullable`1<app.SavedataSaveRequestArgs>)",
    }) do
        local m = T_SSM:get_method(sig)
        local by_category = sig:find("SaveSlotCategory", 1, true) ~= nil
        if m then
            sdk.hook(m, function(args)
                skipped = false
                if not fresh.active then return end
                if by_category and (sdk.to_int64(args[3]) & 0xFFFFFFFF) == CAT_SYSTEM then return end
                skipped = true
                return sdk.PreHookResult.SKIP_ORIGINAL
            end, post)
        end
    end
    -- a load in the playthrough (game over, "Restart", "Load"): the host's last world comes up again
    -- (without one, the guest's own save loads and the playthrough ends there)
    for _, m in ipairs(T_SSM:get_methods()) do
        if m:get_name() == "requestLoad" then
            sdk.hook(m, function()
                if not fresh.active or fresh.world_on then return end
                pcall(store_kit, "loading")
                if fresh.world then
                    hook_restores()
                    fresh.world_on, fresh.subs, fresh.phase, fresh.t, fresh.load_go = true, 0, "loading_world", now(), me.go_addr
                    say("loading the host's world again")
                    local g = guest_session()
                    if g then send_ctrl(string.pack("<BB", MSG.PLAY_REQ, PLAY_WORLD), g.owner) end
                else
                    fresh.active, fresh.phase = false, nil
                    say("co-op playthrough over: your own last save loads (join from the main menu again)")
                end
            end, nil)
        end
    end
end

-- the screen stayed black after a chapter change (the game's fade wasn't lifted): fade it in
-- (only for 2 minutes after a scene change the mod brought about: a chapter followed, a co-op
-- playthrough started, the partner's cutscene skip; the game's own fades are left alone)
ext.fade_arm = function() fresh.fade_until = now() + 120 end

local function fade_watch(t_now)
    if t_now > (fresh.fade_until or 0) then fresh.fade_since = nil return end
    if t_now < fresh.fade_t then return end
    fresh.fade_t = t_now + 0.5
    local f = sdk.get_managed_singleton("app.FadeManager")
    local gm = sdk.get_managed_singleton("app.GuiManager")
    local paused = gm and gm:call("get_ActiveGuiWithPause")
    if f == nil or me.go == nil or in_cutscene() or paused or not f:call("isAnyFadeOut") then
        fresh.fade_since = nil
        return
    end
    fresh.fade_since = fresh.fade_since or t_now
    if t_now - fresh.fade_since > 20 then
        fresh.fade_since = nil
        ext.later(function()
            for t = 0, 8 do pcall(f.call, f, "requestFadeIn", t, 0.5, nil, nil) end
        end)
        say("the screen stayed black: faded it in")
    end
end

ext.fresh_ctrl = function(from, kind, data)
    local st = session.status
    if kind == MSG.PLAY_REQ then
        -- the lobby owner tells a guest where to start, or gives them a copy of what it carries
        if not ((st and st.is_host) or _G.re9coop_test_owner) or me.go == nil then return end -- (dev bridge: test_owner)
        local _, what = string.unpack("<BB", data)
        if what == PLAY_START then
            if ext.on_peer_left then ext.on_peer_left(from) end -- a new game there: our whole world again
            local dm = sdk.get_managed_singleton("app.GameDifficultyManager")
            local ok, d = pcall(function() return dm:call("get_DifficultyID"):call("ToString") end)
            local chapter = me.chapter:match("^(Chap%d+_%d%d)") or me.chapter
            send_ctrl(string.pack("<Bs1s1", MSG.PLAY, chapter, ok and d or ""), from)
            say("your partner starts a co-op playthrough in %s", chapter)
            send_world(from)
        elseif what == PLAY_WORLD then
            send_world(from)
        elseif what == PLAY_KIT then
            local ok, kit = pcall(read_kit)
            if ok then send_ctrl(string.pack("<Bs4", MSG.KIT, json.dump_string(kit)), from) end
        end
    elseif kind == MSG.PLAY then
        local g = guest_session()
        if fresh.phase ~= "asked" or not (g and from == g.owner) then return end
        local _, chapter, difficulty = string.unpack("<Bs1s1", data)
        fresh.host, fresh.chapter, fresh.play = from, chapter, { chapter, difficulty }
        if has_own_save() then
            fresh.phase, fresh.t = "await_world", now()
            say("getting the host's world...")
            return
        end
        fresh.phase, fresh.t, fresh.via = "starting", now(), "newgame"
        fresh.active = true
        ext.later(function()
            if start_new_game(chapter, difficulty) then
                ext.fade_arm()
                say("starting a co-op playthrough in %s (your own saves aren't touched)", chapter)
            else
                fresh.active, fresh.phase = false, nil
            end
        end)
    elseif kind == MSG.WORLD then
        local g = guest_session()
        if not (g and from == g.owner) then return end
        local _, tag, idx, total, chunk = string.unpack("<BI2I2I2s4", data)
        local pt = fresh.parts
        if pt == nil or pt.tag ~= tag then
            pt = { tag = tag, total = total, got = 0, chunks = {} }
            fresh.parts = pt
        end
        if pt.chunks[idx] == nil then
            pt.chunks[idx], pt.got = chunk, pt.got + 1
        end
        if pt.got < pt.total then return end
        fresh.parts = nil
        local blob = table.concat(pt.chunks)
        ext.later(function()
            local okj, enc = pcall(json.load_string, blob)
            if not okj or type(enc) ~= "table" then say("the host's world didn't arrive whole") return end
            local okd, roots, missing, objs = pcall(ext.worldx.decode, enc)
            if not okd then say("couldn't unpack the host's world: %s", tostring(roots)) return end
            for _, o in ipairs(fresh.world_objs or {}) do pcall(o.release, o) end
            fresh.world, fresh.world_objs = roots, objs
            if #missing > 0 then say("the host's world: %d objects this game doesn't know", #missing) end
            if fresh.phase == "await_world" and me.go == nil then
                fresh.active, fresh.phase, fresh.t = true, "loading_world", now()
                if start_world_load() then
                    ext.fade_arm()
                    say("loading the host's world (%d KB; your own saves aren't touched)", #blob // 1024)
                else
                    fresh.active, fresh.phase = false, nil
                end
            end
        end)
    elseif kind == MSG.KIT then
        if fresh.phase ~= "await_kit" then return end
        local _, s = string.unpack("<Bs4", data)
        local ok, kit = pcall(json.load_string, s)
        if not ok or type(kit) ~= "table" then return end
        fresh.phase = "playing"
        ext.later(function()
            local n = apply_kit(kit)
            say("you start with a copy of what the host carries (%d things)", n)
            store_kit()
        end)
    end
end

-- our game is free: a player, no cutscene, no fade, for 3 s (a fade only counts for the first 30 s
-- after the player shows up: some rooms keep one of the fade layers down for good, and the partner's
-- locks and story then never came in)
ext.settled = function()
    return fresh.calm_since ~= nil and now() - fresh.calm_since >= 3
end

local function skip_cutscene()
    local m = sdk.get_managed_singleton("app.TimelineEventMediator")
    if m == nil or not m:call("get_IsPlayingCutScene") then return end
    fresh.skip_tries = (fresh.skip_tries or 0) + 1
    if not m:call("get_IsSkippable") then return end
    ext.cut_quiet = true
    local ok, done = pcall(m.call, m, "skip(System.Object)", m) -- the caller can't be null
    ext.cut_quiet = false
    if ok and done then
        fresh.skips = (fresh.skips or 0) + 1
        say("skipped the chapter's opening (the host has seen it)")
    end
end

ext.fresh_late = function(t_now)
    pump_world()
    -- the loaded player (not the one still there when the load began)
    if fresh.world_on and me.go ~= nil and me.chapter ~= "" and fresh.phase == "loading_world"
        and (me.go_addr ~= fresh.load_go or t_now - fresh.t > 25) then
        fresh.world_on = false
        fresh.phase, fresh.t = "arrived", t_now
        say("in the host's world (%d parts of it loaded)", fresh.subs)
    end
    if fresh.phase == "await_world" and t_now - fresh.t > 40 and fresh.play then
        -- no world came: the new game in the host's chapter instead
        local play = fresh.play
        fresh.phase, fresh.t, fresh.via, fresh.active = "starting", t_now, "newgame", true
        ext.later(function()
            if start_new_game(play[1], play[2]) then ext.fade_arm() else fresh.active, fresh.phase = false, nil end
        end)
        say("the host's world didn't come: starting in its chapter instead")
    end
    if fresh.phase == "loading_world" and me.go == nil and t_now - fresh.t > 120 then
        fresh.active, fresh.phase, fresh.world_on = false, nil, false
        say("the host's world didn't load: trying again")
    end
    local f = sdk.get_managed_singleton("app.FadeManager")
    local fading = f and f:call("isAnyFadeOut") and t_now - (me.loaded_at or 0) < 30
    local calm = me.go ~= nil and not in_cutscene() and not fading
    if calm then fresh.calm_since = fresh.calm_since or t_now else fresh.calm_since = nil end
    -- a co-op playthrough starts in the middle of the host's chapter: its opening cutscene is skipped
    -- (3 s into it: a skip right as it starts is taken but the cutscene plays on)
    local cut_now = me.go ~= nil and in_cutscene()
    if cut_now then fresh.cut_since = fresh.cut_since or t_now else fresh.cut_since = nil end
    if fresh.active and fresh.via == "newgame" and (fresh.phase == "arrived" or fresh.phase == "starting") and cut_now
        and t_now - fresh.cut_since >= 3 and t_now - fresh.t < 180 and t_now >= (fresh.skip_t or 0) then
        fresh.skip_t = t_now + 1
        ext.later(skip_cutscene)
    end
    if t_now >= fresh.title_t then
        fresh.title_t = t_now + 1
        fresh.title = me.go == nil and title_controller() ~= nil
    end
    -- back at the main menu after playing it (not while the new game is still on its way)
    if fresh.active and fresh.title and fresh.phase ~= "starting" and fresh.phase ~= "loading_world" then
        end_playthrough("back at the main menu")
    end
    if fresh.phase == "starting" and me.go == nil and t_now - fresh.t > 90 then
        fresh.active, fresh.phase = false, nil
        say("the co-op playthrough didn't start: trying again")
    end
    if me.go then pcall(fade_watch, t_now) end
    local st = guest_session()
    if st == nil or not cfg.fresh_join then
        if fresh.active and fresh.phase == "playing" and fresh.left_t == nil then
            fresh.left_t = t_now
            store_kit("you left the session")
        end
        if fresh.phase == "asked" or fresh.phase == "await_world" then fresh.phase = nil end
        return
    end
    fresh.left_t = nil
    if me.go == nil then
        -- at the main menu: ask the host where it is
        if not fresh.active and fresh.title and (fresh.phase == nil or (fresh.phase == "asked" and t_now - fresh.t > 5)) then
            send_ctrl(string.pack("<BB", MSG.PLAY_REQ, PLAY_START), st.owner)
            fresh.phase, fresh.t = "asked", t_now
        end
        return
    end
    if not fresh.active then return end
    if fresh.phase == "starting" and me.chapter ~= "" then
        fresh.phase, fresh.t = "arrived", t_now
    elseif fresh.phase == "arrived" and ext.settled() then
        local kit = load_kit(fresh.host)
        if kit then
            fresh.phase = "playing"
            ext.later(function()
                local n = apply_kit(kit)
                say("your things from the last co-op session are back (%d)", n)
                fresh.saved_t = now()
            end)
        else
            send_ctrl(string.pack("<BB", MSG.PLAY_REQ, PLAY_KIT), fresh.host)
            fresh.phase, fresh.t = "await_kit", t_now
        end
    elseif fresh.phase == "await_kit" and t_now - fresh.t > 10 then
        send_ctrl(string.pack("<BB", MSG.PLAY_REQ, PLAY_KIT), fresh.host)
        fresh.t = t_now
    elseif fresh.phase == "playing" and t_now - fresh.saved_t > 120 then
        pcall(store_kit)
    end
end

ext.fresh_draw = function()
    local msg
    if fresh.phase == "await_world" then
        local pt = fresh.parts
        msg = pt and string.format("Getting the host's world... %d%%", pt.got * 100 // math.max(1, pt.total))
            or "Getting the host's world..."
    elseif fresh.phase == "loading_world" then
        msg = "Loading the host's world..."
    elseif fresh.phase == "asked" or fresh.phase == "starting" then
        msg = "Starting the co-op playthrough in the host's chapter..."
    elseif ext.fresh_hold() and me.go then
        msg = "You're in the host's lobby with your own save: go to the main menu (Esc > Quit), the co-op playthrough starts there. Your own save isn't touched."
    end
    if msg then draw.text(msg, 960 - #msg * 3.5, 80, 0xFF80FFFF) end
end

-- dev
fresh.read_kit, fresh.apply_kit, fresh.start_new_game, fresh.load_kit = read_kit, apply_kit, start_new_game, load_kit
fresh.world_blob, fresh.start_world_load, fresh.hook_restores = world_blob, start_world_load, hook_restores
end)()

-------------------------------------------------------------------------------------------------
-- sync check
-------------------------------------------------------------------------------------------------
-- What the two games share, compared (the test oracle the co-op playbook asks for: snapshots of
-- shared state from both clients, diffed). Either player asks ("Check sync with partner" in the menu,
-- and the guest by itself a minute after joining and every 5 minutes); the other answers with a
-- digest of its world: story flows, every gimmick's logical fields, the items lying about, the
-- enemies (spawned, dead, HP, where) and how its copy of us is doing. The asking side builds its own,
-- compares, says the counts and writes the details to reframework/data/re9coop_sync_report.txt
-- (the file to send when something looks wrong).
;(function()
local check = { next_auto = nil, waiting = nil, last = nil }
ext.check = check

local function round(v) return math.floor(v * 2 + 0.5) / 2 end

-- our side, as plain data (inside the game's GUI update: gimmick states come from store())
local function digest()
    local d = { chapter = me.chapter, t = os.time(), flows = {}, gims = {}, items = {}, foes = {}, puppets = {} }
    if me.go then
        local p = me.go:call("get_Transform"):call("get_Position")
        d.pos = { round(p.x), round(p.y), round(p.z) }
    end
    for hash, value in pairs(story.flows() or {}) do d.flows[tostring(hash)] = value end
    for _, gc in ipairs(gim.contexts_of(now()) or {}) do
        local id = gim.id_of(gc)
        if id then
            local ok, _, sig = pcall(gim.state_of, gc)
            if ok and sig then d.gims[id] = sig end
        end
    end
    world.refresh(now())
    for id, core in pairs(world.items or {}) do
        local ok, spawned = pcall(function() return core:get_field("_Context"):call("get_IsSpawn") end)
        if ok then d.items[id] = spawned and 1 or 0 end
    end
    -- the game's own enemy list (the mod's index only fills while enemies are shared)
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local list = cm and cm:call("get_EnemyContextList")
    local all = {}
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local ctx = list:call("get_Item", i)
        local okid, id = pcall(function() return ctx:call("get_ID"):call("ToString") end)
        local okk, kind = pcall(function() return ctx:call("get_KindID"):call("ToString") end)
        if okid and id then all[id] = { ctx = ctx, kind = okk and kind or "?" } end
    end
    for id, e in pairs(all) do
        local f = { k = e.kind }
        local ok = pcall(function()
            f.s = e.ctx:call("get_IsSpawn") and 1 or 0
            f.d = e.ctx:call("get_IsDead") and 1 or 0
            local hp = e.ctx:call("get_HitPoint")
            f.hp = hp and hp:call("get_CurrentHitPoint") or nil
            local go = f.s == 1 and e.ctx:call("get_GameObject")
            if go then
                local p = go:call("get_Transform"):call("get_Position")
                f.p = { round(p.x), round(p.y), round(p.z) }
            end
            f.o = foes.owner[id] == false and "partner" or "us"
        end)
        if ok then d.foes[id] = f end
    end
    -- how our copies of the other player(s) are doing (animations reach us?)
    for pid, p in pairs(peers) do
        if pid ~= LOOPBACK_ID then
            local pup = p.puppet
            local matched, total = 0, 0
            for _, j in ipairs(pup and pup.jmap or {}) do
                total = total + 1
                if j then matched = matched + 1 end
            end
            local last = p.snaps[#p.snaps]
            d.puppets[pid] = { name = p.name, state = pup and pup.state or "none", visible = pup and pup.visible or false,
                joints = total, matched = matched, names = p.appear and #(p.appear.names or {}) or 0,
                sent_joints = last and #last.j or 0, snaps = #p.snaps, age = string.format("%.1f", now() - (p.last or 0)),
                chapter = p.chapter }
        end
    end
    d.my_joints = me.joints and #me.joints or 0
    return d
end

local function n_keys(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-- compare ours (a) with theirs (b): lines for the report and counts
local function compare(a, b, who)
    -- (an empty table comes back from JSON as nothing)
    for _, k in ipairs({ "flows", "gims", "items", "foes", "puppets" }) do a[k], b[k] = a[k] or {}, b[k] or {} end
    local out, counts = {}, { flows = 0, gims = 0, items = 0, foes = 0 }
    local function line(s) out[#out + 1] = s end
    line(string.format("sync check %s, us in %s, %s in %s", os.date("%Y-%m-%d %H:%M:%S"), tostring(a.chapter), who, tostring(b.chapter)))
    if a.chapter ~= b.chapter then line("DIFFERENT CHAPTERS: the rest compares things that can't match") end
    if a.pos and b.pos then line(string.format("positions: us %s, %s %s", table.concat(a.pos, ","), who, table.concat(b.pos, ","))) end
    -- story
    line("")
    line(string.format("story flows: %d here, %d there", n_keys(a.flows), n_keys(b.flows)))
    local fl = {}
    for h, v in pairs(a.flows) do
        local w = b.flows[h] or 0
        if w ~= v then fl[#fl + 1] = string.format("  flow %s: here %d, there %d", h, v, w) end
    end
    for h, w in pairs(b.flows) do
        if a.flows[h] == nil and w ~= 0 then fl[#fl + 1] = string.format("  flow %s: here 0, there %d", h, w) end
    end
    counts.flows = #fl
    table.sort(fl)
    for i = 1, math.min(#fl, 40) do line(fl[i]) end
    -- gimmicks
    line("")
    line(string.format("gimmicks: %d here, %d there", n_keys(a.gims), n_keys(b.gims)))
    local gl = {}
    for id, sig in pairs(a.gims) do
        local other = b.gims[id]
        if other and other ~= sig then
            local name = "?"
            local gc = gim.by_id and gim.by_id[id]
            local ok, entries = false, nil
            if gc then
                local okb, body = pcall(function() return gc:call("get_BodyGameObject") end)
                if okb and body then name = body:call("get_Name") end
                ok, entries = pcall(gim.state_of, gc)
            end
            local mine, theirs = {}, {}
            for v in sig:gmatch("[^,]+") do mine[#mine + 1] = v end
            for v in other:gmatch("[^,]+") do theirs[#theirs + 1] = v end
            local diffs = {}
            if #mine ~= #theirs then
                diffs[1] = string.format("%d fields here, %d there", #mine, #theirs)
            else
                for i = 1, #mine do
                    if mine[i] ~= theirs[i] then
                        local e = ok and entries and entries[i]
                        diffs[#diffs + 1] = string.format("%s=%s/%s", e and (e[1]:match("[^.]+$") .. "." .. e[2]) or ("#" .. i), mine[i], theirs[i])
                    end
                end
            end
            gl[#gl + 1] = string.format("  %s %s: %s", name, id:sub(1, 8), table.concat(diffs, " "))
        end
    end
    counts.gims = #gl
    table.sort(gl)
    for i = 1, math.min(#gl, 60) do line(gl[i]) end
    -- items lying about
    line("")
    local il = {}
    for id, s in pairs(a.items) do
        local t = b.items[id]
        if t ~= nil and t ~= s then
            il[#il + 1] = string.format("  item %s: %s here, %s there", id:sub(1, 8), s == 1 and "still lying" or "taken", t == 1 and "still lying" or "taken")
        end
    end
    counts.items = #il
    line(string.format("items: %d here, %d there, %d differ", n_keys(a.items), n_keys(b.items), #il))
    for i = 1, math.min(#il, 40) do line(il[i]) end
    -- enemies
    line("")
    local el = {}
    for id, f in pairs(a.foes) do
        local g = b.foes[id]
        if g == nil then
            if f.s == 1 and f.d == 0 then el[#el + 1] = string.format("  %s %s: alive here, not in %s's game", f.k, id:sub(1, 8), who) end
        else
            local why = {}
            if f.d ~= g.d then why[#why + 1] = string.format("dead here %d there %d", f.d, g.d) end
            if f.s ~= g.s then why[#why + 1] = string.format("spawned here %d there %d", f.s, g.s) end
            if f.p and g.p then
                local dx, dy, dz = f.p[1] - g.p[1], f.p[2] - g.p[2], f.p[3] - g.p[3]
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist > 3 then why[#why + 1] = string.format("%.0f m apart", dist) end
            end
            if f.hp and g.hp and f.d == 0 and math.abs(f.hp - g.hp) > 1 then why[#why + 1] = string.format("HP %d/%d", f.hp, g.hp) end
            if #why > 0 then el[#el + 1] = string.format("  %s %s (run by %s): %s", f.k, id:sub(1, 8), f.o, table.concat(why, ", ")) end
        end
    end
    for id, g in pairs(b.foes) do
        if a.foes[id] == nil and g.s == 1 and g.d == 0 then el[#el + 1] = string.format("  %s %s: alive in %s's game, not here", g.k, id:sub(1, 8), who) end
    end
    counts.foes = #el
    table.sort(el)
    line(string.format("enemies: %d here, %d there, %d differ", n_keys(a.foes), n_keys(b.foes), #el))
    for i = 1, math.min(#el, 60) do line(el[i]) end
    -- the player copies
    line("")
    line(string.format("our player: %d joints; %s's: %s", a.my_joints or 0, who, tostring(b.my_joints)))
    for side, d in pairs({ ["our copy of them"] = a, ["their copy of us"] = b }) do
        for _, p in pairs(d.puppets or {}) do
            line(string.format("%s (%s): %s, visible %s, joints matched %d of %d (names %d, a pose carries %d), %d poses kept, last %s s ago, in %s",
                side, tostring(p.name), p.state, tostring(p.visible), p.matched, p.joints, p.names, p.sent_joints, p.snaps, p.age, tostring(p.chapter)))
        end
    end
    return out, counts
end

local function request(why)
    local p = partner_to_follow and partner_to_follow()
    if p == nil or p.id == LOOPBACK_ID then return "no partner" end
    check.waiting = { id = p.id, t = now(), why = why }
    send_ctrl(string.pack("<B", MSG.CHECK_REQ), p.id)
    return "asked " .. tostring(p.name)
end
check.request = request

ext.check_ctrl = function(from, kind, data)
    if kind == MSG.CHECK_REQ then
        ext.later(function()
            local ok, d = pcall(digest)
            if ok then send_ctrl(string.pack("<Bs4", MSG.CHECK, json.dump_string(d)), from) end
        end)
    elseif kind == MSG.CHECK then
        local w = check.waiting
        if w == nil or w.id ~= from then return end
        check.waiting = nil
        local _, s = string.unpack("<Bs4", data)
        ext.later(function()
            local okj, theirs = pcall(json.load_string, s)
            local okd, ours = pcall(digest)
            if not (okj and okd and type(theirs) == "table") then say("sync check failed") return end
            local p = peers[from]
            local lines, c = compare(ours, theirs, p and p.name or "partner")
            fs.write("re9coop_sync_report.txt", table.concat(lines, "\n"))
            check.last = c
            say("sync check (%s): %d story flows, %d gimmicks, %d items, %d enemies differ (re9coop_sync_report.txt)",
                w.why, c.flows, c.gims, c.items, c.foes)
        end)
    end
end

-- the guest checks by itself: a minute after it's settled in, then every 5 minutes
ext.check_late = function(t_now)
    if check.waiting and t_now - check.waiting.t > 20 then check.waiting = nil end
    local st = session.status
    local p = partner_to_follow and partner_to_follow()
    if not world_shared() or st == nil or st.is_host or p == nil or p.id == LOOPBACK_ID or p.chapter ~= me.chapter then
        check.next_auto = nil
        return
    end
    if ext.settled and not ext.settled() then return end
    if check.next_auto == nil then check.next_auto = t_now + 60 end
    if t_now >= check.next_auto and check.waiting == nil then
        check.next_auto = t_now + 300
        request("automatic")
    end
end

-- dev
check.digest, check.compare = digest, compare
end)()

-- Doors held by a scene that isn't playing. An event holds a door (GmDoorData._IsConstMode,
-- _IsMotionFollowMode: the door follows the event's motion and can't be pushed) and lets go of it when it
-- ends. Up to v0.11.1 a guest's whole-world resync (sent when the host came back from a checkpoint) carried
-- such doors from the guest's own opening event into the host's game, where no event let go of them, and
-- the host's save kept them: in Chap3_02 the security office door stayed shut (a host's save, 2026-10-17).
-- "Free stuck doors" (host or alone, outside cutscenes) lets them go and unlocks again the ones this
-- playthrough had opened (_IsDone); a door never opened stays locked as it was.
;(function()
local T_BASE = sdk.typeof("app.structure.GmBaseData")
local T_DOOR_DATA = sdk.typeof("app.structure.GmDoorData")
local fix = { count = 0, next_t = 0 }
ext.doors_fix = fix

local function stuck_doors()
    world.refresh(now())
    gim.contexts_of(now())
    local out = {}
    for id in pairs(world.doors or {}) do
        local gc = gim.by_id and gim.by_id[id]
        local ok, sdc = pcall(function() return gc and gc:call("get_SDC") end)
        local dd = ok and sdc and sdc:call("getStructureData(System.Type)", T_DOOR_DATA)
        if dd and dd:get_field("_IsConstMode") == true then
            out[#out + 1] = { data = dd, base = sdc:call("getStructureData(System.Type)", T_BASE) }
        end
    end
    return out
end

local function may_fix()
    local st = session.status
    local guest = st and st.state == "in_lobby" and not st.is_host
    return me.go ~= nil and not guest and not in_cutscene()
end

-- how many (counted in the game's GUI update, every 3 s while the menu is open)
fix.poll = function()
    local t = now()
    if t >= fix.next_t then
        fix.next_t = t + 3
        ext.later(function()
            local ok, list = pcall(stuck_doors)
            fix.count = (ok and may_fix()) and #list or 0
        end)
    end
    return fix.count
end

fix.run = function()
    ext.later(function()
        if not may_fix() then
            say("doors: only in the host's game or alone, outside cutscenes")
            return
        end
        local n, opened = 0, 0
        for _, d in ipairs(stuck_doors()) do
            d.data:set_field("_IsConstMode", false)
            d.data:set_field("_IsMotionFollowMode", false)
            pcall(d.data.call, d.data, "onDirty")
            if d.base and d.base:get_field("_IsDone") == true and d.base:get_field("_IsLock") == true then
                d.base:set_field("_IsLock", false)
                pcall(d.base.call, d.base, "onDirty")
                opened = opened + 1
            end
            n = n + 1
        end
        fix.count, fix.next_t = 0, now() + 3
        say("freed %d stuck doors (%d you had opened before are unlocked again); save to keep it", n, opened)
    end)
end
end)()

-------------------------------------------------------------------------------------------------
-- saving together
-------------------------------------------------------------------------------------------------
-- When the lobby owner's game saves (an autosave or a typewriter save), the guest's game makes an
-- autosave too, the game's own way (GuiManager.AutoSaveFlow.requestAutoSave with the game's
-- default settings: an Auto slot, the empty or oldest one), so both saves hold the same moment and
-- the guest's manual slots are never written. A save is noticed by the save service's serial
-- number moving on to a game slot (not the system slot). The guest's game saves as soon as it can:
-- not in a cutscene, alive, not loading, and saving allowed there (the game blocks it in some
-- fights). To go on later: both load their latest save, host and join again; the lobby owner's world
-- (locks, story, boxes) is sent on joining.
local saves
do
local T_AUTOSAVE_ARGS = "app.GuiAutoSaveFlowRequestArgs"
local PHASE_IDLE, PHASE_UPDATE = 0, 1

saves = { serial = nil, serial_t = 0, wait_slot = nil, pending = nil, own_until = 0, stats = { sent = 0, made = 0 } }

local function save_service()
    return sdk.get_managed_singleton("app.SaveServiceManager")
end

-- the slot id holding the save with this serial number (-1 is the system slot), or nil
local function slot_of_serial(serial)
    local ssm = save_service()
    local d = ssm and ssm:get_field("_SaveSlotInfoDict")
    local entries = d and d:get_field("_entries")
    local n = d and d:get_field("_count") or 0
    for i, e in ipairs(elements(entries) or {}) do
        if i > n then break end
        local v = (e:get_field("hashCode") or -1) >= 0 and e:get_field("value") or nil
        local k = v and e:get_field("key")
        if k and v:get_field("_SerialNumber") == serial then return k:get_field("_SlotId") end
    end
    return nil
end

local function auto_save_flow()
    local gm = sdk.get_managed_singleton("app.GuiManager")
    local ok, flow = pcall(function() return gm and gm:call("get_AutoSaveFlow") end)
    return ok and flow or nil
end

local function can_save_now()
    if me.go == nil or me.pc == nil or in_cutscene() then return false end
    local hp = me.pc:call("get_HitPoint")
    if hp and (hp:call("get_CurrentHitPoint") or 0) <= 0 then return false end
    local ssm = save_service()
    if ssm == nil or ssm:call("get_IsBusy") or ssm:call("get_IsRejectingGameSlotSave")
        or ssm:call("get_IsSuppressingGameSlotSave") then
        return false
    end
    local flow = auto_save_flow()
    local phase = flow and flow:get_field("_Phase")
    return phase == PHASE_IDLE or phase == PHASE_UPDATE
end

-- an autosave, the way the game makes one
local function make_save()
    local flow = auto_save_flow()
    local args = sdk.create_instance(T_AUTOSAVE_ARGS)
    if flow == nil or args == nil then return false end
    args:add_ref()
    pcall(args.call, args, ".ctor")
    saves.own_until = now() + 30
    local ok = pcall(flow.call, flow, "requestAutoSave", args)
    if ok then
        saves.stats.made = saves.stats.made + 1
        say("saved with the host (autosave)")
    end
    return ok
end

ext.saves_ctrl = function(from, kind, data)
    local st_net = session.status
    if not world_shared() or not cfg.save_with_host or not st_net or from ~= st_net.owner or st_net.is_host then return end
    -- a co-op playthrough isn't saved by the game: the mod keeps what the guest carries
    if ext.fresh and ext.fresh.active then
        if ext.fresh_store then ext.fresh_store("the host saved") end
        return
    end
    local _, chapter = string.unpack("<Bs1", data)
    saves.pending = { since = now(), chapter = chapter }
    say("the host saved: saving here too")
end

saves.late = function(t_now)
    -- the lobby owner: did our game just save into a game slot?
    if t_now >= saves.serial_t then
        saves.serial_t = t_now + 1
        local ssm = save_service()
        local serial = ssm and ssm:get_field("_CurrentSaveSerialNumber")
        if serial and saves.serial == nil then
            saves.serial = serial
        elseif serial and serial ~= saves.serial then
            saves.serial, saves.wait_slot = serial, { serial = serial, till = t_now + 30 }
        end
        local w = saves.wait_slot
        if w and not (ssm and ssm:call("get_IsProcessingSave")) then
            local slot = slot_of_serial(w.serial)
            if slot ~= nil or t_now > w.till then saves.wait_slot = nil end
            local st_net = session.status
            if slot ~= nil and slot >= 0 and world_shared() and st_net and st_net.is_host and t_now >= saves.own_until then
                send_ctrl(string.pack("<Bs1", MSG.SAVE, me.chapter))
                saves.stats.sent = saves.stats.sent + 1
                say("saved: your partner's game saves too")
                -- a partner in a co-op playthrough gets our world as saved (what a load of theirs brings back)
                local p = partner_to_follow and partner_to_follow()
                if p and p.id ~= LOOPBACK_ID and ext.fresh_send_world then ext.fresh_send_world(p.id) end
            end
        end
    end
    -- the guest: save once we can
    local p = saves.pending
    if p and can_save_now() then
        saves.pending = nil
        ext.later(make_save)
    elseif p and t_now - p.since > 300 then
        saves.pending = nil
        say("couldn't save with the host (no chance to in 5 minutes)")
    end
end

-- dev: the slot a serial number went to, and a save the guest way
saves.slot_of_serial, saves.make_save, saves.can_save_now = slot_of_serial, make_save, can_save_now
end

-------------------------------------------------------------------------------------------------
-- downed and revived, grabbed and rescued
-------------------------------------------------------------------------------------------------
-- Downed: while a partner is with you (same chapter, connected), the game's own "can't die" request
-- (HitPoint.NoDeath) is on, so a hit that would kill you leaves you at 1 HP, and you go down: no
-- moving, aiming or items (the game's player restrictions, requested every frame), no more damage
-- (Invincible), and a grab on you is ended. Your partner crouches next to you for a moment to get you
-- up with a third of your health. If nobody does within 30 s you come to next to your partner
-- (unless "come to next to your partner" is off: then after 90 s). If your partner leaves, or you
-- both go down, you die the game's way (game over, back to the last checkpoint).
-- Grabbed: the game's grapple controller (GrappleFsmController.requestGrapple / startGrapple with our
-- player among its participants) tells us we're held. Your partner frees you by hurting the enemy that
-- holds you (their hits on it reach your game) or by a melee attack (knife, kick) next to you; the grab
-- is ended with GrappleFsmController.forceEndGrapple, inside the game's GUI update.
do
local REVIVE_TIME, BLEED_OUT, PARTNER_GONE = 2.5, 90, 10
local REVIVE_RANGE, RESCUE_RANGE = 1.8, 2.5
-- Walk, Run, Move, Terrain, Hold, InventoryOpen, Crouch, EquipmentWeapon, QuickTurn, MeleeWepAttack,
-- Stumble, Cover (the camera stays free)
local RESTRICT_DOWN = 1 | 2 | 4 | 8 | 16 | 64 | 128 | 256 | 512 | 8192 | 16384 | 32768
local LABEL = "re9coop"
local SIG_DAMAGE = "addDamageHitPoint(System.Int32, System.Boolean, System.Boolean)"
local SIG_RECOVERY = "recovery(System.Int32, app.HitPoint.RecoveryFactor)"
local M_DAMAGE = sdk.find_type_definition("app.HitPoint"):get_method(SIG_DAMAGE)
local T_GRAPPLE = sdk.find_type_definition("app.GrappleFsmController")

local life = {
    hp = nil, hp_addr = 0, nodeath = false,
    down_since = nil, lethal_t = -10, alone_since = nil, both_since = nil, invincible_until = 0,
    dead = false,         -- we died: nothing more until the game brings a new player object
    grab = nil, end_grab = false,
    revive_t = 0, revive_for = nil, rescue_t = 0,
    come_to_after = 30,   -- s down before we come to next to the partner
    stats = { downs = 0, revived = 0, rescues = 0, came_to = 0 },
}
ext.life = life

local function partner_here()
    local p = partner_to_follow and partner_to_follow()
    if p == nil or (p.id == LOOPBACK_ID and not _G.re9coop_test_life) then return nil end
    if p.chapter ~= me.chapter or now() - p.last > 3 then return nil end
    return p
end

local function partner_pos(p)
    local s = p.snaps[#p.snaps]
    return s and s.pos
end

local function my_pos()
    return me.go and me.go:call("get_Transform"):call("get_Position")
end

local function set_nodeath(on)
    if on == life.nodeath or life.hp == nil then return end
    local ok, nd = pcall(life.hp.call, life.hp, "get_NoDeath")
    if not ok or nd == nil then return end
    if on then
        pcall(nd.call, nd, "request(System.String, System.Boolean)", LABEL, true)
    else
        pcall(nd.call, nd, "clear(System.String)", LABEL)
    end
    life.nodeath = on
end

local function go_down(t_now)
    life.down_since, life.alone_since, life.both_since = t_now, nil, nil
    me.down = true
    pcall(life.hp.call, life.hp, "set_Invincible", true)
    if life.grab then life.end_grab = true end
    life.stats.downs = life.stats.downs + 1
    say("you're down: your partner can get you up (crouch next to you)")
end

local function get_up(t_now, ratio)
    if not life.down_since then return end
    life.down_since, me.down = nil, false
    local hp = life.hp
    local max = hp:call("get_CurrentMaximumHitPoint") or 0
    local cur = hp:call("get_CurrentHitPoint") or 0
    local want = math.floor(max * ratio)
    if want > cur then pcall(hp.call, hp, SIG_RECOVERY, want - cur, nil) end
    life.invincible_until = t_now + 2 -- a moment to get away
    life.stats.revived = life.stats.revived + 1
    say("back on your feet")
end

-- nobody got us up: we come to next to the partner (no game over, the worlds stay together)
life.come_to = function(t_now)
    get_up(t_now, 0.35)
    life.stats.came_to = life.stats.came_to + 1
    ext.later(function() say("%s", teleport_to_partner()) end)
    say("you came to next to your partner")
end

-- die the game's way (game over)
local function die()
    life.down_since, me.down, life.dead, me.dead = nil, false, true, true
    set_nodeath(false)
    local hp = life.hp
    pcall(hp.call, hp, "set_Invincible", false)
    foes.bypass = true -- not a hit on a shared enemy
    pcall(hp.call, hp, SIG_DAMAGE, 999999, false, true)
    foes.bypass = false
    say("you didn't make it")
end

-- a hit that would kill us (NoDeath keeps 1 HP): down
sdk.hook(M_DAMAGE, function(args)
    if not life.nodeath or life.down_since or sdk.to_int64(args[2]) ~= life.hp_addr then return end
    local cur = life.hp:call("get_CurrentHitPoint") or 0
    if cur - int32(sdk.to_int64(args[3])) <= 0 then life.lethal_t = now() end
end, nil)

-- grabs that include our player
local function grapple_hook(args)
    if me.go == nil then return end
    local arr = sdk.to_managed_object(args[3])
    local ok, list = pcall(function() return arr:get_elements() end)
    if not ok then return end
    local mine, others = false, {}
    local my_addr = me.go:get_address()
    for _, g in ipairs(list) do
        local a = g:get_address()
        if a == my_addr then mine = true else others[a] = true end
    end
    if mine then
        life.grab = { ctl = sdk.to_managed_object(args[2]), enemies = others, since = now() }
        if life.down_since then life.end_grab = true end
    end
end
for _, m in ipairs(T_GRAPPLE:get_methods()) do
    local n = m:get_name()
    if n == "requestGrapple" or n == "startGrapple" then sdk.hook(m, grapple_hook, nil) end
end

-- the partner hit an enemy of ours: if it is the one holding us, we're free
me.on_partner_hit = function(e)
    local g = life.grab
    if g == nil then return end
    local ctl = spawn_control(e)
    local go = ctl and ctl:call("getSpawnInstance")
    if go and g.enemies[go:get_address()] then
        life.end_grab = true
        life.stats.rescues = life.stats.rescues + 1
    end
end

ext.life_ctrl = function(from, kind, data)
    if kind == MSG.REVIVE then
        if life.down_since then get_up(now(), 0.35) end
    elseif kind == MSG.RESCUE then
        if life.grab then
            life.end_grab = true
            life.stats.rescues = life.stats.rescues + 1
        end
    end
end

-- before the player's update: keep NoDeath / restrictions right, notice going down
ext.life_tick = function(t_now)
    local hp = me.pc and me.pc:call("get_HitPoint")
    local addr = hp and hp:get_address() or 0
    if addr ~= life.hp_addr then -- a new player object (load, chapter, game over)
        life.hp, life.hp_addr, life.nodeath, life.dead, me.dead = hp, addr, false, false, false
        life.down_since, life.grab, life.end_grab, me.down, me.grabbed = nil, nil, false, false, false
    end
    if hp == nil or life.dead then return end
    if hp:call("get_IsDead") or (life.down_since == nil and (hp:call("get_CurrentHitPoint") or 0) <= 0) then
        life.dead, me.down, me.dead = true, false, true -- died some other way (a fall, a scripted death)
        set_nodeath(false)
        return
    end
    local p = partner_here()
    if life.down_since == nil then
        set_nodeath(p ~= nil and cfg.revive and world_shared())
        if life.nodeath and (hp:call("get_CurrentHitPoint") or 0) <= 1 and t_now - life.lethal_t < 2 then
            go_down(t_now)
        end
        if life.invincible_until > 0 and t_now >= life.invincible_until then
            life.invincible_until = 0
            pcall(hp.call, hp, "set_Invincible", false)
        end
    else
        local u = me.pc:call("get_CharacterUpdaterBase")
        local core = u and u:call("get_RestrictBlackboardCore")
        local unit = core and core:get_field("<Unit>k__BackingField")
        if unit then pcall(unit.call, unit, "requestRestrictionAction", RESTRICT_DOWN) end
        if p then life.alone_since = nil else life.alone_since = life.alone_since or t_now end
        if p and p.flags and p.flags & (FLAG_DOWN | 1024) ~= 0 then -- down or dead: nobody to get us up
            life.both_since = life.both_since or t_now
        else
            life.both_since = nil
        end
        local partner_up = p and not (p.flags and p.flags & (FLAG_DOWN | 1024) ~= 0)
        if cfg.respawn_at_partner and partner_up and t_now - life.down_since > life.come_to_after then
            life.come_to(t_now)
        elseif t_now - life.down_since > BLEED_OUT or (life.alone_since and t_now - life.alone_since > PARTNER_GONE)
            or (life.both_since and t_now - life.both_since > 3) then
            die()
        end
    end
    if life.grab and not life.grab.ctl:call("get_IsPlaying") then life.grab, life.end_grab = nil, false end
    me.grabbed = life.grab ~= nil

    -- helping the partner: crouch next to them when they're down, melee next to them when grabbed
    life.revive_for = nil
    if p and me.go and not life.down_since then
        local pp, mp = partner_pos(p), my_pos()
        local d = pp and mp and (pp - mp):length() or 99
        local common = me.pc:call("get_Common")
        if p.flags and p.flags & FLAG_DOWN ~= 0 and d <= REVIVE_RANGE and common and common:call("get_IsCrouch") then
            life.revive_t = life.revive_t + (t_now - (life.revive_last or t_now))
            life.revive_for = p
            if life.revive_t >= REVIVE_TIME then
                life.revive_t = 0
                send_ctrl(string.pack("<B", MSG.REVIVE), p.id)
            end
        else
            life.revive_t = 0
        end
        local grabbed = p.flags and p.flags & FLAG_GRABBED ~= 0
        if grabbed and d <= RESCUE_RANGE and common and common:call("get_IsMeleeAttack") and t_now - life.rescue_t > 1 then
            life.rescue_t = t_now
            send_ctrl(string.pack("<B", MSG.RESCUE), p.id)
        end
    end
    life.revive_last = t_now
end

-- inside the game's GUI update: end a grab
ext.life_gui = function()
    if life.end_grab and life.grab then
        life.end_grab = false
        pcall(life.grab.ctl.call, life.grab.ctl, "forceEndGrapple(System.Boolean)", false)
    end
end

ext.life_draw = function()
    local cx = 960
    if life.down_since and not life.dead then
        local come = cfg.respawn_at_partner
        local left = math.max(0, math.ceil((come and life.come_to_after or BLEED_OUT) - (now() - life.down_since)))
        local msg = come and string.format("You're down. Your partner can get you up (crouch next to you), or you come to next to them in %d s", left)
            or string.format("You're down. Your partner can get you up (crouch next to you). %d s", left)
        draw.text(msg, cx - #msg * 3.5, 520, 0xFF4040FF)
    end
    for _, p in pairs(peers) do
        local pup = p.puppet
        local hpos = pup and pup.state == "ready" and pup:head_position()
        local sp = hpos and draw.world_to_screen(hpos + Vector3f.new(0, 0.6, 0))
        if p.flags and p.flags & FLAG_DOWN ~= 0 then
            local msg = life.revive_for == p and string.format("Getting %s up... %d%%", p.name, math.floor(life.revive_t * 100 / REVIVE_TIME))
                or string.format("%s is down: crouch next to them", p.name)
            if sp then draw.text(msg, sp.x - #msg * 3.5, sp.y, 0xFF4040FF) end
            draw.text(msg, cx - #msg * 3.5, 560, 0xFF4040FF)
        elseif p.flags and p.flags & FLAG_GRABBED ~= 0 then
            local msg = string.format("%s is grabbed: shoot the enemy or hit it next to them", p.name)
            if sp then draw.text(msg, sp.x - #msg * 3.5, sp.y, 0xFF40A0FF) end
        elseif p.flags and p.flags & 1024 ~= 0 then
            local msg = string.format("%s didn't make it: back with you once they press Continue", p.name)
            draw.text(msg, cx - #msg * 3.5, 560, 0xFF4040FF)
        end
    end
end
end


local function set_loopback(v)
    loopback = v
    if net then net.set_loopback(v, cfg.loopback_delay_ms) end
    if not v then drop_peer(LOOPBACK_ID) else announce(LOOPBACK_ID) end
end

local function sync_members(st, t_now)
    local ids = {}
    for _, m in ipairs(st.members or {}) do
        if m.id ~= st.me then ids[#ids + 1] = m.id end
    end
    table.sort(ids)
    local key = table.concat(ids, ",")
    if key ~= session.last_members then
        session.last_members = key
        local present = {}
        for _, id in ipairs(ids) do present[id] = true end
        for id in pairs(peers) do
            if id ~= LOOPBACK_ID and not present[id] then drop_peer(id) end
        end
        for _, m in ipairs(st.members or {}) do
            if m.id ~= st.me then peer(m.id).name = m.name end
        end
        if #ids > 0 then announce() end
    end
    if t_now >= session.next_ping then
        session.next_ping = t_now + 2
        send_ctrl(string.pack("<Bd", MSG_PING, t_now))
    end
end

local function tick_session(t_now)
    if net == nil then return end
    local st = net.status()
    session.status = st
    if st.state == "in_lobby" then
        sync_members(st, t_now)
    elseif session.last_members ~= "" then
        session.last_members = ""
        for id in pairs(peers) do if id ~= LOOPBACK_ID then drop_peer(id) end end
    end
    if t_now >= session.next_join_poll then
        session.next_join_poll = t_now + 1
        local lobby = net.pending_join()
        if lobby then
            say("joining lobby %s from a Steam invite", lobby)
            session.left = false
            net.join(lobby)
        end
    end
    -- Reconnecting: a session that drops without "Leave" (a Steam hiccup) is picked up again for 3
    -- minutes: the guest tries its lobby and the host's lobby as Steam friends list it; the host hosts
    -- again. The last session is kept in the config, so a game restarted after a crash does the same
    -- (the guest within 30 minutes, the host within 10).
    local busy = st.state == "creating" or st.state == "joining"
    if st.state == "in_lobby" then
        if st.owner ~= "" and (cfg.last_host ~= st.owner or cfg.last_lobby ~= st.lobby or os.time() - cfg.last_t > 300) then
            cfg.last_host, cfg.last_lobby, cfg.last_was_host, cfg.last_t = st.owner, st.lobby, st.is_host, os.time()
            save_cfg()
        end
        session.was_in, session.rj, session.left = true, nil, false
    elseif session.was_in and not busy then
        session.was_in = false
        if cfg.auto_rejoin and not session.left then
            session.rj = { till = t_now + 180, next = t_now + 2, tries = 0 }
            say("the co-op session dropped: reconnecting...")
        end
    elseif session.rj == nil and not session.started and cfg.auto_rejoin and cfg.last_host ~= "" and me.go
        and not _G.re9coop_test_no_rejoin then -- (dev bridge: tests never pick an old session up)
        session.started = true
        local age = os.time() - cfg.last_t
        if age < (cfg.last_was_host and 600 or 1800) then
            session.rj = { till = t_now + 180, next = t_now + 2, tries = 0 }
            say(cfg.last_was_host and "hosting your co-op session again (Leave to stop)" or "looking for your partner's co-op session...")
        end
    end
    local rj = session.rj
    if rj and st.state ~= "in_lobby" and not busy and t_now >= rj.next then
        if t_now > rj.till then
            session.rj = nil
            say("couldn't reconnect: host or join from the menu")
        else
            rj.next, rj.tries = t_now + 6, rj.tries + 1
            if cfg.last_was_host then
                net.host(2, cfg.public_lobby and 2 or 1)
            else
                local target
                for _, f in ipairs(net.friends() or {}) do
                    if f.id == cfg.last_host and f.lobby ~= "" then target = f.lobby end
                end
                if target == nil and rj.tries % 2 == 1 and cfg.last_lobby ~= "" then target = cfg.last_lobby end
                if target then net.join(target) end
            end
        end
    end
end

local function tick_send(t_now)
    if me.go == nil then return end
    if t_now >= me.next_appear_check then
        me.next_appear_check = t_now + 2
        local ok, a = pcall(read_appearance, me.go)
        if ok then
            local key = appearance_key(a)
            if key ~= me.appear_key then
                me.appear, me.appear_key = a, key
                me.appear_blob = msg_appear(a, me.names)
                send_ctrl(me.appear_blob)
            end
        end
    end
    if t_now >= me.next_weapon_check then
        me.next_weapon_check = t_now + 0.25
        local ok, mesh, mat, wgo = pcall(read_weapon, me.pc, me.go)
        if ok then
            local a = addr(wgo)
            if a ~= me.weapon_go_addr then
                me.weapon_go_addr = a
                me.weapon_sc = wgo and wgo:call("getComponent(System.Type)", TYPE_SOUND) or nil
            end
            local blob = string.pack("<Bs2s2", MSG_WEAPON, mesh, mat)
            if blob ~= me.weapon_blob then
                me.weapon_blob = blob
                send_ctrl(blob)
            end
        end
    end
    if #fx_out > 0 then
        local out = fx_out
        fx_out = {}
        for _, blob in ipairs(out) do send_ctrl(blob) end
    end
    if t_now < session.next_send then return end
    session.next_send = t_now + 1 / math.max(1, cfg.send_hz)
    local st = session.status
    if not loopback and (st == nil or st.state ~= "in_lobby" or session.last_members == "") then return end
    local ok, data = pcall(msg_pose, t_now)
    if ok and net then
        local n = net.send(data, false, CH_POSE)
        stats.tx, stats.tx_bytes = stats.tx + n, stats.tx_bytes + #data * n
    end
end

-------------------------------------------------------------------------------------------------
-- scene changes
-------------------------------------------------------------------------------------------------
-- Loading a save, the next chapter or a jump all go through LevelFlowManager.requestGameJump (loads
-- also through SaveServiceManager.requestLoad). Right then every object of the old scene still
-- exists: the puppets are destroyed, every index of scene objects (doors, items, gimmicks, triggers,
-- enemies, item boxes) is dropped and the Lua wrappers are collected at once, and the old player
-- object is left alone until the new one shows up. Holding them through the unload corrupted the
-- game's memory (a crash a second later, in its lock-on scan).
local function scene_leaving()
    if me.go ~= nil then
        me.leaving = { addr = me.go_addr, till = now() + 60, joint = me.joints and me.joints[1] and me.joints[1]:get_address() or 0 }
        forget_player() -- on_player_lost: puppets destroyed, enemies / world / gimmicks / story / box reset
    end
    if ext.life then ext.life.hp, ext.life.hp_addr, ext.life.grab = nil, 0, nil end
    if ext.sync_scene then ext.sync_scene() end
    if ext.mark_scene then ext.mark_scene() end
    ext.jobs = {} -- the partner's door pushes, pickups and story steps were for the old scene
    collectgarbage("collect")
end
do
    local function on_change() pcall(scene_leaving) end
    sdk.hook(sdk.find_type_definition("app.LevelFlowManager"):get_method("requestGameJump"), on_change, nil)
    for _, m in ipairs(sdk.find_type_definition("app.SaveServiceManager"):get_methods()) do
        if m:get_name() == "requestLoad" then sdk.hook(m, on_change, nil) end
    end
end

-------------------------------------------------------------------------------------------------
-- frame hooks
-------------------------------------------------------------------------------------------------
-- Before animation: drive the puppets so their parts' JointConstraints pick the pose up this frame.
re.on_pre_application_entry("UpdateBehavior", function()
    if net == nil then return end
    local t_now = now()
    local ok, err = pcall(function()
        refresh_player()
        tick_session(t_now)
        receive()
        for _, p in pairs(peers) do update_peer(p, t_now) end
        enemies_update(t_now)
        if ext.life_tick then ext.life_tick(t_now) end
        if ext.ground_tick then ext.ground_tick(t_now) end
    end)
    if not ok then say("error: %s", tostring(err)) end
    if t_now - stats.rate_t >= 1 then
        stats.tx_kbps = stats.tx_bytes * 8 / 1000 / math.max(0.001, t_now - stats.rate_t)
        stats.rx_kbps = stats.rx_bytes * 8 / 1000 / math.max(0.001, t_now - stats.rate_t)
        stats.tx_bytes, stats.rx_bytes, stats.rate_t = 0, 0, t_now
    end
end)

-- After animation: read our own final pose and send it.
re.on_application_entry("LateUpdateBehavior", function()
    if net == nil then return end
    local t_now = now()
    local ok, err = pcall(tick_send, t_now)
    if not ok then say("send error: %s", tostring(err)) end
    ok, err = pcall(enemies_late, t_now)
    if not ok then say("enemy error: %s", tostring(err)) end
    ok, err = pcall(world_late, t_now)
    if not ok then say("world error: %s", tostring(err)) end
    ok, err = pcall(gimmicks_late, t_now)
    if not ok then say("gimmick error: %s", tostring(err)) end
    ok, err = pcall(story_late, t_now)
    if not ok then say("story error: %s", tostring(err)) end
    ok, err = pcall(saves.late, t_now)
    if not ok then say("save error: %s", tostring(err)) end
    ok, err = pcall(ext.recipes_late, t_now)
    if not ok then say("recipe error: %s", tostring(err)) end
    ok, err = pcall(ext.sync_late, t_now)
    if not ok then say("sync error: %s", tostring(err)) end
    ok, err = pcall(ext.fresh_late, t_now)
    if not ok then say("co-op playthrough error: %s", tostring(err)) end
    ok, err = pcall(ext.check_late, t_now)
    if not ok then say("sync check error: %s", tostring(err)) end
end)

re.on_frame(function()
    -- partner in another chapter: say where, so the other player can catch up
    for id, p in pairs(peers) do
        if id ~= LOOPBACK_ID and p.chapter ~= "" and me.chapter ~= "" and p.chapter ~= me.chapter then
            local msg = string.format("%s is in %s (you: %s)", p.name, p.chapter, me.chapter)
            draw.text(msg, 960 - #msg * 3.5, 40, 0xFF80E0FF)
        end
    end
    if story and story.follow.target then
        local left = math.max(0, math.ceil(story.follow.at - now()))
        local msg = left > 0 and story.follow.tries == 0 and string.format("Following the host to %s in %d...", story.follow.target, left)
            or string.format("Going to %s...", story.follow.target)
        draw.text(msg, 960 - #msg * 3.5, 60, 0xFF80FFFF)
    end
    if ext.life_draw then pcall(ext.life_draw) end
    if ext.fresh_draw then pcall(ext.fresh_draw) end
    if ext.mark_draw then
        local ok, err = pcall(ext.mark_draw)
        if not ok then
            say("marker error: %s", tostring(err))
            ext.mark_draw = nil
        end
    end
    if not cfg.nametags then return end
    for _, p in pairs(peers) do
        local pup = p.puppet
        if pup and pup.state == "ready" and pup.visible then
            local hpos = pup:head_position()
            local sp = hpos and draw.world_to_screen(hpos + Vector3f.new(0, 0.35, 0))
            if sp then
                local last = p.snaps[#p.snaps]
                local hp = (last and last.hp_max and last.hp_max > 0) and string.format("  %d%%", math.floor(last.hp * 100 / last.hp_max)) or ""
                local my = me.go and me.go:call("get_Transform"):call("get_Position")
                local dist = my and (hpos - my):length() or 0
                local label = p.name .. hp .. (p.rtt and string.format("  %d ms", math.floor(p.rtt * 1000)) or "")
                    .. (dist > 10 and string.format("  %d m", math.floor(dist + 0.5)) or "")
                draw.text(label, sp.x - #label * 3.5, sp.y, 0xFFFFFFFF)
            end
        end
    end
end)

re.on_script_reset(function()
    pcall(enemies_reset, me.go ~= nil)
    for id in pairs(peers) do
        local p = peers[id]
        if p.puppet then p.puppet:destroy() end
    end
    peers = {}
    if net then
        send_ctrl(string.pack("<B", MSG_BYE))
        net.set_loopback(false, 0)
    end
end)

-------------------------------------------------------------------------------------------------
-- menu
-------------------------------------------------------------------------------------------------
local ui = { join_id = "", friends = nil, friends_t = 0 }

re.on_draw_ui(function()
    if not imgui.tree_node("RE9 Co-op (online) v" .. VERSION) then return end
    if net == nil then
        imgui.text_colored("re9coop_net.dll is missing from reframework/plugins.", 0xFF4040FF)
        imgui.tree_pop()
        return
    end
    local st = session.status or net.status()
    if not st.steam then
        imgui.text_colored("Steam isn't ready: " .. tostring(st.error), 0xFF4040FF)
    end
    imgui.text("You: " .. net.my_name() .. "   player: " .. (me.kind ~= "" and me.kind or "-") .. "   area: " .. (me.chapter ~= "" and me.chapter or "-"))
    imgui.text("Session: " .. st.state .. (st.is_host and "  (host)" or "") .. (st.error ~= "" and ("  - " .. st.error) or ""))

    if st.state == "in_lobby" then
        imgui.text("Lobby " .. st.lobby .. ", " .. #st.members .. " player(s)")
        imgui.same_line()
        if imgui.button("Copy lobby ID") then
            sdk.copy_to_clipboard(st.lobby)
            say("lobby ID %s copied", st.lobby)
        end
        if imgui.button("Invite friends (Steam overlay)") then net.invite() end
        imgui.same_line()
        if imgui.button("Teleport to partner") then say("%s", teleport_to_partner()) end
        imgui.same_line()
        if imgui.button("Go to partner's chapter") then say("%s", go_to_partner_chapter()) end
        imgui.same_line()
        if imgui.button("Check sync with partner") and ext.check then say("sync check: %s", ext.check.request("by hand")) end
        imgui.same_line()
        if imgui.button("Leave") then
            send_ctrl(string.pack("<B", MSG_BYE))
            session.left, session.rj, cfg.last_host = true, nil, ""
            save_cfg()
            net.leave()
        end
    elseif st.state == "creating" or st.state == "joining" then
        imgui.text("...")
    else
        if session.rj then
            imgui.text("Reconnecting...")
            imgui.same_line()
            if imgui.button("Stop") then session.rj, session.left, cfg.last_host = nil, true, "" save_cfg() end
        end
        if imgui.button("Host a co-op session") then
            session.left, session.rj = false, nil
            net.host(2, cfg.public_lobby and 2 or 1)
        end
        imgui.same_line()
        local cp, vp = imgui.checkbox("Anyone with the ID can join", cfg.public_lobby)
        if cp then cfg.public_lobby = vp save_cfg() end
        imgui.same_line()
        if imgui.button("Refresh friends") or ui.friends == nil then
            ui.friends = net.friends()
        end
        if ui.friends and #ui.friends > 0 then
            imgui.text("Friends playing RE Requiem:")
            for _, f in ipairs(ui.friends) do
                if f.lobby ~= "" then
                    if imgui.button("Join " .. f.name .. "##" .. f.id) then
                        session.left, session.rj = false, nil
                        net.join(f.lobby)
                    end
                else
                    imgui.text("  " .. f.name .. " (not hosting)")
                end
            end
        else
            imgui.text("No friends in RE Requiem right now.")
        end
        local changed, v = imgui.input_text("Lobby ID", ui.join_id)
        if changed then ui.join_id = v end
        imgui.same_line()
        if imgui.button("Join by ID") and ui.join_id ~= "" then
            session.left, session.rj = false, nil
            net.join(ui.join_id)
        end
    end

    imgui.separator()
    for id, p in pairs(peers) do
        local pup = p.puppet
        imgui.text(string.format("%s  area %s%s  %s  ping %s", p.name, p.chapter ~= "" and p.chapter or "?",
            (p.chapter ~= "" and p.chapter ~= me.chapter) and " (not with you)" or "",
            pup and pup.state or "waiting for look",
            p.rtt and string.format("%d ms", math.floor(p.rtt * 1000)) or "-"))
    end
    imgui.text(string.format("net: out %.1f kbit/s, in %.1f kbit/s", stats.tx_kbps, stats.rx_kbps))
    if foes.active then
        imgui.text(string.format("Shared enemies: you run %d, your partner runs %d. Hits sent %d, received %d. Handovers %d.",
            foes.stats.owned, foes.stats.puppets, foes.stats.dmg_sent, foes.stats.dmg_applied, foes.stats.handovers))
    end
    imgui.text(string.format("Doors: sent %d, opened for partner %d. Pickups: sent %d, removed %d.",
        world.stats.doors_sent, world.stats.doors_applied, world.stats.items_sent, world.stats.items_applied))
    imgui.text(string.format("Locks, puzzles, switches: sent %d, applied %d. Keys / items used: sent %d, replayed %d.",
        gim.stats.sent, gim.stats.applied, gim.stats.live_sent, gim.stats.live_applied))
    imgui.text(string.format("Story steps: sent %d, applied %d. Chapter jumps %d.", story.stats.sent, story.stats.applied, story.stats.jumps))
    imgui.text(string.format("Item box: changes sent %d, applied %d. Saves: told partner %d, saved with host %d.",
        box.stats.sent, box.stats.applied, saves.stats.sent, saves.stats.made))
    local stuck = ext.doors_fix and ext.doors_fix.poll() or 0
    if stuck > 0 then
        imgui.text_colored(string.format("%d door(s) here are held by a scene that isn't playing: they can't be pushed open.", stuck), 0xFF40C0FF)
        if imgui.button("Free stuck doors") then ext.doors_fix.run() end
    end

    imgui.separator()
    local c, v = imgui.checkbox("Self test (see your own echo next to you)", loopback)
    if c then set_loopback(v) end
    local changed = false
    c, v = imgui.checkbox("Self test: echo faces you", cfg.loopback_face); if c then cfg.loopback_face, changed = v, true end
    c, v = imgui.checkbox("Partner's muzzle flash and gun sounds", cfg.shot_fx); if c then cfg.shot_fx, changed = v, true end
    c, v = imgui.checkbox("Partner's footsteps and body sounds", cfg.body_sounds); if c then cfg.body_sounds, changed = v, true end
    c, v = imgui.checkbox("Share enemies (both players need it on)", cfg.enemy_sync); if c then cfg.enemy_sync, changed = v, true end
    c, v = imgui.checkbox("Share doors and pickups", cfg.world_sync); if c then cfg.world_sync, changed = v, true end
    c, v = imgui.checkbox("Share locks, puzzles and switches", cfg.gimmick_sync); if c then cfg.gimmick_sync, changed = v, true end
    c, v = imgui.checkbox("Share crafting recipes", cfg.recipe_sync); if c then cfg.recipe_sync, changed = v, true end
    c, v = imgui.checkbox("Down too long: come to next to your partner", cfg.respawn_at_partner); if c then cfg.respawn_at_partner, changed = v, true end
    c, v = imgui.checkbox("Skip cutscenes together", cfg.skip_together); if c then cfg.skip_together, changed = v, true end
    c, v = imgui.checkbox("Show your partner on the map and at the screen edge", cfg.partner_marker); if c then cfg.partner_marker, changed = v, true end
    c, v = imgui.checkbox("Share what enemies drop", cfg.share_drops); if c then cfg.share_drops, changed = v, true end
    c, v = imgui.checkbox("Share story progress (experimental)", cfg.story_sync); if c then cfg.story_sync, changed = v, true end
    c, v = imgui.checkbox("Follow the host to new chapters (guest)", cfg.follow_host); if c then cfg.follow_host, changed = v, true end
    c, v = imgui.checkbox("Join as a co-op playthrough from the main menu (guest; your saves untouched)", cfg.fresh_join); if c then cfg.fresh_join, changed = v, true end
    c, v = imgui.checkbox("One item box for both players", cfg.box_sync); if c then cfg.box_sync, changed = v, true end
    c, v = imgui.checkbox("Save when the host saves (guest; an autosave)", cfg.save_with_host); if c then cfg.save_with_host, changed = v, true end
    c, v = imgui.checkbox("Go down instead of dying while your partner is with you", cfg.revive); if c then cfg.revive, changed = v, true end
    c, v = imgui.checkbox("Ammo, healing and materials: each player picks up their own", cfg.pickups_for_both); if c then cfg.pickups_for_both, changed = v, true end
    c, v = imgui.checkbox("Name tags", cfg.nametags); if c then cfg.nametags, changed = v, true end
    c, v = imgui.slider_int("Pose updates per second", cfg.send_hz, 5, 30); if c then cfg.send_hz, changed = v, true end
    c, v = imgui.slider_float("Smoothing delay (s)", cfg.interp_delay, 0.05, 0.4); if c then cfg.interp_delay, changed = v, true end
    if changed then save_cfg() end

    if imgui.tree_node("Log") then
        for _, l in ipairs(recent_log) do imgui.text(l) end
        imgui.tree_pop()
    end
    imgui.tree_pop()
end)

if net == nil then
    log.warn(TAG .. "re9coop_net.dll not loaded; co-op is off")
else
    say("loaded v%s (net %s)", VERSION, net.version())
end

-- dev hooks for automated tests (harmless in normal play)
_G.re9coop = { peers = function() return peers end, me = me, set_loopback = set_loopback, cfg = cfg, foes = foes,
    teleport_to_partner = teleport_to_partner, world = world, gim = gim, story = story,
    go_to_partner_chapter = go_to_partner_chapter, box = box, saves = saves, gimmick_ctrl = gimmick_ctrl, ext = ext,
    on_ctrl = on_ctrl,
    -- what every part of the mod sees in this chapter (for the chapter-by-chapter test)
    selftest = function()
        local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
        local echo = peers[LOOPBACK_ID]
        local r = { chapter = me.chapter, kind = me.kind, player = me.go ~= nil,
            echo = echo and (echo.puppet and echo.puppet.state or "no puppet") or "off",
            enemies = count(foes.index), gimmicks = gim.contexts and #gim.contexts or 0,
            triggers = count(gim.trigger_index(now(), true).by_key), doors = count(world.doors), items = count(world.items),
            boxes = count(box.box_inventories()), weapon = me.weapon_blob and #me.weapon_blob or 0,
            nodeath = ext.life and ext.life.nodeath, cutscene = in_cutscene() }
        local lf = sdk.get_managed_singleton("app.LevelFlowManager")
        local d = lf and lf:get_field("_ProgressiveNumberList")
        r.flows = d and d:get_field("_count") or 0
        local log = {}
        for i = math.max(1, #recent_log - 4), #recent_log do log[#log + 1] = recent_log[i] end
        r.log = log
        return r
    end }
