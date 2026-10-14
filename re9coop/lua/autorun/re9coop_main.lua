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

local VERSION = "0.6.1"
local PROTO = 5
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
    flash_power = 2000,       -- muzzle flash light (the game's own flashlight fill light is 100)
    flash_radius = 5.0,
    enemy_sync = true,        -- share the host's enemies
    enemy_hz = 15,            -- enemy updates per second (host)
    enemy_posed = 4,          -- how many enemies nearest to the guest get their full skeleton
    world_sync = true,        -- share door pushes and pickups
    gimmick_sync = true,      -- share gimmick states (locks, puzzles, switches, used keys)
    story_sync = true,        -- share story progress (level flow steps); experimental
    follow_host = true,       -- the guest goes to the host's chapter
    box_sync = true,          -- one item box for both players
    save_with_host = true,    -- the guest's game autosaves whenever the host's game saves
    public_lobby = false,     -- anyone with the lobby ID can join (otherwise friends and invitees)
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
    weapon_go_addr = 0, weapon_sc = nil, player_sc = nil,
    flashlight = nil,      -- app.FlashLightController under "PlayerFlashLightController"
}

local on_player_lost -- set below: puppets are rebuilt whenever our player object goes away
local in_cutscene -- set in the "story" section: true while a cutscene plays here

local function forget_player()
    if me.go ~= nil and on_player_lost then on_player_lost() end
    me.pc, me.go, me.go_addr = nil, nil, 0
    me.joints, me.names, me.j_root, me.j_hip = nil, nil, nil, nil
    me.weapon_go_addr, me.weapon_sc, me.player_sc, me.flashlight = 0, nil, nil, nil
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
    if a ~= me.go_addr then
        forget_player()
        me.pc, me.go, me.go_addr = pc, go, a
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
        local c = go:call("get_Transform"):call("get_Child")
        while c do
            local cgo = c:call("get_GameObject")
            if cgo and cgo:call("get_Name") == "PlayerFlashLightController" then
                me.flashlight = cgo:call("getComponent(System.Type)", TYPE_FLASHLIGHT)
            end
            c = c:call("get_Next")
        end
        say("player %s in %s (%d joints)", me.kind, me.chapter, #me.joints)
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
local MSG_BOX, MSG_SAVE = 22, 23
local MSG_GIMMICK_TRIGGER = 24
local FLAG_CUTSCENE = 64
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
    local n, pos
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
    local x, y, z, qx, qy, qz, qw, rx, ry, rz, hx, hy, hz, n, pos
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
    local by_name = {}
    local js = rtr:call("get_Joints")
    for _, j in ipairs(js and js:get_elements() or {}) do by_name[j:call("get_Name")] = j end
    self.jmap = {}
    for i, n in ipairs(self.appear.names) do self.jmap[i] = by_name[n] or false end
    self.j_root, self.j_hip = by_name["root"], by_name["Hip"]
    self.state = "ready"
    say("%s's character is ready (%d parts)", self.name, #self.parts)
end

function Puppet:apply(pos, rot, s_a, s_b, f)
    local rtr = self.root:call("get_Transform")
    rtr:call("set_Position", pos)
    rtr:call("set_Rotation", rot)
    local ja, jb = s_a.j, s_b.j
    for i, j in ipairs(self.jmap) do
        if j and ja[i] then
            j:call("set_LocalRotation", (jb[i] and f > 0) and ja[i]:slerp(jb[i], f) or ja[i])
        end
    end
    if self.j_root then self.j_root:call("set_LocalPosition", s_a.root + (s_b.root - s_a.root) * f) end
    if self.j_hip then self.j_hip:call("set_LocalPosition", s_a.hip + (s_b.hip - s_a.hip) * f) end
end

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

local function rig_enable(rig, spot, point, extras)
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
local box_ctrl, box_reset, saves_ctrl -- set in the "item box" and "saving together" sections
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
    if box_reset then box_reset() end
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
        local key = appearance_key(a)
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
    elseif (kind == MSG_DOOR or kind == MSG_ITEM_TAKEN) and world_ctrl then
        world_ctrl(from, kind, data)
    elseif (kind == MSG_GIMMICK or kind == MSG_GIMMICK_FLAGS or kind == MSG_GIMMICK_TRIGGER) and gimmick_ctrl then
        gimmick_ctrl(from, kind, data)
    elseif kind == MSG_STORY and story_ctrl then
        story_ctrl(from, kind, data)
    elseif kind == MSG_BOX and box_ctrl then
        box_ctrl(from, kind, data)
    elseif kind == MSG_SAVE and saves_ctrl then
        saves_ctrl(from, kind, data)
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
local session = { last_members = "", next_ping = 0, next_send = 0, next_join_poll = 0, status = nil }

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

local function spawn_control(e)
    if e.ctl == nil then
        local sd = character_manager():call("getSpawnDataRef", e.ctx:call("get_ID"))
        e.ctl = sd and sd:call("get_SpawnControl") or false
    end
    return e.ctl or nil
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
local function puppetize(id, e)
    local ctl = spawn_control(e)
    local go = ctl and ctl:call("getSpawnInstance")
    if go == nil or not ctl:call("get_HasCompletedSpawn") or not go:call("get_UpdateSelf") then return end
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
    if js == nil then return nil end
    j = { list = js:get_elements(), names = {}, kind = kind }
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
                live[#live + 1] = { id = id, e = e, go = go, pos = pos, d = ppos and (pos - ppos):length() or 0 }
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
-- Pure, so tools/test_owner_decision.lua can check it outside the game.
local function owner_decision(cur, together, dead, dme, dpeer)
    if not together then return true end
    if dead then
        if cur == nil then return true end
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
    local function decide(id, pos, dead)
        seen[id] = true
        local cur = foes.owner[id]
        local want = owner_decision(cur, together, dead, together and (pos - my):length() or 0, together and (pos - ppos):length() or 0)
        if want ~= cur then
            set_owner(id, want)
            changes[#changes + 1] = { id, not want } -- sent from the guest's point of view
        end
    end
    for id, e in pairs(foes.index) do
        if e.ctx:call("get_IsSpawn") then
            local go = e.ctx:call("get_GameObject")
            if go then decide(id, go:call("get_Transform"):call("get_Position"), e.ctx:call("get_IsDead")) end
        end
    end
    for id, pr in pairs(foes.presence) do
        if not seen[id] and t_now - pr.t < 1.5 then decide(id, pr.pos, pr.dead) end
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
    local x, y, z, qx, qy, qz, qw, pos
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
        -- this game counts it as dead and plays the death itself
        if e and foes.owner[id] == false and st.flags & F_DEAD ~= 0 and not st.killed then
            st.killed = true
            if foes.puppets[id] then release_puppet(id, true) end
            if e.ctx:call("get_IsSpawn") and not e.ctx:call("get_IsDead") then
                local hp = e.ctx:call("get_HitPoint")
                local cur = hp and hp:call("get_CurrentHitPoint") or 0
                apply_damage(e, 0, math.max(1, cur) + 100, false, true)
            end
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
                    if ctl then ctl_request(ctl, st.tries % 2 == 1 and "requestSpawn" or "requestResume") end
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
                if foes.puppets[id] == nil then puppetize(id, e) end
                local st = foes.states[id]
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
    for _, j in ipairs(js and js:get_elements() or {}) do by[j:call("get_Name")] = j end
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
-- Doors (app.GmDoorV3) swing open when pushed: one GmDoorV3.addForce(RequestInfo) call. Every push
-- here (except the door's own auto-close) is sent to the partner, whose game pushes the same door the
-- same way. Pickups: when an item (app.ItemCore) is picked up here, the partner's copy of it is
-- despawned through its ItemContext (set_IsSpawn(false)), the way the game removes taken items.
-- Doors and items are matched by their scene GUIDs (GimmickCore / ItemCore context IDs). Items made
-- at runtime (enemy drops) have per-PC IDs and aren't shared. Key-locked doors aren't unlocked for
-- the partner yet.
local world, world_shared, world_late
do
local DOOR_AUTO_CLOSE = 1
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
    stats = { doors_sent = 0, doors_applied = 0, items_sent = 0, items_applied = 0 },
}

world_reset = function()
    world.doors, world.door_ids, world.items, world.item_ids = {}, {}, {}, {}
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

world_shared = function()
    if me.go == nil or not cfg.world_sync then return false end
    if _G.re9coop_test_shared then return true end -- dev bridge only
    if loopback then return true end
    local st_net = session.status
    return st_net ~= nil and st_net.state == "in_lobby" and session.last_members ~= ""
end

sdk.hook(M_DOOR_FORCE, function(args)
    if world.applying or not world_shared() then return end
    local id = world.door_ids[sdk.to_int64(args[2])]
    if id == nil then return end
    local t = now()
    if t - (world.applied_at[id] or -10) < 0.5 or t - (world.sent_at[id] or -10) < 0.15 then return end
    local info = sdk.to_managed_object(args[3])
    if info == nil then return end
    local action = info:get_field("ActionType")
    if action == DOOR_AUTO_CLOSE or #world.out >= 32 then return end
    world.sent_at[id] = t
    world.out[#world.out + 1] = string.pack("<Bs1s1BfI4", MSG_DOOR, me.chapter, id, action or 0,
        info:get_field("Force") or 1.0, (info:get_field("ForceDir") or 1) & 0xFFFFFFFF)
end, nil)

sdk.hook(M_ITEM_PICKED, function(args)
    if world.applying or not world_shared() or (sdk.to_int64(args[3]) & 1) == 0 then return end
    local id = world.item_ids[sdk.to_int64(args[2])]
    if id and #world.out < 32 then
        world.out[#world.out + 1] = string.pack("<Bs1s1", MSG_ITEM_TAKEN, me.chapter, id)
    end
end, nil)

world_ctrl = function(from, kind, data)
    if not world_shared() then return end
    refresh_world(now())
    if kind == MSG_DOOR then
        local _, chapter, id, action, force, dir = string.unpack("<Bs1s1BfI4", data)
        local door = chapter == me.chapter and world.doors[id]
        if not door then return end
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
    if #world.out == 0 then return end
    local out = world.out
    world.out = {}
    for _, blob in ipairs(out) do
        local kind = string.byte(blob, 1)
        send_ctrl(blob)
        if kind == MSG_DOOR then
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
    local pos = s.pos + s.rot * Vector3f.new(0, 0, -1.0)
    local cm = character_manager()
    local ok = pcall(cm.call, cm, WARP_SIG, me.pc:call("get_ID"), nullable_vec3(pos), nullable_quat(s.rot))
    return ok and ("went to " .. p.name) or "couldn't move you"
end

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

gim = {
    fields = {},          -- structure type name -> { {name, tag}, ... } (logical fields only)
    sig = {},             -- context id -> last known fingerprint
    sent_at = {},         -- context id -> last send time (rate limit)
    applied_at = {},      -- context id -> when we applied the partner's state (our game's rewrite isn't news)
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
                if not fl:is_static() then
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
    for _, x in ipairs(arr and arr:get_elements() or {}) do
        local tname, fields = logical_fields(x)
        for _, fd in ipairs(fields) do
            local ok, v = pcall(x.get_field, x, fd[1])
            if ok and v ~= nil then
                local num = fd[2] == T_BOOL and (v and 1 or 0) or (type(v) == "number" and math.floor(v) or 0)
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
        gim.contexts = arr and arr:get_elements() or {}
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
                if old ~= nil and old ~= sig and not echo and #entries > 0 and t_now - (gim.sent_at[id] or -10) > 0.5 and #gim.out < 64 then
                    gim.sent_at[id] = t_now
                    gim.out[#gim.out + 1] = pack_gimmick(id, entries, false)
                end
            end
        end
    end
end


local function apply_gimmick(data)
    local _, chapter, id, full, n, pos = string.unpack("<Bs1s1BH", data)
    if chapter ~= me.chapter then return end
    local want = {}
    for _ = 1, n do
        local tname, fname, tag, v
        tname, fname, tag, v, pos = string.unpack("<s1s1Bi8", data, pos)
        want[tname] = want[tname] or {}
        want[tname][fname] = tag == T_BOOL and (v ~= 0) or v
    end
    gimmick_contexts(now())
    local gc = gim.by_id[id]
    if gc == nil or (world.doors[id] and not full) then return end
    local sdc = gc:call("get_SDC")
    local list = sdc and sdc:get_field("_Structures")
    local count = list and list:call("get_Count") or 0
    local changed = false
    gim.applying = true
    for i = 0, count - 1 do
        local x = list:call("get_Item", i)
        local w = x and want[x:get_type_definition():get_full_name()]
        if w then
            local dirty = false
            for fname, v in pairs(w) do
                local ok, cur = pcall(x.get_field, x, fname)
                if ok and cur ~= v then
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
    local ok, _, sig = pcall(gimmick_state, gc)
    if ok then gim.sig[id] = sig end -- what we now have is not a change of ours
end

-- key-item triggers worth replaying: the outcome of using an item, never player input
local function key_outcome(name)
    return type(name) == "string" and (name:find("^UseKeyItem_Success") or name:find("^UseKeyItem_Use")) ~= nil
end

local TYPE_KEY_HOLDER = sdk.typeof("app.InteractTriggerKeyItemInventoryHolder")
local TYPE_LOCK = sdk.typeof("app.GmLockV2")
local TYPE_CORE = sdk.typeof("app.GimmickCore")
local M_TRIGGER_PROCESS = sdk.find_type_definition("app.InteractTrigger"):get_method("onProcessEvent(via.GameObject)")
local SIG_TRIGGER_PROCESS = "onProcessEvent(via.GameObject)"

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
    -- the triggers on `go` (every holder on it) whose names pass `want`
    local function add(go, want)
        local core = go and go:call("getComponent(System.Type)", TYPE_CORE)
        local ok, id = pcall(function() return core:call("get_ContextID"):call("ToString") end)
        if not ok or not id then return end
        local lock = go:call("getComponent(System.Type)", TYPE_LOCK)
        for _, c in ipairs(go:call("get_Components"):get_elements()) do
            local okt, trs = pcall(function() return c:get_field("_Triggers"):get_elements() end)
            for _, t in ipairs(okt and trs or {}) do
                local name = t:get_field("_Name")
                if want(name) then
                    ti.by_addr[t:get_address()] = { id = id, name = name }
                    ti.by_key[id .. "|" .. name] = { trig = t, go = go, lock = lock }
                end
            end
        end
    end
    for _, h in ipairs(world.scene_components(TYPE_KEY_HOLDER)) do add(h:call("get_GameObject"), key_outcome) end
    for _, lock in ipairs(world.scene_components(TYPE_LOCK)) do
        local names = {}
        local okp, params = pcall(function() return lock:get_field("_UnlockParams"):get_elements() end)
        for _, prm in ipairs(okp and params or {}) do
            local n = prm:get_field("_TriggerName")
            if n and n ~= "" and n ~= "Interact" then names[n] = true end
        end
        if next(names) then add(lock:call("get_GameObject"), function(n) return names[n] == true end) end
    end
    return ti
end

local function replayable(name)
    return key_outcome(name) or name == "TurnOff" or name == "Unlock"
end

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
    if #gim.out < 64 then
        gim.out[#gim.out + 1] = string.pack("<Bs1s1s1", MSG_GIMMICK_TRIGGER, me.chapter, e.id, e.name)
        gim.stats.live_sent = gim.stats.live_sent + 1
    end
end, nil)

-- a lock that is open already (its data says so) isn't opened again
local function lock_open(lock)
    local ok, open = pcall(function()
        local d = lock:get_field("_GmLockData")
        return d:get_field("_UnlockCount") >= d:get_field("_MaxUnlockCount") and lock:get_field("_GmBaseData"):get_field("_IsDone")
    end)
    return ok and open == true
end

local function apply_trigger(data)
    local _, chapter, id, name = string.unpack("<Bs1s1s1", data)
    if chapter ~= me.chapter then return end
    local key = id .. "|" .. name
    local t_now = now()
    local e = trigger_index(t_now).by_key[key] or trigger_index(t_now, true).by_key[key]
    if e == nil then return "missing" end -- not indexed (yet), or not loaded here
    if e.lock and lock_open(e.lock) then return end
    gim.trigger_applying = true
    pcall(e.trig.call, e.trig, SIG_TRIGGER_PROCESS, e.go)
    gim.trigger_applying = false
    gim.applied_at[id] = now()
    gim.stats.live_applied = gim.stats.live_applied + 1
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
    gim.queue[#gim.queue + 1] = { kind = kind, data = data }
end

-- the partner's gimmick messages, applied inside the game's GUI update
gim.gui_tick = function()
    if #gim.queue == 0 or not world_shared() then return end
    local queue = gim.queue
    gim.queue = {}
    for i, m in ipairs(queue) do
        if i > 40 then -- the rest next frame (a full sync is ~500 messages)
            for j = i, #queue do gim.queue[#gim.queue + 1] = queue[j] end
            break
        end
        local ok, err
        if m.kind == MSG_GIMMICK then
            ok, err = pcall(apply_gimmick, m.data)
        elseif m.kind == MSG_GIMMICK_FLAGS then
            ok, err = pcall(apply_gimmick_flags, m.data)
        elseif m.kind == MSG_GIMMICK_TRIGGER then
            ok, err = pcall(apply_trigger, m.data)
            -- the gimmick may not be indexed yet: try again for 10 s (if it isn't loaded here at all,
            -- its data follows with the state sync)
            if ok and err == "missing" then
                m.till = m.till or now() + 10
                if now() < m.till then gim.queue[#gim.queue + 1] = m end
            end
        end
        if ok == false then say("gimmick error: %s", tostring(err)) end
    end
end

gimmick_reset = function()
    gim.sig, gim.sent_at, gim.applied_at, gim.contexts, gim.cursor, gim.out = {}, {}, {}, nil, 1, {}
    gim.queue, gim.triggers, gim.trig_sent = {}, { by_addr = {}, by_key = {}, t = 0, chapter = "", forced = 0 }, {}
    gim.ids, gim.by_id = {}, {}
    gim.full_pending, gim.full_done_for, gim.flags_sent = nil, nil, { -1, -1 }
end

gimmicks_late = function(t_now)
    if not world_shared() or not cfg.gimmick_sync then return end
    gimmick_scan(t_now)
    local st_net = session.status
    local partner = partner_to_follow and partner_to_follow()
    if st_net and st_net.is_host and partner and partner.id ~= LOOPBACK_ID and partner.chapter == me.chapter then
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

local function progress_list()
    local lf = level_flow()
    local d = lf and lf:get_field("_ProgressiveNumberList")
    local entries = d and d:get_field("_entries")
    local n = d and d:get_field("_count") or 0
    local out = {}
    if entries then
        for i, e in ipairs(entries:get_elements()) do
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

local function apply_story(data)
    local _, chapter, hash, value = string.unpack("<Bs1I4i4", data)
    if chapter ~= me.chapter then return end
    local lf = level_flow()
    if lf == nil then return end
    local ok, cur = pcall(lf.call, lf, "getProgressiveNumber", hash)
    if ok and cur == value then return end
    story.expect[hash] = value
    pcall(lf.call, lf, "requestChangeProgressiveNumber", hash, value)
    story.stats.applied = story.stats.applied + 1
end

local function jump_to_chapter(name)
    local mg = sdk.get_managed_singleton("app.MainGameFlowManager")
    local lf = level_flow()
    if mg == nil or lf == nil then return false end
    pcall(mg.call, mg, "setOverrideNextJumpScene", name)
    pcall(lf.call, lf, "requestGameJump")
    story.stats.jumps = story.stats.jumps + 1
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

story_ctrl = function(from, kind, data)
    if not world_shared() or not cfg.story_sync then return end
    if kind == MSG_STORY then pcall(apply_story, data) end
end

story_reset = function()
    story.expect, story.out, story.full_done_for = {}, {}, nil
end

story_late = function(t_now)
    if not world_shared() and not _G.re9coop_test_host then return end
    local st_net = session.status
    -- the lobby owner sends every flow that has moved, once per partner per chapter
    local partner = partner_to_follow and partner_to_follow()
    if cfg.story_sync and st_net and st_net.is_host and partner and partner.id ~= LOOPBACK_ID
        and partner.chapter == me.chapter and story.full_done_for ~= partner.id then
        story.full_done_for = partner.id
        local n = 0
        for hash, value in pairs(progress_list()) do
            if value ~= 0 then
                send_ctrl(string.pack("<Bs1I4i4", MSG_STORY, me.chapter, hash, value), partner.id)
                n = n + 1
            end
        end
        say("sent %d story steps to your partner", n)
        story.stats.sent = story.stats.sent + n
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
local box, box_late
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
    stats = { sent = 0, applied = 0 },
}

local function box_inventories()
    local m = sdk.get_managed_singleton("app.InventoryManager")
    local d = m and m:get_field("_Inventories")
    local entries = d and d:get_field("_entries")
    local n = d and d:get_field("_count") or 0
    local out = {}
    if entries == nil then return out end
    for i, e in ipairs(entries:get_elements()) do
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
    for _, c in ipairs(li and li:get_elements() or {}) do
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
    local sts = inv:call("getPanelStates")
    for _, st in ipairs(sts and sts:get_elements() or {}) do
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
    local t = { string.pack("<Bs1BH", MSG_BOX, key, flag, #ops) }
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

local function apply_ops(inv, ops)
    local list = read_box(inv)
    for _, op in ipairs(ops) do
        local sign, body = op:sub(1, 1), op:sub(2)
        if sign == "-" then
            for i, x in ipairs(list) do
                if x.id == body then
                    pcall(inv.call, inv, SIG_REMOVE, x.key, EVENT_MOVED)
                    table.remove(list, i)
                    break
                end
            end
        elseif sign == "+" and not add_entry(inv, body) then
            say("couldn't put %s in the box", body:match("^[^|]*"))
        end
    end
    box.stats.applied = box.stats.applied + 1
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

-- true while one of the item boxes here is in use (its menu may be open)
local function box_in_use(t_now)
    if t_now >= box.gimmicks_t or box.gimmicks_chapter ~= me.chapter then
        box.gimmicks_t, box.gimmicks_chapter = t_now + 5, me.chapter
        box.gimmicks = world.scene_components(TYPE_BOX_GIMMICK)
    end
    for _, g in ipairs(box.gimmicks) do
        local ok, idle = pcall(g.call, g, "get_IsStepTypeNone")
        if ok and idle == false then return true end
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
    if #ops_here > 0 then apply_ops(inv, ops_here) end
    if #ops_there > 0 then send_ctrl(pack_box(key, FLAG_OPS, ops_there), from) end
    say("item box %s: got %d, sent %d", key, #ops_here, #ops_there)
end

box_ctrl = function(from, kind, data)
    -- our own echo (self test) would put everything in twice
    if from == LOOPBACK_ID or not world_shared() or not cfg.box_sync then return end
    local _, key, flag, n, pos = string.unpack("<Bs1BH", data)
    local ops = {}
    for i = 1, n do ops[i], pos = string.unpack("<s2", data, pos) end
    if #box.queue < 256 then box.queue[#box.queue + 1] = { key = key, flag = flag, ops = ops, from = from } end
end

box_reset = function()
    box.gimmicks, box.gimmicks_t = {}, 0
end

box_late = function(t_now)
    if not world_shared() or not cfg.box_sync or EVENT_MOVED == nil or t_now < box.next_scan then return end
    box.next_scan = t_now + 0.5
    local invs = box_inventories()
    -- our own changes first, so the partner's below aren't taken for ours
    for key, inv in pairs(invs) do
        local list, counts = read_box(inv)
        local old = box.known[key]
        box.known[key] = counts
        if old then
            local ops = diff_ops(old, list, counts)
            if #ops > 0 then
                send_ctrl(pack_box(key, FLAG_OPS, ops))
                box.stats.sent = box.stats.sent + 1
            end
        end
    end
    -- the partner's, when no box is open here
    if #box.queue > 0 and not box_in_use(t_now) then
        local queue = box.queue
        box.queue = {}
        for _, m in ipairs(queue) do
            local inv = invs[m.key]
            if inv then
                local ok, err
                if m.flag == FLAG_JOIN then
                    ok, err = pcall(join_merge, m.key, inv, m.ops, m.from)
                else
                    ok, err = pcall(apply_ops, inv, m.ops)
                end
                if not ok then say("box error: %s", tostring(err)) end
                local _, counts = read_box(inv)
                box.known[m.key] = counts
            end
        end
    end
    -- the lobby owner sends its boxes once to a partner who joins
    local st_net = session.status
    local partner = partner_to_follow and partner_to_follow()
    if st_net and st_net.is_host and partner and partner.id ~= LOOPBACK_ID and box.full_done_for ~= partner.id then
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
        local ok, err = pcall(box_late, now())
        if not ok then say("item box error: %s", tostring(err)) end
        ok, err = pcall(gim.gui_tick)
        if not ok then say("gimmick error: %s", tostring(err)) end
    end, nil)
end

-- dev
box.read_box, box.box_inventories, box.pack_box = read_box, box_inventories, pack_box
end

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
    for i, e in ipairs(entries and entries:get_elements() or {}) do
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

saves_ctrl = function(from, kind, data)
    local st_net = session.status
    if not world_shared() or not cfg.save_with_host or not st_net or from ~= st_net.owner or st_net.is_host then return end
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
                send_ctrl(string.pack("<Bs1", MSG_SAVE, me.chapter))
                saves.stats.sent = saves.stats.sent + 1
                say("saved: your partner's game saves too")
            end
        end
    end
    -- the guest: save once we can
    local p = saves.pending
    if p and can_save_now() then
        saves.pending = nil
        make_save()
    elseif p and t_now - p.since > 300 then
        saves.pending = nil
        say("couldn't save with the host (no chance to in 5 minutes)")
    end
end

-- dev: the slot a serial number went to, and a save the guest way
saves.slot_of_serial, saves.make_save, saves.can_save_now = slot_of_serial, make_save, can_save_now
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
            net.join(lobby)
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
    if not cfg.nametags then return end
    for _, p in pairs(peers) do
        local pup = p.puppet
        if pup and pup.state == "ready" and pup.visible then
            local hp = pup:head_position()
            local sp = hp and draw.world_to_screen(hp + Vector3f.new(0, 0.35, 0))
            if sp then
                local last = p.snaps[#p.snaps]
                local hp = (last and last.hp_max and last.hp_max > 0) and string.format("  %d%%", math.floor(last.hp * 100 / last.hp_max)) or ""
                local label = p.name .. hp .. (p.rtt and string.format("  %d ms", math.floor(p.rtt * 1000)) or "")
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
        if imgui.button("Leave") then
            send_ctrl(string.pack("<B", MSG_BYE))
            net.leave()
        end
    elseif st.state == "creating" or st.state == "joining" then
        imgui.text("...")
    else
        if imgui.button("Host a co-op session") then net.host(2, cfg.public_lobby and 2 or 1) end
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
                    if imgui.button("Join " .. f.name .. "##" .. f.id) then net.join(f.lobby) end
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
        if imgui.button("Join by ID") and ui.join_id ~= "" then net.join(ui.join_id) end
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

    imgui.separator()
    local c, v = imgui.checkbox("Self test (see your own echo next to you)", loopback)
    if c then set_loopback(v) end
    local changed = false
    c, v = imgui.checkbox("Self test: echo faces you", cfg.loopback_face); if c then cfg.loopback_face, changed = v, true end
    c, v = imgui.checkbox("Partner's muzzle flash and gun sounds", cfg.shot_fx); if c then cfg.shot_fx, changed = v, true end
    c, v = imgui.checkbox("Share enemies (both players need it on)", cfg.enemy_sync); if c then cfg.enemy_sync, changed = v, true end
    c, v = imgui.checkbox("Share doors and pickups", cfg.world_sync); if c then cfg.world_sync, changed = v, true end
    c, v = imgui.checkbox("Share locks, puzzles and switches", cfg.gimmick_sync); if c then cfg.gimmick_sync, changed = v, true end
    c, v = imgui.checkbox("Share story progress (experimental)", cfg.story_sync); if c then cfg.story_sync, changed = v, true end
    c, v = imgui.checkbox("Follow the host to new chapters (guest)", cfg.follow_host); if c then cfg.follow_host, changed = v, true end
    c, v = imgui.checkbox("One item box for both players", cfg.box_sync); if c then cfg.box_sync, changed = v, true end
    c, v = imgui.checkbox("Save when the host saves (guest; an autosave)", cfg.save_with_host); if c then cfg.save_with_host, changed = v, true end
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
    go_to_partner_chapter = go_to_partner_chapter, box = box, box_ctrl = box_ctrl, saves = saves,
    saves_ctrl = saves_ctrl, gimmick_ctrl = gimmick_ctrl }
