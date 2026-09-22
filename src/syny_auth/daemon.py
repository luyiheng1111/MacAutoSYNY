"""后台守护进程：周期探测网络，断线时自动认证。

由 launchd 托管（KeepAlive=true），登录后常驻运行、异常退出会被自动拉起。
本地手动调试时可直接运行：python3 -m syny_auth daemon
"""

from __future__ import annotations

import os
import signal
import time

from . import core


class Daemon:
    def __init__(self):
        self._stopping = False
        self._last_state = None          # online / offline
        self._wifi_guard = None          # "syny" / "skip"
        self._beats = 0
        self._last_fail_notify = 0.0
        self._last_fail_message = ""

    # ------------------------------------------------------------------ #
    def _handle_signal(self, *_args):
        self._stopping = True

    def _sleep(self, seconds: int) -> None:
        """分片睡眠，便于及时响应终止信号。"""
        for _ in range(int(max(1, seconds))):
            if self._stopping:
                return
            time.sleep(1)

    def _notify_fail(self, message: str) -> None:
        """失败通知限频：10 分钟内最多一次，避免刷屏。"""
        now = time.time()
        if now - self._last_fail_notify < 600:
            return
        self._last_fail_notify = now
        core.notify(core.APP_TITLE, message, subtitle="认证失败")

    # ------------------------------------------------------------------ #
    def run(self) -> int:
        core.ensure_support_dir()
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

        cfg = core.load_config()
        username = cfg.get("username", "")
        if not username:
            core.log("未配置校园网账号，后台服务退出（配置账号后会自动重新启用）", "ERROR")
            return 0

        with open(core.PID_PATH, "w", encoding="utf-8") as fh:
            fh.write(str(os.getpid()))

        core.log(
            "后台服务启动 pid={} 账号={} 间隔={}s".format(
                os.getpid(), username, cfg["check_interval"]
            )
        )

        try:
            while not self._stopping:
                # 每轮热加载配置，界面上改完立即生效
                cfg = core.load_config()
                try:
                    self._tick(cfg)
                except Exception as exc:  # noqa: BLE001 - 单轮异常不应终止守护进程
                    core.log("循环异常：{}: {}".format(type(exc).__name__, exc), "ERROR")
                self._sleep(int(cfg.get("check_interval", 30)))
        finally:
            try:
                os.remove(core.PID_PATH)
            except OSError:
                pass
            core.log("后台服务已退出")
        return 0

    # ------------------------------------------------------------------ #
    def _tick(self, cfg: dict) -> None:
        # WiFi 守卫：未连接 syny WiFi 时完全不探测、不认证，避免在非校园网
        # （家庭 / 其他 WiFi）环境下后台反复测试连接、触发 captive 弹窗
        if cfg.get("only_syny_wifi", True) and not core.wifi_is_syny(cfg):
            ssid = core.current_wifi_ssid()
            if self._wifi_guard != "skip":
                core.log("当前 WiFi「{}」不是 syny，后台认证已暂停".format(
                    ssid or "(无 WiFi 连接)"))
                self._wifi_guard = "skip"
            self._last_state = None
            return
        if self._wifi_guard == "skip":
            core.log("已连接到 syny WiFi，恢复后台认证")
            self._wifi_guard = "syny"

        online, portal, detail = core.probe(cfg)

        if online:
            self._beats += 1
            self._last_fail_message = ""
            # 趁门户服务器可达，顺手刷新缓存的门户参数（wlanuserip 可能已变），
            # 这样下次断网时即便 DNS 失效也能直接复用，无需再看到 captive 页面。
            if self._beats % 4 == 1:
                learned = core.learn_portal_while_online(cfg)
                if learned and self._last_state != "online":
                    core.log("已预学习门户地址：{}".format(learned))
                # 同时抓取 userIndex（已在线时门户会 302 到 success.jsp?userIndex=...），
                # 这样即便本次登录不是由本软件发起，手动下线也能用
                core.capture_userindex_if_online(cfg)
            # 交叉校验：探测域名可能被放行（返回 204）但实则仍在 captive，
            # 此时直接问门户是否还需登录，避免误判在线而放任认证页弹出。
            if self._beats % 4 == 1 and core.portal_needs_login(cfg):
                core.log("门户仍要求登录（探测域名被放行），判定为离线并尝试认证")
                online = False
            if online:
                if self._last_state != "online":
                    core.log("网络正常：{}".format(detail))
                elif self._beats % 20 == 0:
                    core.log("心跳：网络正常（已连续 {} 次）".format(self._beats))
                self._last_state = "online"
                return

        # 未联网时一律继续尝试认证：无论是识别到认证页，还是探测本身失败
        # （DNS 解析不了、连接超时）。旧版在探测失败时直接放弃，导致断网后
        # 浏览器弹出认证页而自动认证毫无反应。
        core.log("未联网（{}），尝试自动认证...".format(detail or portal or "原因未知"))
        ok, message, attempted = core.authenticate(cfg)

        if ok:
            if attempted:
                core.log("认证成功：{}".format(message))
                if self._last_state != "online" and cfg.get("notify", True):
                    core.notify(core.APP_TITLE, "校园网认证成功", subtitle=message)
            else:
                core.log("网络已恢复：{}".format(message))
            self._last_fail_message = ""
            self._last_state = "online"
            return

        # 失败后快速重试两次：刚断线时门户可能尚未就绪，
        # 立刻放弃会白等一个完整检测周期。
        for _ in range(2):
            if self._stopping or not attempted:
                break
            self._sleep(3)
            if self._stopping:
                return
            ok, message, attempted = core.authenticate(cfg)
            if ok:
                core.log("认证成功（重试）：{}".format(message))
                if cfg.get("notify", True):
                    core.notify(core.APP_TITLE, "校园网认证成功", subtitle=message)
                self._last_fail_message = ""
                self._last_state = "online"
                return

        # 失败日志按内容去重，避免每轮刷同一条
        if message != self._last_fail_message:
            core.log("认证未通过：{}".format(message), "WARN")
            self._last_fail_message = message
        if cfg.get("notify", True):
            self._notify_fail(message)
        self._last_state = "offline"
