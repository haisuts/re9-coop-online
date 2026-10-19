"""A boss fight on the stand (dev tool; needs tools/stand.py start + coop first).

usage: python tools/stand_boss.py OUT_DIR CHAPTER BOSS_KIND [ARENA_FOLDER]
Both games go to CHAPTER; the arena folder (if given) is activated in both and the boss spawned in the
host's game (as its entrance would: through its spawn control, or permitSpawn + requestSpawn on its
spawn param); whether the mod brings it into the guest's game; both players are put next to it.
For 24 s: who runs it, both players' health (healed back above 300 so nobody dies), then the runner
is put down: the boss should go to the other player. Then the hits of the player who doesn't run it
on its copy (4 x 30%; the boss's no-death cleared first): dead in both games. The mod's error lines
of both logs. -> OUT_DIR/boss_<kind>.json
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stand_sweep as sw  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def lua_file(name):
    return os.path.join(HERE, name)


def run_step(game, kind, step, extra=""):
    code = "dev.ba_kind = '%s' dev.ba_step = '%s' %s return 1" % (kind, step, extra)
    sw.bridge(game, code, 10)
    rc, out = sw.bridge(game, open(lua_file("boss_any.lua"), encoding="utf-8").read(), 20)
    return out


def op_result(game):
    rc, out = sw.bridge(game, "return tostring(dev.op_result and dev.op_result.r)", 10)
    return out


HEAL = ("if not dev.heal_hooked then dev.heal_hooked = true dev.heal_t = 0 "
        "sdk.hook(sdk.find_type_definition('app.GuiAutoSaveFlowController'):get_method('update'), function() "
        "if not dev.heal_on then return end local t = os.clock() if t < dev.heal_t then return end dev.heal_t = t + 0.3 "
        "local pc = _G.re9coop.me.pc local hp = pc and pc:call('get_HitPoint') "
        "if hp and not _G.re9coop.me.down and hp:call('get_CurrentHitPoint') < 300 then dev.heal_n = (dev.heal_n or 0) + 1 "
        "hp:call('set_CurrentHitPoint', hp:call('get_CurrentMaximumHitPoint')) end end, nil) end dev.heal_on = %s return 1")


def warp_near(game, kind, off):
    code = ("dev.op_result = nil dev.op = function() local G = _G.re9coop local cm = sdk.get_managed_singleton('app.CharacterManager') "
            "local list = cm:call('get_EnemyContextList') local bp for i = 0, list:call('get_Count') - 1 do local x = list:call('get_Item', i) "
            "if x:call('get_KindID'):call('ToString') == '%s' and x:call('get_IsSpawn') and not x:call('get_IsDead') then "
            "bp = x:call('get_GameObject'):call('get_Transform'):call('get_Position') end end if not bp or bp.y < -50 then return 'no boss' end "
            "local p = Vector3f.new(bp.x + %f, bp.y + 0.3, bp.z + %f) local q = G.me.go:call('get_Transform'):call('get_Rotation') "
            "local nv = ValueType.new(sdk.find_type_definition('System.Nullable`1<via.vec3>')) nv:write_byte(0, 1) nv:write_float(16, p.x) nv:write_float(20, p.y) nv:write_float(24, p.z) "
            "local nq = ValueType.new(sdk.find_type_definition('System.Nullable`1<via.Quaternion>')) nq:write_byte(0, 1) nq:write_float(16, q.x) nq:write_float(20, q.y) nq:write_float(24, q.z) nq:write_float(28, q.w) "
            "cm:call('requestWarp(app.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>)', G.me.pc:call('get_ID'), nv, nq) return 'warped' end return 1") % (kind, off[0], off[1])
    sw.bridge(game, code, 10)
    time.sleep(1.5)


def dist(game, kind):
    out = run_step(game, kind, "state")
    try:
        return float(out.split("(")[1].split(" m)")[0])
    except (IndexError, ValueError):
        return None


NO_DEATH_OFF = ("dev.op_result = nil dev.op = function() local cm = sdk.get_managed_singleton('app.CharacterManager') "
                "local list = cm:call('get_EnemyContextList') local r = {} for i = 0, list:call('get_Count') - 1 do local x = list:call('get_Item', i) "
                "if x:call('get_KindID'):call('ToString') == '%s' then local nd = x:call('get_HitPoint'):get_field('<NoDeath>k__BackingField') "
                "local was = nd:call('get_Enable') nd:call('applyRequestHashSet(System.UInt32[])', sdk.create_managed_array('System.UInt32', 0)) "
                "r[#r + 1] = tostring(was) .. ' -> ' .. tostring(nd:call('get_Enable')) end end return table.concat(r, ', ') end return 1")


LIFE = "local G = _G.re9coop local hp = G.me.pc:call('get_HitPoint') return string.format('hp %d down %s', hp:call('get_CurrentHitPoint'), tostring(G.me.down))"


def main():
    out_dir, chapter, kind = sys.argv[1], sys.argv[2], sys.argv[3]
    folder = sys.argv[4] if len(sys.argv) > 4 else None
    os.makedirs(out_dir, exist_ok=True)
    res = {"chapter": chapter, "kind": kind, "log": []}

    def note(s):
        print(s, flush=True)
        res["log"].append(s)

    start = {g: sw.log_len(g) for g in sw.GAMES}
    for g in ("1", "2"):
        sw.bridge(g, sw.GUI_OP)
    host_in = sw.in_chapter("1", chapter)
    if not host_in or not sw.in_chapter("2", chapter):
        sw.jump("1", chapter)
        st, sent = sw.wait_both(chapter)
        note("in %s: host %s guest %s (guest sent directly: %s)" % (chapter, bool(st["1"]), bool(st["2"]), sent))
        if not (st["1"] and st["2"]):
            json.dump(res, open(os.path.join(out_dir, "boss_%s.json" % kind), "w"), indent=1)
            return 1
        time.sleep(10)
    for g in ("1", "2"):
        note("game %s find: %s" % (g, run_step(g, kind, "find")))
    if folder:
        for g in ("1", "2"):
            run_step(g, kind, "activate", "dev.ba_folder = '%s'" % folder)
            time.sleep(2)
            note("game %s activate: %s" % (g, op_result(g)))
        time.sleep(4)
    # spawned in the host's game only: the mod should bring it into the guest's (as the host's
    # entrance into the arena would); spawned there by hand if it doesn't
    run_step("1", kind, "spawn")
    time.sleep(3)
    note("game 1 spawn: %s" % op_result("1"))
    time.sleep(8)
    guest_has = "spawn true" in run_step("2", kind, "state")
    res["mod_spawned_in_guest"] = guest_has
    note("in the guest's game by the mod: %s" % guest_has)
    if not guest_has:
        run_step("2", kind, "spawn")
        time.sleep(3)
        note("game 2 spawn by hand: %s" % op_result("2"))
    time.sleep(6)
    for g in ("1", "2"):
        run_step(g, kind, "wake")
        note("game %s boss: %s" % (g, run_step(g, kind, "state")))
    # both players next to it (first offset that lands within 8 m)
    for g, offs in (("1", [(3, 0), (-3, 0), (0, 3), (0, -3)]), ("2", [(4, 1), (-4, 1), (1, 4), (1, -4)])):
        for off in offs:
            warp_near(g, kind, off)
            d = dist(g, kind)
            if d is not None and d < 8:
                break
        note("game %s next to it: %s m" % (g, dist(g, kind)))
    for g in ("1", "2"):
        sw.bridge(g, HEAL % "true", 10)
    for i in range(3):
        time.sleep(8)
        note("t+%ds host [%s] %s | guest [%s] %s" % ((i + 1) * 8, sw.bridge("1", LIFE, 10)[1], run_step("1", kind, "state"),
                                                     sw.bridge("2", LIFE, 10)[1], run_step("2", kind, "state")))
    # the runner down: the boss should go to the other player
    st1 = run_step("1", kind, "state")
    runner = "1" if "runs here true" in st1 else "2"
    other = "2" if runner == "1" else "1"
    for g in ("1", "2"):
        sw.bridge(g, HEAL % "false", 10)
    sw.bridge(runner, "dev.op_result = nil dev.op = function() local hp = _G.re9coop.me.pc:call('get_HitPoint') "
                      "hp:call('addDamageHitPoint(System.Int32, System.Boolean, System.Boolean)', hp:call('get_CurrentHitPoint') + 100, false, true) "
                      "return 'down' end return 1", 10)
    note("runner game %s put down" % runner)
    sw.bridge(other, HEAL % "true", 10)
    for i in range(3):
        time.sleep(6)
        note("down t+%ds host [%s] %s | guest [%s] %s" % ((i + 1) * 6, sw.bridge("1", LIFE, 10)[1], run_step("1", kind, "state"),
                                                          sw.bridge("2", LIFE, 10)[1], run_step("2", kind, "state")))
    # the player who doesn't run it now hits its copy (the hits go to the runner's game): four hits of
    # 30% of its health, 8 s apart, so phase changes (and their scenes) get their chance. A boss
    # before its fight can't die (its NoDeath requests): cleared in both games, as its fight would.
    hitter = "1" if "runs here false" in run_step("1", kind, "state") else "2"
    for g in (("1", "2") if not os.environ.get("KEEP_COPY_NODEATH") else (("2",) if hitter == "1" else ("1",))):
        sw.bridge(g, NO_DEATH_OFF % kind, 10)
        time.sleep(1.5)
        note("game %s no-death: %s" % (g, op_result(g)))
    for i in range(4):
        sw.bridge(hitter, ("dev.op_result = nil dev.op = function() local cm = sdk.get_managed_singleton('app.CharacterManager') "
                           "local list = cm:call('get_EnemyContextList') local n = 0 for i = 0, list:call('get_Count') - 1 do local x = list:call('get_Item', i) "
                           "if x:call('get_KindID'):call('ToString') == '%s' and x:call('get_IsSpawn') and not x:call('get_IsDead') then "
                           "local hp = x:call('get_HitPoint') local d = math.max(1, math.floor(hp:call('get_CurrentMaximumHitPoint') * 0.3)) "
                           "hp:call('addDamageHitPoint(System.Int32, System.Boolean, System.Boolean)', d, false, false) n = n + 1 end end "
                           "return 'hits ' .. n end return 1") % kind, 10)
        time.sleep(8)
        note("hit %d from game %s (%s): host %s | guest %s" % (i + 1, hitter, op_result(hitter), run_step("1", kind, "state"),
                                                              run_step("2", kind, "state")))
    time.sleep(4)
    for g in ("1", "2"):
        note("after the kill game %s: %s" % (g, run_step(g, kind, "state")))
    for g in ("1", "2"):
        res["errors_" + g] = sw.errors(sw.log_since(g, start[g]))
        note("game %s mod errors: %d" % (g, len(res["errors_" + g])))
        sw.shot(g, os.path.join(out_dir, "boss_%s_game%s.png" % (kind, g)))
    json.dump(res, open(os.path.join(out_dir, "boss_%s.json" % kind), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
