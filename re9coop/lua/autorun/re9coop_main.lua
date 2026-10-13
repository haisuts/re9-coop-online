-- RE9 Co-op: online co-op for Resident Evil Requiem over Steam   (v0.1.0)
--
-- Your Steam friend appears in your game as a fully posed character (their own costume, every move
-- they make), and you appear in theirs. Steam lobby + peer-to-peer through Steam's relay network.
--
-- Needs REFramework and reframework/plugins/re9coop_net.dll (the Steam part).
-- Menu: REFramework (Insert) -> Script Generated UI -> "RE9 Co-op (online)".
--
-- How it works: each game reads its own player's skeleton (68 joints) after animation, packs it
-- (~600 bytes) and sends it 20 times a second. The other game builds a "puppet" from the same
-- montage parts (body, head, hair...) and the same skeleton file, and plays the pose back with a
-- small buffer so it moves smoothly. The puppet has no AI and no collision: v0.1 doesn't share
-- enemies, items or doors yet (see README).

local VERSION = "0.1.0"
local PROTO = 1
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
local T_APP = sdk.find_type_definition("via.Application")

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
}

local on_player_lost -- set below: puppets are rebuilt whenever our player object goes away

local function forget_player()
    if me.go ~= nil and on_player_lost then on_player_lost() end
    me.pc, me.go, me.go_addr = nil, nil, 0
    me.joints, me.names, me.j_root, me.j_hip = nil, nil, nil, nil
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
    if not ok or id == nil or not id:match("^arm") then return "", "" end
    local c = go:call("get_Transform"):call("get_Child")
    while c do
        local cgo = c:call("get_GameObject")
        if cgo and cgo:call("get_Name") == id then
            local mesh = cgo:call("getComponent(System.Type)", TYPE_MESH)
            local mh = mesh and mesh:call("getMesh")
            local mt = mesh and mesh:call("get_Material")
            return mh and mh:call("get_ResourcePath") or "", mt and mt:call("get_ResourcePath") or ""
        end
        c = c:call("get_Next")
    end
    return "", ""
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
        say("player %s in %s (%d joints)", me.kind, me.chapter, #me.joints)
    end
    return true
end

-------------------------------------------------------------------------------------------------
-- wire format (string.pack, little endian)
-------------------------------------------------------------------------------------------------
local MSG_HELLO, MSG_APPEAR, MSG_POSE, MSG_PING, MSG_PONG, MSG_BYE, MSG_REQ_APPEAR, MSG_WEAPON = 1, 2, 3, 4, 5, 6, 7, 8
local CH_CTRL, CH_POSE = 0, 1

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

function Puppet:head_position()
    if self.state ~= "ready" then return nil end
    local t = self.root:call("get_Transform")
    local j = t:call("getJointByName", "Head_0") or t:call("getJointByName", "Head")
    return j and j:call("get_Position") or nil
end

function Puppet:destroy()
    self.jmap, self.j_root, self.j_hip, self.weapon_meshc = nil, nil, nil, nil
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

-- A load screen or chapter change can tear down scene objects, ours included; never keep
-- references across it.
on_player_lost = function()
    for _, p in pairs(peers) do
        if p.puppet then p.puppet:destroy() p.puppet = nil end
        p.snaps = {}
    end
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
end

-- Sample the snapshot buffer at render time (sender's clock) and drive the puppet.
local function update_peer(p, t_now)
    if p.appear == nil or me.go == nil then return end
    if p.puppet == nil then p.puppet = Puppet.new(p.id == LOOPBACK_ID and "echo" or p.id, p.appear) end
    local pup = p.puppet
    pup:build_step()
    if pup.state ~= "ready" then return end
    if p.weapon then pup:set_weapon(p.weapon.mesh, p.weapon.mat) end
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
        local ok, mesh, mat = pcall(read_weapon, me.pc, me.go)
        if ok then
            local blob = string.pack("<Bs2s2", MSG_WEAPON, mesh, mat)
            if blob ~= me.weapon_blob then
                me.weapon_blob = blob
                send_ctrl(blob)
            end
        end
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
    local ok, err = pcall(tick_send, now())
    if not ok then say("send error: %s", tostring(err)) end
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

    imgui.separator()
    local c, v = imgui.checkbox("Self test (see your own echo next to you)", loopback)
    if c then set_loopback(v) end
    local changed = false
    c, v = imgui.checkbox("Self test: echo faces you", cfg.loopback_face); if c then cfg.loopback_face, changed = v, true end
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
_G.re9coop = { peers = function() return peers end, me = me, set_loopback = set_loopback, cfg = cfg }
