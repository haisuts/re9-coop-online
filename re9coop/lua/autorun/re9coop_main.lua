-- RE9 Co-op: online co-op for Resident Evil Requiem over Steam   (v0.3.0)
--
-- Your Steam friend appears in your game as a fully posed character (their own costume, every move
-- they make, their gun, its muzzle flash and sounds), and you appear in theirs. The host's enemies
-- are shared: the guest's game shows the same enemies doing what they do on the host, and the guest's
-- shots hurt them on the host. Steam lobby + peer-to-peer through Steam's relay network.
--
-- Needs REFramework and reframework/plugins/re9coop_net.dll (the Steam part).
-- Menu: REFramework (Insert) -> Script Generated UI -> "RE9 Co-op (online)".
--
-- How it works:
-- * Players: each game reads its own player's skeleton (68 joints) after animation and sends it 20
--   times a second (~600 bytes). The other game builds a "puppet" from the same montage parts and
--   skeleton file and plays the pose back through a small buffer.
-- * Enemies (host = lobby owner): the host sends every spawned enemy's state 15 times a second (the
--   nearest few with their full skeleton). On the guest each enemy is spawned through its own spawn
--   control, its AI (think + lock-on drivers) is switched off, and it is warped and posed from the
--   host's data. Damage the guest deals (HitPoint.addDamageHitPoint / addDamageReactionHP) is caught
--   before it lands and sent to the host, which applies it to the real enemy.

local VERSION = "0.3.0"
local PROTO = 2
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
    flash_intensity = 6000,
    flash_radius = 6.0,
    enemy_sync = true,        -- share the host's enemies
    enemy_hz = 15,            -- enemy updates per second (host)
    enemy_posed = 4,          -- how many enemies nearest to the guest get their full skeleton
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
}

local on_player_lost -- set below: puppets are rebuilt whenever our player object goes away

local function forget_player()
    if me.go ~= nil and on_player_lost then on_player_lost() end
    me.pc, me.go, me.go_addr = nil, nil, 0
    me.joints, me.names, me.j_root, me.j_hip = nil, nil, nil, nil
    me.weapon_go_addr, me.weapon_sc, me.player_sc = 0, nil, nil
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
    return head .. string.pack("<" .. string.rep("h", #q), table.unpack(q))
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

-- Muzzle flash: a short burst of warm point light at the gun. The game's own muzzle-flash effect
-- can't be used here (handing it the puppet's bare gun object crashed the game).
function Puppet:flash(t_now)
    if self.state ~= "ready" or not self.visible then return end
    if self.light == nil then
        local go = M_GO_CREATE:call(nil, "re9coop_" .. self.name .. "_flash")
        if go == nil then return end
        self.light_go = go:add_ref()
        local light = go:call("createComponent(System.Type)", TYPE_POINTLIGHT)
        if light == nil then return end
        self.light = light
        local t = go:call("get_Transform")
        t:call("setParent(via.Transform, System.Boolean)", self.root:call("get_Transform"), false)
        t:call("set_ParentJoint", "R_Wep")
        t:call("set_LocalPosition", Vector3f.new(0, 0, 0))
        light:call("set_Color", Vector3f.new(1.0, 0.72, 0.38))
        light:call("set_ShadowEnable", false)
    end
    self.light:call("set_Radius", cfg.flash_radius)
    self.light:call("set_Intensity", cfg.flash_intensity)
    self.light:call("set_Enabled", true)
    self.flash_until = t_now + 0.06
end

function Puppet:update_fx(t_now)
    if self.flash_until and t_now >= self.flash_until then
        self.flash_until = nil
        if self.light then self.light:call("set_Enabled", false) end
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
    self.jmap, self.j_root, self.j_hip, self.weapon_meshc, self.light = nil, nil, nil, nil, nil
    destroy_go(self.light_go)
    destroy_go(self.weapon)
    for _, go in ipairs(self.parts) do destroy_go(go) end
    destroy_go(self.root)
    self.parts, self.root, self.weapon, self.light_go, self.state = {}, nil, nil, nil, "gone"
end

-------------------------------------------------------------------------------------------------
-- remote peers
-------------------------------------------------------------------------------------------------
local LOOPBACK_ID = "1"
local peers = {}          -- steam id string -> peer
local enemy_ctrl, enemy_recv, enemies_reset -- set in the "shared enemies" section
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
    elseif kind >= MSG_ENEMY and kind <= MSG_ENEMY_DAMAGE and enemy_ctrl then
        enemy_ctrl(from, kind, data)
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
    pup:set_visible(#snaps > 0 and not stale and same_place)
    if #snaps == 0 or stale or not same_place then return end
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
end

-------------------------------------------------------------------------------------------------
-- session
-------------------------------------------------------------------------------------------------
local session = { last_members = "", next_ping = 0, next_send = 0, next_join_poll = 0, status = nil }

-------------------------------------------------------------------------------------------------
-- shared enemies (the host decides)
-------------------------------------------------------------------------------------------------
-- Enemy contexts are identified by their scene GUID (app.ContextID), the same on both PCs.
-- Host: every spawned enemy -> MSG_ENEMY (unreliable, CH_ENEMY): id, kind, flags, position,
--   rotation, HP, and for the few nearest the guest the full skeleton.
-- Guest: spawns the same enemy through its spawn control, turns its AI off (think + lock-on +
--   out-of-area drivers), keeps it awake, warps it to the host's position every frame and writes the
--   host's joint rotations after its own animation. Its HitPoint is hooked: damage the guest deals is
--   sent to the host (MSG_ENEMY_DAMAGE) instead of landing here. Enemies the host doesn't have are
--   put away. When co-op ends, every enemy gets its AI back.
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

local foes = {
    role = "off",          -- "host" | "guest" | "off"
    index = {}, index_t = 0, index_chapter = "",  -- id -> { ctx, kind, ctl, orphan_since }
    -- host
    next_send = 0, seq = 0, skel_sent = {}, joints = {},
    -- guest
    states = {},           -- id -> { snaps, last, kind, flags, hp, chapter, next_spawn }
    puppets = {},          -- id -> { e, ctl, go, upd, kind, jmap, j_hip, hp_addr }
    hp_owner = {},         -- HitPoint address -> enemy id (puppets only)
    ctl_owner = {},        -- spawn control address -> enemy id (puppets only)
    self_call = false,     -- true while we call a spawn control ourselves
    names = {},            -- kind -> joint names sent by the host
    asked = {},            -- kind -> when we last asked the host for them
    dmg_out = {},          -- damage caught on puppets, waiting to be sent to the host
    bypass = false,        -- true while the host applies a guest's damage
    stats = { synced = 0, dmg_sent = 0, dmg_applied = 0 },
    -- one-PC test (dev bridge only): with the self test on, enemy `src` is sent through the loopback
    -- and what arrives is applied to enemy `dst`, so dst copies src 150 ms late. { src=id, dst=id }
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
    local list = character_manager() and character_manager():call("get_EnemyContextList")
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
    foes.index, foes.index_t, foes.skel_sent = {}, 0, {}
end

-- Only after the spawn has completed (with AI on): turning AI off earlier leaves it asleep.
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

-- host -------------------------------------------------------------------------------------------

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

local function host_send(t_now, guest)
    if t_now < foes.next_send then return end
    foes.next_send = t_now + 1 / math.max(1, cfg.enemy_hz)
    refresh_index(t_now)
    local gpos = #guest.snaps > 0 and guest.snaps[#guest.snaps].pos or nil
    local live = {}
    for id, e in pairs(foes.index) do
        if (foes.test == nil or id == foes.test.src) and e.ctx:call("get_IsSpawn") then
            local go = e.ctx:call("get_GameObject")
            if go then
                local pos = go:call("get_Transform"):call("get_Position")
                live[#live + 1] = { id = id, e = e, go = go, pos = pos, d = gpos and (pos - gpos):length() or 0 }
            end
        end
    end
    table.sort(live, function(a, b) return a.d < b.d end)
    foes.stats.synced = #live
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
                send_skeleton(x.e.kind, jt.names, guest.id)
            end
        end
        local n = net.send(msg, false, CH_ENEMY, guest.id)
        stats.tx, stats.tx_bytes = stats.tx + n, stats.tx_bytes + #msg * n
    end
    foes.seq = (foes.seq + 1) % 65536
end

local function host_apply_damage(data)
    local _, id, which, dmg, b1, b2 = string.unpack("<Bs1Bi4BB", data)
    if foes.test and id == foes.test.dst then id = foes.test.src end -- one-PC test: hits on the copy land on the original
    local e = foes.index[id]
    if e == nil or not e.ctx:call("get_IsSpawn") then return end
    local hp = e.ctx:call("get_HitPoint")
    if hp == nil then return end
    foes.bypass = true
    pcall(function() hp:call(which == 0 and ADD_HP_SIG or ADD_RHP_SIG, dmg, b1 == 1, b2 == 1) end)
    foes.bypass = false
    foes.stats.dmg_applied = foes.stats.dmg_applied + 1
end

-- guest ------------------------------------------------------------------------------------------

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
    local st_net = session.status
    if foes.role == "test" then
        if from ~= LOOPBACK_ID then return end
    elseif foes.role ~= "guest" or st_net == nil or from ~= st_net.owner then
        return
    end
    local ok, s = pcall(read_enemy, data)
    if not ok then return end
    if foes.role == "test" then
        if s.id ~= foes.test.src then return end
        s.id = foes.test.dst
    end
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
    local st_net = session.status
    if kind == MSG_ENEMY_SKEL then
        local _, k, n, pos = string.unpack("<Bs1B", data)
        local names = {}
        for i = 1, n do names[i], pos = string.unpack("<s1", data, pos) end
        foes.names[k] = names
        for _, pup in pairs(foes.puppets) do
            if pup.kind == k then pup.jmap = nil end
        end
    elseif kind == MSG_REQ_ENEMY_SKEL then
        if foes.role ~= "host" then return end
        local _, k = string.unpack("<Bs1", data)
        for _, j in pairs(foes.joints) do
            if j.kind == k then return send_skeleton(k, j.names, from) end
        end
        foes.skel_sent[k] = nil -- sent with the next pose of that kind
    elseif kind == MSG_ENEMY_DAMAGE then
        if (foes.role == "host" and st_net and st_net.state == "in_lobby") or foes.role == "test" then host_apply_damage(data) end
    end
end

-- Damage the guest deals to a puppet goes to the host instead.
local function forward_damage(which)
    return function(args)
        if foes.bypass or (foes.role ~= "guest" and foes.role ~= "test") then return end
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

-- The guest's own spawn logic puts enemies away by its rules (e.g. a wave spawner every ~10 s, or the
-- guest being far from the spawn area). While the host still has the enemy, refuse.
local function guard_suspend(args)
    if foes.self_call or (foes.role ~= "guest" and foes.role ~= "test") then return end
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

local function host_render_time(t_now)
    local st_net = session.status
    local hp = foes.role == "test" and peers[LOOPBACK_ID] or (st_net and peers[st_net.owner])
    if hp == nil or hp.off == nil then return nil end
    return t_now - hp.off - cfg.interp_delay
end

-- Before animation: spawn / put away / keep awake / warp.
local function guest_tick(t_now)
    refresh_index(t_now)
    local cm = character_manager()
    local rt = host_render_time(t_now)
    for id, st in pairs(foes.states) do
        local e = foes.index[id]
        local fresh = t_now - st.last < 1.0 and st.chapter == me.chapter
        if e then
            local pup = foes.puppets[id]
            local spawned = e.ctx:call("get_IsSpawn")
            if pup and not spawned then -- put to sleep anyway: let go, it gets respawned below
                release_puppet(id, false)
                pup = nil
            end
            if fresh and st.flags & F_SPAWNED ~= 0 then
                if not spawned and pup == nil and t_now >= (st.next_spawn or 0) then
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
    -- every enemy alive here becomes a puppet; the ones the host doesn't have are put away
    for id, e in pairs(foes.index) do
        if (foes.test == nil or id == foes.test.dst) and e.ctx:call("get_IsSpawn") then
            if foes.puppets[id] == nil then puppetize(id, e) end
            local st = foes.states[id]
            if st == nil or t_now - st.last > 1.5 then
                e.orphan_since = e.orphan_since or t_now
                if t_now - e.orphan_since > 1.5 then
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
    for id, pup in pairs(foes.puppets) do
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
end

local function build_jmap(pup)
    local names = foes.names[pup.kind]
    if names == nil then
        local t = now()
        if t - (foes.asked[pup.kind] or 0) > 2 then
            foes.asked[pup.kind] = t
            send_ctrl(string.pack("<Bs1", MSG_REQ_ENEMY_SKEL, pup.kind), session.status and session.status.owner)
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

-- After animation: the host's skeleton over the enemy's own (stepped at the host's send rate).
local function guest_pose(t_now)
    local rt = host_render_time(t_now)
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

local function enemies_role(st_net)
    local role = "off"
    if cfg.enemy_sync and st_net and st_net.state == "in_lobby" and session.last_members ~= "" then
        role = st_net.is_host and "host" or "guest"
    elseif foes.test and loopback then
        role = "test"
    end
    if role ~= foes.role then
        if foes.role == "guest" or foes.role == "test" then enemies_reset(me.go ~= nil) end
        foes.role = role
        say("shared enemies: %s", role)
    end
end

local function the_guest()
    for id, p in pairs(peers) do
        if id ~= LOOPBACK_ID then return p end
    end
end

-- called before animation
local function enemies_update(t_now)
    enemies_role(session.status)
    if (foes.role == "guest" or foes.role == "test") and me.go then guest_tick(t_now) end
end

-- called after animation
local function enemies_late(t_now)
    if me.go == nil then return end
    if foes.role == "host" then
        local g = the_guest()
        if g and g.chapter == me.chapter then host_send(t_now, g) end
    elseif foes.role == "guest" or foes.role == "test" then
        if foes.role == "test" then host_send(t_now, peer(LOOPBACK_ID)) end
        guest_pose(t_now)
        if #foes.dmg_out > 0 then
            local out = foes.dmg_out
            foes.dmg_out = {}
            local to = foes.role == "test" and LOOPBACK_ID or session.status.owner
            for _, blob in ipairs(out) do send_ctrl(blob, to) end
            foes.stats.dmg_sent = foes.stats.dmg_sent + #out
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
end)

re.on_frame(function()
    if not cfg.nametags then return end
    for _, p in pairs(peers) do
        local pup = p.puppet
        if pup and pup.state == "ready" and pup.visible then
            local hp = pup:head_position()
            local sp = hp and draw.world_to_screen(hp + Vector3f.new(0, 0.35, 0))
            if sp then
                local label = p.name .. (p.rtt and string.format("  %d ms", math.floor(p.rtt * 1000)) or "")
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
        if imgui.button("Invite friends (Steam overlay)") then net.invite() end
        imgui.same_line()
        if imgui.button("Leave") then
            send_ctrl(string.pack("<B", MSG_BYE))
            net.leave()
        end
    elseif st.state == "creating" or st.state == "joining" then
        imgui.text("...")
    else
        if imgui.button("Host a co-op session") then net.host(2) end
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
    if foes.role == "host" then
        imgui.text(string.format("Shared enemies: you are the host, %d enemies shared, %d hits from your partner",
            foes.stats.synced, foes.stats.dmg_applied))
    elseif foes.role == "guest" then
        local n = 0
        for _ in pairs(foes.puppets) do n = n + 1 end
        imgui.text(string.format("Shared enemies: following the host, %d enemies here, %d hits sent", n, foes.stats.dmg_sent))
    end

    imgui.separator()
    local c, v = imgui.checkbox("Self test (see your own echo next to you)", loopback)
    if c then set_loopback(v) end
    local changed = false
    c, v = imgui.checkbox("Self test: echo faces you", cfg.loopback_face); if c then cfg.loopback_face, changed = v, true end
    c, v = imgui.checkbox("Partner's muzzle flash and gun sounds", cfg.shot_fx); if c then cfg.shot_fx, changed = v, true end
    c, v = imgui.checkbox("Share the host's enemies (both players need it on)", cfg.enemy_sync); if c then cfg.enemy_sync, changed = v, true end
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
_G.re9coop = { peers = function() return peers end, me = me, set_loopback = set_loopback, cfg = cfg, foes = foes }
