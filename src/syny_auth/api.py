"""JSON 桥接层：供原生前端（SwiftUI）以子进程方式调用后端能力。

前端每次操作启动一个进程，执行：

    python3 -m syny_auth api

从 stdin 读一行 JSON 请求，向 stdout 写一行 JSON 响应。请求形如：

    {"op": "status"}
    {"op": "save", "config": {...}, "password": "..."}
    {"op": "set_logging", "value": true}

响应统一为：

    {"ok": true|false, "message": "...", "data": {...}}

设计原则：本模块只做「参数校验 + 调用 core + 序列化结果」，所有网络 /
钥匙串 / launchd 逻辑都留在 core.py，避免与既有命令行行为产生分歧。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from . import core

# 可被前端修改的配置项（与 core.DEFAULT_CONFIG 对齐，enabled 由服务层维护）
_EDITABLE_KEYS = (
    "username", "check_interval", "captive_url", "portal_hint",
    "auto_start", "notify", "logging", "only_syny_wifi",
)


def _emit(payload: dict) -> None:
    """向标准输出写一行 JSON（前端按行解析）。"""
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _ok(data=None, message: str = "") -> dict:
    return {"ok": True, "message": message, "data": data if data is not None else {}}


def _err(message: str, data=None) -> dict:
    return {"ok": False, "message": message, "data": data if data is not None else {}}


def _public_config(cfg: dict) -> dict:
    return {
        "username": cfg.get("username", ""),
        "check_interval": cfg.get("check_interval", 30),
        "captive_url": cfg.get("captive_url", ""),
        "portal_hint": cfg.get("portal_hint", ""),
        "auto_start": bool(cfg.get("auto_start", True)),
        "notify": bool(cfg.get("notify", True)),
        "logging": bool(cfg.get("logging", False)),
        "only_syny_wifi": bool(cfg.get("only_syny_wifi", True)),
        "enabled": bool(cfg.get("enabled", False)),
    }


# --------------------------------------------------------------------------- #
# 各操作
# --------------------------------------------------------------------------- #
def _op_status(_req: dict) -> dict:
    cfg = core.load_config()
    mode, running, pid = core.service_state()
    username = cfg.get("username", "")
    ssid = core.current_wifi_ssid()
    return _ok({
        "config": _public_config(cfg),
        "has_password": bool(core.keychain_get_password(username)) if username else False,
        "service": {"mode": mode, "running": bool(running), "pid": pid},
        "wifi": {"ssid": ssid, "is_syny": bool(core.wifi_is_syny(cfg))},
        "log_tail": core.read_log_tail(200),
    })


def _op_get_password(req: dict) -> dict:
    username = (req.get("username") or "").strip() or core.load_config().get("username", "")
    if not username:
        return _ok({"password": ""})
    return _ok({"password": core.keychain_get_password(username)})


def _op_save(req: dict) -> dict:
    incoming = req.get("config") or {}
    password = req.get("password", "")
    username = str(incoming.get("username") or "").strip()
    if not username:
        return _err("请填写校园网账号。")

    try:
        interval = int(incoming.get("check_interval", 30))
    except (TypeError, ValueError):
        return _err("检测间隔必须是整数秒。")
    if interval < 5:
        return _err("检测间隔不能小于 5 秒。")

    captive = str(incoming.get("captive_url") or "").strip()
    if not captive.startswith("http"):
        return _err("探测地址需以 http:// 或 https:// 开头。")
    portal = str(incoming.get("portal_hint") or "").strip()
    if portal and not portal.startswith("http"):
        return _err("认证门户地址需以 http:// 或 https:// 开头。")

    # 密码只有非空时才写，避免把回填的掩码/空值覆盖掉钥匙串
    if password:
        if not core.keychain_set_password(username, password):
            return _err("密码写入系统钥匙串失败，请重试。")

    updates = {k: incoming[k] for k in _EDITABLE_KEYS if k in incoming}
    updates["username"] = username
    updates["check_interval"] = interval
    updates["captive_url"] = captive
    updates["portal_hint"] = portal
    core.save_config(updates)
    return _ok(_public_config(core.load_config()), "已保存。")


def _op_start(_req: dict) -> dict:
    ok, message = core.start_service()
    return (_ok(message=message) if ok else _err(message))


def _op_stop(_req: dict) -> dict:
    core.stop_service()
    return _ok(message="后台认证已停止。")


def _op_test(_req: dict) -> dict:
    cfg = core.load_config()
    if not cfg.get("username"):
        return _err("尚未配置账号。")
    learned = core.learn_portal_while_online(cfg)
    ok, message = core.authenticate_once(cfg)
    if learned and not ok:
        message += "（已预学习门户地址，下次断网可自动复用）"
    return (_ok(message=message) if ok else _err(message))


def _op_logout(_req: dict) -> dict:
    cfg = core.load_config()
    ok, message = core.logout(cfg)
    if ok and core.service_state()[1]:
        core.stop_service()
        message += "\n\n后台自动认证已暂停，恢复请点「保存并启用后台认证」。"
    return (_ok(message=message) if ok else _err(message))


def _op_set_logging(req: dict) -> dict:
    enabled = bool(req.get("value", False))
    cfg = core.load_config()
    before = bool(cfg.get("logging", False))
    cfg["logging"] = enabled
    core.save_config({"logging": enabled})
    # 日志开关影响守护进程输出目标，服务已注册时重写服务定义
    if enabled != before and core.agent_loaded():
        core.install_agent()
    core.log("日志记录已{}".format("开启" if enabled else "关闭"))
    return _ok({"logging": enabled},
               "日志记录已{}。".format("开启" if enabled else "关闭"))


def _op_log(_req: dict) -> dict:
    if core.logging_enabled():
        content = core.read_log_tail(200) or "(暂无日志内容)"
    else:
        content = ("日志记录未开启（默认关闭，不写入任何日志文件）。\n"
                   "如需排查认证问题，请打开「记录运行日志」。")
        if os.path.exists(core.LOG_PATH):
            content += ("\n\n—— 以下为关闭日志前记录的历史内容 ——\n"
                        + core.read_log_tail(60))
    return _ok({"logging": core.logging_enabled(), "content": content})


def _op_clear_log(_req: dict) -> dict:
    core.clear_log()
    return _ok(message="日志已清空。")


def _op_open_log(_req: dict) -> dict:
    if not os.path.exists(core.LOG_PATH):
        return _err("尚未记录任何日志。日志默认不记录，打开「记录运行日志」后才会生成日志文件。")
    subprocess.run(["open", "-R", core.LOG_PATH], capture_output=True)
    return _ok(message="已在访达中显示日志文件。")


def _op_ping(_req: dict) -> dict:
    return _ok({"version": __import__("syny_auth").__version__})


_HANDLERS = {
    "ping": _op_ping,
    "status": _op_status,
    "get_password": _op_get_password,
    "save": _op_save,
    "start": _op_start,
    "stop": _op_stop,
    "test": _op_test,
    "logout": _op_logout,
    "set_logging": _op_set_logging,
    "log": _op_log,
    "clear_log": _op_clear_log,
    "open_log": _op_open_log,
}


def run_api() -> int:
    raw = sys.stdin.read().strip()
    try:
        request = json.loads(raw) if raw else {}
    except ValueError:
        _emit(_err("请求不是合法 JSON"))
        return 2
    if not isinstance(request, dict):
        _emit(_err("请求必须是 JSON 对象"))
        return 2

    op = request.get("op", "status")
    handler = _HANDLERS.get(op)
    if handler is None:
        _emit(_err("未知操作：{}".format(op)))
        return 2

    try:
        _emit(handler(request))
        return 0
    except Exception as exc:  # noqa: BLE001 - 兜底：任何异常都以 JSON 形式回传
        _emit(_err("操作出错：{}: {}".format(type(exc).__name__, exc)))
        return 1
