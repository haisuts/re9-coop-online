"""Two RE9 games on one PC for co-op tests (dev tool).

    python tools/stand.py setup     # make the second game folder: hard links to the game's files, copies of
                                    # what the game writes (config, shader cache, REFramework folder)
    python tools/stand.py start     # both games: lowest graphics in a 1280x720 window, save guard, dev bridge,
                                    # the LAN test transport (UDP on 127.0.0.1 instead of Steam); launch both
    python tools/stand.py coop      # the first game continues from the latest save and hosts; the second
                                    # joins from its title screen (a co-op playthrough in the host's world)
    python tools/stand.py stop      # kill both (nothing saved), put back the player's own graphics settings,
                                    # remove the guard, the bridge and the LAN files from both

The first game is the Steam install (launched through Steam), the second the folder STAND (launched from
its exe with steam_appid.txt, same Steam account). Both read the same Steam save folder: the save guard
blocks every save in both. Their dev bridges: tools/bridge.py -g <game folder>.
"""
import os
import shutil
import subprocess
import sys
import time

GAME = r"E:\SteamLibrary\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem"
STAND = r"E:\RE9coop_stand\game2"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APPID = "3764200"
# written by the game or REFramework: copied, never linked (a link would let one game overwrite the other's)
COPIED = {"config.ini", "shader.cache2", "piplinelist.bin", "re2_fw_config.txt", "ref_ui.ini",
          "ref_dropdown_status.ini", "reframework_revision.txt"}
SKIPPED = {"re2_framework_log.txt", "re2_framework_log.prev.txt", "reframework_crash.dmp",
           "reframework_accessed_files.txt", "reframework_faulty_files.txt", "reframework_loose_files.txt"}
USER_CONFIG = os.path.join(REPO, "_backup", "config.ini.player")
USER_REF_CONFIG = os.path.join(REPO, "_backup", "re2_fw_config.txt.player")
# REFramework's menu, open at every start unless its state is remembered: open, it keeps keys from the
# game (no cutscene skip, no interact)
REF_MENU = {"REFrameworkConfig_RememberMenuState": "true", "REFrameworkConfig_MenuOpen": "false"}
# lowest graphics, windowed, no frame generation (keys as the game writes them)
LOW = {
    "AOQuality": "Low", "BloomEnable": "False", "ContactShadowEnable": "False", "DepthOfFieldEnable": "False",
    "DynamicShadowEnable": "False", "EffectQuality": "Low", "FilmGrainEnable": "False", "FrameGeneration": "Off",
    "LensDistortionSetting": "OFF", "LensFlareQuality": "Low", "MeshQuality": "LOW", "MotionBlurEnable": "False",
    "ParticleLightingEnable": "False", "RayTracingSetting": "Off", "Resolution": "1280x720", "ShadowCacheEnable": "False",
    "ShadowQuality": "Low", "SSSQuality": "Low", "TextureQuality": "Low", "TextureSamplerQuality": "Bilinear",
    "VolumetricFogQuality": "Low", "VSync": "True", "WindowMode": "Windowed", "DrawQualityPreset": "Custom",
}
LAN = {GAME: ("host", 47101, 47102, "76561190000000001", "76561190000000002", "Host"),
       STAND: ("guest", 47102, 47101, "76561190000000002", "76561190000000001", "Guest")}


def setup():
    n_link = n_copy = 0
    for root, dirs, files in os.walk(GAME):
        rel = os.path.relpath(root, GAME)
        dst_root = os.path.join(STAND, rel) if rel != "." else STAND
        os.makedirs(dst_root, exist_ok=True)
        in_ref = rel == "reframework" or rel.startswith("reframework" + os.sep)
        for f in files:
            if rel == "." and f in SKIPPED:
                continue
            src, dst = os.path.join(root, f), os.path.join(dst_root, f)
            if os.path.exists(dst):
                continue
            if in_ref or (rel == "." and f in COPIED):
                shutil.copy2(src, dst)
                n_copy += 1
            else:
                os.link(src, dst)
                n_link += 1
    with open(os.path.join(STAND, "steam_appid.txt"), "w") as fh:
        fh.write(APPID)
    print("second game at %s: %d links, %d copies" % (STAND, n_link, n_copy))


def write_low(game):
    path = os.path.join(game, "config.ini")
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    out, section = [], ""
    for line in lines:
        if line.startswith("["):
            section = line
        key = line.split("=", 1)[0]
        if section == "[GameOption]" and "=" in line and key in LOW:
            line = key + "=" + LOW[key]
        if section == "[RenderConfig]" and key == "WindowMode":
            line = "WindowMode=Windowed"
        if section == "[RenderConfig]" and key == "NormalWindowResolution":
            line = "NormalWindowResolution=(1280.000000,720.000000)"
        out.append(line)
    open(path, "w", encoding="utf-8", newline="\r\n").write("\n".join(out) + "\n")


def write_ref_menu(game):
    path = os.path.join(game, "re2_fw_config.txt")
    if not os.path.exists(path):
        return
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    out = []
    for line in lines:
        key = line.split("=", 1)[0]
        if key in REF_MENU:
            line = key + "=" + REF_MENU[key]
        out.append(line)
    open(path, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")


def running():
    r = subprocess.run(["tasklist", "/FI", "IMAGENAME eq re9.exe"], capture_output=True, text=True)
    return r.stdout.count("re9.exe")


def start():
    if running():
        print("a game is running: stop it first")
        return 1
    if not os.path.exists(os.path.join(STAND, "re9.exe")):
        setup()
    # the player's own settings, kept once (a second start must not keep the low ones)
    os.makedirs(os.path.dirname(USER_CONFIG), exist_ok=True)
    if not os.path.exists(USER_CONFIG):
        shutil.copy2(os.path.join(GAME, "config.ini"), USER_CONFIG)
    if not os.path.exists(USER_REF_CONFIG) and os.path.exists(os.path.join(GAME, "re2_fw_config.txt")):
        shutil.copy2(os.path.join(GAME, "re2_fw_config.txt"), USER_REF_CONFIG)
    for game, (role, port, peer, me, peer_id, name) in LAN.items():
        write_low(game)
        write_ref_menu(game)
        data = os.path.join(game, "reframework", "data", "re9coop_bridge")
        os.makedirs(data, exist_ok=True)
        open(os.path.join(data, "block_saves.flag"), "w").write("1")
        open(os.path.join(data, "lan.txt"), "w").write(
            "role=%s\nport=%d\npeer=%d\nme=%s\npeer_id=%s\nname=%s\n" % (role, port, peer, me, peer_id, name))
        auto = os.path.join(game, "reframework", "autorun")
        shutil.copy2(os.path.join(REPO, "dev", "re9coop_devbridge.lua"), auto)
        shutil.copy2(os.path.join(REPO, "re9coop", "lua", "autorun", "re9coop_main.lua"), auto)
        plug = os.path.join(REPO, "re9coop", "plugin", "build", "re9coop_net.dll")
        if os.path.exists(plug):
            shutil.copy2(plug, os.path.join(game, "reframework", "plugins"))
    subprocess.run(["um", "win", "launch", "--steam", APPID], capture_output=True, shell=True)
    time.sleep(20)
    subprocess.Popen([os.path.join(STAND, "re9.exe")], cwd=STAND)
    print("launched both")
    return 0


def bridge(game, code, timeout=15):
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "bridge.py"), "-g", game, code, "-t", str(timeout)],
                       capture_output=True, text=True, timeout=timeout + 15)
    return (r.stdout + r.stderr).strip()


GUI_OP = """if not dev.gui_op then dev.gui_op = true
sdk.hook(sdk.find_type_definition('app.GuiAutoSaveFlowController'):get_method('update'), function()
local op = dev.op if op then dev.op = nil local ok, r = pcall(op) dev.op_result = { ok = ok, r = tostring(r) } end end, nil) end
return 'ok'"""
CONTINUE = """dev.op = function() local T = sdk.typeof('app.TitleFlowController')
local scene = sdk.call_native_func(sdk.get_native_singleton('via.SceneManager'), sdk.find_type_definition('via.SceneManager'), 'get_CurrentScene')
local all = scene:call('findComponents(System.Type)', T):get_elements()
if #all == 0 then return 'no title' end all[1]:call('onContinue') return 'continue' end return 1"""
IN_GAME = "return tostring(_G.re9coop.me.go ~= nil) .. ' ' .. tostring(_G.re9coop.me.chapter)"


def coop():
    """the host continues from the latest save and opens the lobby; the guest joins from its title screen"""
    for g in ("1", "2"):
        print(g, bridge(g, GUI_OP))
    # the title screen may not be there yet: again until it is
    for _ in range(30):
        bridge("1", CONTINUE)
        time.sleep(2)
        r = bridge("1", "return tostring(dev.op_result and dev.op_result.r)")
        if "continue" in r:
            break
        time.sleep(3)
    print("host:", r, flush=True)
    for _ in range(40):
        if '"true Chap' in bridge("1", IN_GAME):
            break
        time.sleep(4)
    print("host in game:", bridge("1", IN_GAME))
    time.sleep(5)
    print("host lobby:", bridge("1", "return tostring(re9coop_net.host(2, 1))"))
    time.sleep(3)
    print("guest joins:", bridge("2", "return tostring(re9coop_net.join('4242'))"))
    for _ in range(60):
        if '"true Chap' in bridge("2", IN_GAME):
            break
        time.sleep(4)
    print("guest in game:", bridge("2", IN_GAME))
    return 0


def stop():
    subprocess.run(["taskkill", "/IM", "re9.exe", "/F"], capture_output=True)
    time.sleep(6)
    if os.path.exists(USER_CONFIG):
        shutil.copy2(USER_CONFIG, os.path.join(GAME, "config.ini"))
        os.remove(USER_CONFIG)
        print("the player's graphics settings are back")
    if os.path.exists(USER_REF_CONFIG):
        shutil.copy2(USER_REF_CONFIG, os.path.join(GAME, "re2_fw_config.txt"))
        os.remove(USER_REF_CONFIG)
        print("the player's REFramework settings are back")
    for game in LAN:
        data = os.path.join(game, "reframework", "data", "re9coop_bridge")
        if os.path.isdir(data):
            shutil.rmtree(data)
        dev = os.path.join(game, "reframework", "autorun", "re9coop_devbridge.lua")
        if os.path.exists(dev):
            os.remove(dev)
    print("stopped; running now: %d" % running())
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "setup":
        setup()
    elif cmd == "start":
        sys.exit(start())
    elif cmd == "stop":
        sys.exit(stop())
    elif cmd == "coop":
        sys.exit(coop())
    else:
        print(__doc__)
