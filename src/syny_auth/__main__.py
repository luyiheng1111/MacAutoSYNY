"""命令行入口：python3 -m syny_auth [gui|daemon|test|status]"""

from __future__ import annotations

import sys

from . import core

USAGE = """SYNY 校园网自动认证

用法：
  python3 -m syny_auth gui      打开设置界面（默认，Tkinter 旧版）
  python3 -m syny_auth daemon   前台运行后台认证循环（调试用）
  python3 -m syny_auth test     立即执行一次「探测 + 认证」并输出结果
  python3 -m syny_auth status   查看当前配置与后台服务状态
  python3 -m syny_auth api      供原生前端调用的 JSON 桥接（stdin 进 / stdout 出）
"""


def _cmd_test() -> int:
    cfg = core.load_config()
    if not cfg.get("username"):
        print("尚未配置账号，请先运行 gui 子命令完成设置。")
        return 2
    ok, message = core.authenticate_once(cfg)
    print(("✅ " if ok else "❌ ") + message)
    return 0 if ok else 1


def _cmd_status() -> int:
    cfg = core.load_config()
    mode, running, pid = core.service_state()
    mode_label = {
        "launchd": "launchd 后台服务",
        "process": "独立进程",
    }.get(mode, "未启用")
    print("账号          : {}".format(cfg.get("username") or "(未配置)"))
    print("检测间隔      : {} 秒".format(cfg["check_interval"]))
    print("探测地址      : {}".format(cfg["captive_url"]))
    print("登录自启      : {}".format("是" if cfg["auto_start"] else "否"))
    print("记录日志      : {}".format("是" if cfg["logging"] else "否"))
    print("密码已存钥匙串: {}".format(
        "是" if core.keychain_get_password(cfg.get("username", "")) else "否"
    ))
    print("运行方式      : {}".format(mode_label))
    print("是否运行中    : {}".format("是" if running else "否"))
    if pid:
        print("进程 PID      : {}".format(pid))
    return 0


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    command = argv[0] if argv else "gui"

    if command == "daemon":
        from .daemon import Daemon

        return Daemon().run()
    if command == "api":
        from .api import run_api

        return run_api()
    if command == "test":
        return _cmd_test()
    if command == "status":
        return _cmd_status()
    if command in ("gui", "app"):
        from .gui import run_gui

        return run_gui()
    if command in ("-h", "--help", "help"):
        print(USAGE)
        return 0

    print("未知命令：{}\n\n{}".format(command, USAGE))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
