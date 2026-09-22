"""图形界面：账号密码设置 + 后台服务开关 + 日志查看。

纯标准库 Tkinter（macOS 上由系统自带 Tk 渲染），跟随系统深色/浅色外观。
视觉语言对齐 macOS 系统设置：头部应用图标 + 状态胶囊、macOS 风格开关、
通栏「高级设置」按钮；首屏收敛为「账号信息」，其余功能收进高级设置。
所有网络与 launchctl 操作都放到工作线程，通过队列回传结果，避免界面卡死。
"""

from __future__ import annotations

import os
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox, ttk

from . import core

# Apple 调色板：浅色套用系统设置常用的 Parchment 底 + Action Blue 交互色；
# 深色用 macOS 窗口/卡片分层灰；开关绿色沿用系统绿 #34c759。
DARK = {
    "bg": "#1c1c1e", "card": "#2c2c2e", "fg": "#f5f5f7", "sub": "#98989d",
    "accent": "#2997ff", "accent_fg": "#ffffff", "ok": "#30d158",
    "warn": "#ff9f0a", "err": "#ff453a", "border": "#3a3a3c", "field": "#1c1c1e",
    "toggle_on": "#34c759", "toggle_off": "#39393d",
    "list_row": "#3a3d42", "list_row_hover": "#45474c",
}
LIGHT = {
    "bg": "#f5f5f7", "card": "#ffffff", "fg": "#1d1d1f", "sub": "#6e6e73",
    "accent": "#0066cc", "accent_fg": "#ffffff", "ok": "#34c759",
    "warn": "#b25000", "err": "#d70015", "border": "#d2d2d7", "field": "#ffffff",
    "toggle_on": "#34c759", "toggle_off": "#e9e9ea",
    "list_row": "#e8e8ed", "list_row_hover": "#dcdce1",
}


def system_is_dark() -> bool:
    try:
        proc = subprocess.run(
            ["defaults", "read", "-g", "AppleInterfaceStyle"],
            capture_output=True, text=True, timeout=3,
        )
        return proc.returncode == 0 and "Dark" in proc.stdout
    except Exception:  # noqa: BLE001
        return False


def pick_font() -> str:
    families = set(tkfont.families())
    for name in ("SF Pro Text", "Helvetica Neue", "PingFang SC", "Helvetica"):
        if name in families:
            return name
    return "TkDefaultFont"


class Toggle(tk.Canvas):
    """macOS 风格开关：绿色胶囊（开）/ 灰色胶囊（关）+ 白色滑块。"""

    def __init__(self, master, variable=None, command=None, palette=None,
                 bg=None, width=50, height=30, **kw):
        super().__init__(master, width=width, height=height, bd=0,
                         highlightthickness=0,
                         bg=(bg or (palette or LIGHT)["bg"]), **kw)
        self._var = variable or tk.BooleanVar(value=False)
        self._command = command
        self._p = palette or LIGHT
        self._width = width
        self._h = height
        self.bind("<Button-1>", self._on_click)
        self._draw()

    def _on_click(self, _event=None):
        self._var.set(not self._var.get())
        self._draw()
        if self._command:
            self._command()

    def _draw(self):
        p = self._p
        self.delete("all")
        on = bool(self._var.get())
        track = p["toggle_on"] if on else p["toggle_off"]
        h = self._h
        r = h / 2.0
        # 轨道：两段半圆 + 中间矩形拼成胶囊
        self.create_oval(0, 0, h, h, fill=track, outline="")
        self.create_oval(self._width - h, 0, self._width, h, fill=track, outline="")
        self.create_rectangle(r, 0, self._width - r, h, fill=track, outline="")
        # 滑块
        kw = h - 4
        kx = (self._width - r - kw / 2) if on else (r - kw / 2)
        ky = (h - kw) / 2
        self.create_oval(kx, ky, kx + kw, ky + kw, fill="#ffffff", outline="")


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.palette = DARK if system_is_dark() else LIGHT
        self.font_family = pick_font()
        self.busy = False
        self.results = queue.Queue()
        self.cfg = core.load_config()
        # 首屏收敛：默认只显示账号信息 + 主操作，高级设置收起
        self.advanced_open = False

        self._build_style()
        self._build_ui()
        self._apply_advanced()
        self._load_into_form()
        self._refresh_status()
        self._poll_results()
        self._schedule_autorefresh()
        self._maybe_autostart()

    # ================================================================== #
    # 样式
    # ================================================================== #
    def _build_style(self) -> None:
        p, f = self.palette, self.font_family
        self.root.configure(bg=p["bg"])
        style = ttk.Style(self.root)
        style.theme_use("clam")

        style.configure(".", background=p["bg"], foreground=p["fg"],
                        font=(f, 13), borderwidth=0, focuscolor=p["accent"])
        style.configure("TFrame", background=p["bg"])
        style.configure("Card.TFrame", background=p["card"], relief="solid",
                        borderwidth=1, bordercolor=p["border"])
        style.configure("TLabel", background=p["bg"], foreground=p["fg"])
        style.configure("Card.TLabel", background=p["card"], foreground=p["fg"])
        style.configure("Title.TLabel", background=p["card"], foreground=p["fg"],
                        font=(f, 17, "bold"))
        style.configure("Sub.TLabel", background=p["card"], foreground=p["sub"],
                        font=(f, 11))
        style.configure("Hint.TLabel", background=p["bg"], foreground=p["sub"],
                        font=(f, 11))
        style.configure("Section.TLabel", background=p["card"], foreground=p["sub"],
                        font=(f, 11, "bold"))

        for name, bg, fg in (
            ("TButton", p["card"], p["fg"]),
            ("Accent.TButton", p["accent"], p["accent_fg"]),
            ("Ghost.TButton", p["bg"], p["sub"]),
        ):
            style.configure(name, background=bg, foreground=fg, padding=(14, 7),
                            relief="flat", borderwidth=0, font=(f, 12))
            style.map(name,
                      background=[("pressed", p["border"]), ("active", p["border"]),
                                  ("disabled", bg)],
                      foreground=[("disabled", p["sub"])])
        style.configure("Accent.TButton", background=p["accent"],
                        foreground=p["accent_fg"])
        style.map("Accent.TButton",
                  background=[("pressed", p["accent"]), ("active", p["accent"]),
                              ("disabled", p["border"])],
                  foreground=[("disabled", p["sub"])])

        style.configure("TEntry", fieldbackground=p["field"], foreground=p["fg"],
                        insertcolor=p["fg"], bordercolor=p["border"],
                        lightcolor=p["border"], darkcolor=p["border"], padding=7)
        # 注意：只用 Tk 8.5 就支持的控件/样式。系统 /usr/bin/python3 是 Tk 8.5，
        # 没有 ttk.Spinbox / TSpinbox（8.6+ 才有），因此检测间隔用原生 tk.Spinbox。
        style.configure("TSeparator", background=p["border"])
        style.configure("Vertical.TScrollbar", background=p["card"],
                        troughcolor=p["bg"], bordercolor=p["bg"],
                        arrowcolor=p["sub"], relief="flat")

    # ================================================================== #
    # 通用构件
    # ================================================================== #
    def _card(self, parent, **pack):
        frame = ttk.Frame(parent, style="Card.TFrame", padding=(18, 14))
        frame.pack(fill="x", **pack)
        return frame

    def _round_rect(self, canvas, x0, y0, x1, y1, r, fill):
        canvas.create_oval(x0, y0, x0 + 2 * r, y0 + 2 * r, fill=fill, outline="")
        canvas.create_oval(x1 - 2 * r, y0, x1, y0 + 2 * r, fill=fill, outline="")
        canvas.create_oval(x0, y1 - 2 * r, x0 + 2 * r, y1, fill=fill, outline="")
        canvas.create_oval(x1 - 2 * r, y1 - 2 * r, x1, y1, fill=fill, outline="")
        canvas.create_rectangle(x0 + r, y0, x1 - r, y1, fill=fill, outline="")
        canvas.create_rectangle(x0, y0 + r, x1, y1 - r, fill=fill, outline="")

    def _make_app_icon(self, parent, size=56):
        p = self.palette
        canvas = tk.Canvas(parent, width=size, height=size, bd=0,
                           highlightthickness=0, bg=p["bg"])
        self._round_rect(canvas, 0, 0, size, size, size * 0.23, fill=p["accent"])
        cx = size / 2.0
        doty = size * 0.72
        canvas.create_oval(cx - 2.5, doty - 2.5, cx + 2.5, doty + 2.5,
                           fill="white", outline="")
        for rad in (size * 0.22, size * 0.34):
            canvas.create_arc(cx - rad, doty - rad, cx + rad, doty + rad,
                              start=205, extent=130, style="arc",
                              outline="white", width=3)
        return canvas

    def _row_button(self, parent, text, command):
        """通栏列表式按钮（如「高级设置」）：左侧标题 + 右侧 chevron。"""
        p = self.palette
        f = tk.Frame(parent, bg=p["list_row"], cursor="hand2", height=42)
        f.pack_propagate(False)
        lab = tk.Label(f, text=text, bg=p["list_row"], fg=p["fg"],
                       font=(self.font_family, 14, "bold"))
        lab.pack(side="left", padx=16)
        ch = tk.Label(f, text="›", bg=p["list_row"], fg=p["sub"],
                      font=(self.font_family, 22))
        ch.pack(side="right", padx=14)
        pieces = [f, lab, ch]

        def enter(_e):
            for w in pieces:
                w.configure(bg=p["list_row_hover"])

        def leave(_e):
            for w in pieces:
                w.configure(bg=p["list_row"])

        f.bind("<Enter>", enter)
        f.bind("<Leave>", leave)
        f.bind("<Button-1>", lambda _e: command())
        lab.bind("<Button-1>", lambda _e: command())
        ch.bind("<Button-1>", lambda _e: command())
        return f, lab, ch

    def _toggle_row(self, parent, text, variable, command=None):
        row = ttk.Frame(parent, style="Card.TFrame")
        ttk.Label(row, text=text, style="Card.TLabel").pack(side="left")
        Toggle(row, variable=variable, command=command, palette=self.palette,
               bg=self.palette["card"]).pack(side="right")
        # 父容器若已用 grid 布局（如「后台服务」卡片），同行内子控件也须用 grid；
        # 否则用 pack。同一父容器不能混用两种几何管理器。
        if parent.grid_slaves():
            nrows = parent.grid_size()[1]
            row.grid(row=nrows, column=0, columnspan=4, sticky="ew",
                     pady=(10, 0))
        else:
            row.pack(fill="x", pady=(10, 0))
        return row

    # ================================================================== #
    # 界面
    # ================================================================== #
    def _build_ui(self) -> None:
        self.root.title(core.APP_TITLE)
        self.root.minsize(680, 300)
        # 工具栏留白由系统标题栏承担（红黄绿按钮为原生），内容区直接放头部

        outer = ttk.Frame(self.root, padding=(20, 18, 20, 14))
        outer.pack(fill="both", expand=True)

        # ---------- 头部：应用图标 + 标题 + 状态胶囊 ----------
        header = ttk.Frame(outer)
        header.pack(fill="x", pady=(0, 14))

        icon = self._make_app_icon(header, size=56)
        icon.pack(side="left")

        titles = ttk.Frame(header)
        titles.pack(side="left", padx=(14, 0))
        ttk.Label(titles, text="校园网自动认证",
                  font=(self.font_family, 20, "bold")).pack(anchor="w")
        ttk.Label(titles, text="断网自动登录 · 后台常驻 · 密码存入系统钥匙串",
                  style="Hint.TLabel").pack(anchor="w", pady=(3, 0))

        self.status_pill = tk.Label(
            header, text="  ●  正在检测  ", bg=self.palette["card"],
            fg=self.palette["sub"], font=(self.font_family, 12, "bold"),
            padx=12, pady=6, bd=1, relief="solid",
        )
        self.status_pill.pack(side="right", ipady=2)

        # ---------- 账号卡片 ----------
        account = self._card(outer, pady=(0, 12))
        ttk.Label(account, text="账号信息", style="Section.TLabel").grid(
            row=0, column=0, columnspan=3, sticky="w", pady=(0, 10))

        ttk.Label(account, text="校园网账号", style="Card.TLabel").grid(
            row=1, column=0, sticky="w", pady=6)
        self.entry_user = ttk.Entry(account, width=26, font=(self.font_family, 13))
        self.entry_user.grid(row=1, column=1, sticky="ew", padx=(12, 0), pady=6)

        ttk.Label(account, text="密码", style="Card.TLabel").grid(
            row=2, column=0, sticky="w", pady=6)
        self.entry_pass = ttk.Entry(account, width=26, show="•",
                                    font=(self.font_family, 13))
        self.entry_pass.grid(row=2, column=1, sticky="ew", padx=(12, 0), pady=6)
        self.btn_eye = ttk.Button(account, text="显示", width=6,
                                  command=self._toggle_password)
        self.btn_eye.grid(row=2, column=2, sticky="e", padx=(8, 0), pady=6)

        account.columnconfigure(1, weight=1)
        ttk.Label(account,
                  text="密码仅保存在本机「钥匙串」中，不会写入配置文件或上传。",
                  style="Sub.TLabel").grid(row=3, column=0, columnspan=3,
                                           sticky="w", pady=(8, 0))

        # ---------- 主操作 ----------
        self.btn_primary = ttk.Button(outer, text="保存并启用后台认证",
                                      style="Accent.TButton",
                                      command=self._on_save_enable)
        self.btn_primary.pack(fill="x", pady=(0, 10), ipady=4)

        # ---------- 高级设置（通栏按钮，默认收起下方） ----------
        self.adv_frame, self.adv_lab, self.adv_ch = self._row_button(
            outer, "高级设置", self._toggle_advanced)
        self.adv_frame.pack(fill="x", pady=(0, 12))

        # 高级设置区：默认收起
        self.advanced = ttk.Frame(outer)

        # ---------- 后台服务卡片 ----------
        service = self._card(self.advanced, pady=(0, 12))
        ttk.Label(service, text="后台服务", style="Section.TLabel").grid(
            row=0, column=0, columnspan=4, sticky="w", pady=(0, 10))

        ttk.Label(service, text="检测间隔", style="Card.TLabel").grid(
            row=1, column=0, sticky="w", pady=6)
        interval_box = ttk.Frame(service, style="Card.TFrame")
        interval_box.grid(row=1, column=1, sticky="w", padx=(12, 0), pady=6)
        self.var_interval = tk.StringVar(value="30")
        tk.Spinbox(interval_box, from_=5, to=3600, increment=5, width=7,
                   textvariable=self.var_interval,
                   font=(self.font_family, 13),
                   bg=self.palette["field"], fg=self.palette["fg"]).pack(side="left")
        ttk.Label(interval_box, text="秒检测一次", style="Card.TLabel").pack(
            side="left", padx=(8, 0))

        ttk.Label(service, text="探测地址", style="Card.TLabel").grid(
            row=2, column=0, sticky="w", pady=6)
        self.entry_probe = ttk.Entry(service, font=(self.font_family, 12))
        self.entry_probe.grid(row=2, column=1, columnspan=2, sticky="ew",
                              padx=(12, 0), pady=6)

        ttk.Label(service, text="认证门户", style="Card.TLabel").grid(
            row=3, column=0, sticky="w", pady=6)
        self.entry_portal = ttk.Entry(service, font=(self.font_family, 12))
        self.entry_portal.grid(row=3, column=1, columnspan=2, sticky="ew",
                               padx=(12, 0), pady=6)
        ttk.Label(service,
                  text="校园网认证门户地址。正常情况会自动识别，识别不到时才需要手工填写。",
                  style="Sub.TLabel").grid(row=4, column=1, columnspan=3,
                                           sticky="w", padx=(12, 0))

        self.var_autostart = tk.BooleanVar(value=True)
        self.var_notify = tk.BooleanVar(value=True)
        self.var_only_syny = tk.BooleanVar(value=True)
        self._toggle_row(service, "登录后自动启动后台服务", self.var_autostart)
        self._toggle_row(service, "认证结果发送系统通知", self.var_notify)
        self._toggle_row(service, "仅 syny WiFi 下认证", self.var_only_syny)

        service.columnconfigure(1, weight=1)
        service.columnconfigure(2, weight=1)

        # ---------- 操作按钮（高级设置区） ----------
        actions = ttk.Frame(self.advanced)
        actions.pack(fill="x", pady=(0, 12))
        self.btn_save_only = ttk.Button(actions, text="仅保存",
                                        command=self._on_save_only)
        self.btn_save_only.pack(side="left")
        self.btn_test = ttk.Button(actions, text="立即测试认证",
                                   command=self._on_test)
        self.btn_test.pack(side="left", padx=(8, 0))

        tools = ttk.Frame(self.advanced)
        tools.pack(fill="x", pady=(0, 12))
        self.btn_logout = ttk.Button(tools, text="手动下线",
                                     command=self._on_logout)
        self.btn_logout.pack(side="left")
        self.btn_stop = ttk.Button(tools, text="停止后台服务",
                                   command=self._on_stop)
        self.btn_stop.pack(side="left", padx=(8, 0))
        self.btn_repair = ttk.Button(tools, text="重装/修复服务",
                                     command=self._on_repair)
        self.btn_repair.pack(side="left", padx=(8, 0))
        ttk.Button(tools, text="打开日志文件", command=self._open_log).pack(
            side="left", padx=(8, 0))

        # ---------- 日志 ----------
        log_card = self._card(self.advanced)
        log_head = ttk.Frame(log_card, style="Card.TFrame")
        log_head.pack(fill="x", pady=(0, 8))
        ttk.Label(log_head, text="运行日志", style="Section.TLabel").pack(side="left")
        ttk.Button(log_head, text="清空", width=6, command=self._on_clear_log).pack(
            side="right")
        ttk.Button(log_head, text="刷新", width=6, command=self._refresh_log).pack(
            side="right", padx=(0, 6))
        self.var_logging = tk.BooleanVar(value=False)
        self._toggle_row(log_head, "记录运行日志", self.var_logging,
                         command=self._on_toggle_logging)

        self.log_text = tk.Text(
            log_card, height=6, width=1, wrap="none", bd=0, highlightthickness=0,
            bg=self.palette["field"], fg=self.palette["sub"],
            insertbackground=self.palette["fg"],
            font=("Menlo", 11), padx=10, pady=8,
        )
        self.log_text.pack(fill="both", expand=True)
        self.log_text.configure(state="disabled")

        ttk.Label(self.advanced,
                  text="关闭窗口不会中断后台认证；如需彻底停止，请点「停止后台服务」。"
                       "日志默认不记录，需要排查问题时再打开「记录运行日志」。",
                  style="Hint.TLabel").pack(anchor="w", pady=(10, 0))

    # ================================================================== #
    # 首屏收敛：高级设置展开 / 收起
    # ================================================================== #
    def _toggle_advanced(self) -> None:
        self.advanced_open = not self.advanced_open
        self._apply_advanced()

    def _apply_advanced(self) -> None:
        if self.advanced_open:
            self.advanced.pack(fill="x")
            self.adv_lab.configure(text="收起高级设置")
            self.adv_ch.configure(text="⌃")
        else:
            self.advanced.pack_forget()
            self.adv_lab.configure(text="高级设置")
            self.adv_ch.configure(text="›")
        self.root.update_idletasks()
        width = min(max(720, self.root.winfo_reqwidth()), 820)
        height = self.root.winfo_reqheight()
        self.root.geometry("{}x{}".format(width, height))

    # ================================================================== #
    # 表单 <-> 配置
    # ================================================================== #
    def _load_into_form(self) -> None:
        self.entry_user.delete(0, "end")
        self.entry_user.insert(0, self.cfg.get("username", ""))
        self.entry_pass.delete(0, "end")
        stored = core.keychain_get_password(self.cfg.get("username", ""))
        if stored:
            self.entry_pass.insert(0, stored)
        self.var_interval.set(str(self.cfg.get("check_interval", 30)))
        self.entry_probe.delete(0, "end")
        self.entry_probe.insert(0, self.cfg.get("captive_url", ""))
        self.entry_portal.delete(0, "end")
        self.entry_portal.insert(0, self.cfg.get("portal_hint", ""))
        self.var_autostart.set(bool(self.cfg.get("auto_start", True)))
        self.var_notify.set(bool(self.cfg.get("notify", True)))
        self.var_only_syny.set(bool(self.cfg.get("only_syny_wifi", True)))
        self.var_logging.set(bool(self.cfg.get("logging", False)))

    def _collect_form(self):
        username = self.entry_user.get().strip()
        password = self.entry_pass.get()
        probe = self.entry_probe.get().strip() or core.DEFAULT_CONFIG["captive_url"]
        try:
            interval = int(self.var_interval.get())
        except ValueError:
            return None, "检测间隔必须是整数秒。"
        if interval < 5:
            return None, "检测间隔不能小于 5 秒。"
        if not username:
            return None, "请填写校园网账号。"
        if not password:
            return None, "请填写密码。"
        if not probe.startswith("http"):
            return None, "探测地址需以 http:// 或 https:// 开头。"
        portal = self.entry_portal.get().strip()
        if portal and not portal.startswith("http"):
            return None, "认证门户地址需以 http:// 或 https:// 开头。"
        return {
            "username": username,
            "password": password,
            "check_interval": interval,
            "captive_url": probe,
            "portal_hint": portal,
            "auto_start": bool(self.var_autostart.get()),
            "notify": bool(self.var_notify.get()),
            "only_syny_wifi": bool(self.var_only_syny.get()),
            "logging": bool(self.var_logging.get()),
        }, None

    def _persist(self, data) -> bool:
        before_logging = bool(core.load_config().get("logging", False))
        ok_pw = core.keychain_set_password(data["username"], data["password"])
        if not ok_pw:
            messagebox.showerror("保存失败", "密码写入系统钥匙串失败，请重试。")
            return False
        core.save_config({k: v for k, v in data.items() if k != "password"})
        self.cfg = core.load_config()
        # 日志开关变化会影响 launchd 的输出目标，需要重写服务定义
        if bool(data.get("logging", False)) != before_logging and core.agent_loaded():
            core.install_agent()
        core.log("配置已保存（账号={}，间隔={}s）".format(
            data["username"], data["check_interval"]))
        return True

    def _toggle_password(self) -> None:
        if self.entry_pass.cget("show"):
            self.entry_pass.configure(show="")
            self.btn_eye.configure(text="隐藏")
        else:
            self.entry_pass.configure(show="•")
            self.btn_eye.configure(text="显示")

    # ================================================================== #
    # 事件
    # ================================================================== #
    def _on_save_enable(self) -> None:
        data, err = self._collect_form()
        if err:
            messagebox.showwarning("请检查填写内容", err)
            return
        if not self._persist(data):
            return
        self._run_async("正在保存并启用后台认证", core.start_service)

    def _on_save_only(self) -> None:
        data, err = self._collect_form()
        if err:
            messagebox.showwarning("请检查填写内容", err)
            return
        if not self._persist(data):
            return
        if core.service_state()[1]:
            self._run_async("正在应用新配置", self._restart_service)
        else:
            self._set_message("已保存。点击「保存并启用后台认证」可开启后台认证。")

    def _restart_service(self):
        core.stop_service()
        ok, message = core.start_service()
        return ok, ("已保存。" + message) if ok else message

    def _on_test(self) -> None:
        data, err = self._collect_form()
        if err:
            messagebox.showwarning("请检查填写内容", err)
            return
        # 先把当前输入落盘，保证测试用的是界面上的账号密码
        if not self._persist(data):
            return

        def job():
            # 在线时也趁门户服务器可达，先把门户参数预学习进缓存，
            # 这样下次断网（哪怕 DNS 失效）也能直接复用、无需再看到 captive 页面。
            learned = core.learn_portal_while_online(core.load_config())
            ok, message = core.authenticate_once(core.load_config())
            if learned and not ok:
                message += "（已预学习门户地址，下次断网可自动复用）"
            return ok, ("认证成功：" if ok else "认证失败：") + message

        self._run_async("正在测试认证，请稍候", job, show_dialog=True)

    def _on_logout(self) -> None:
        if not messagebox.askyesno(
            "手动下线",
            "确定要断开当前校园网认证吗？\n\n"
            "断开后会一并暂停后台自动认证，避免立刻被自动重新登录。\n"
            "需要恢复时请点「保存并启用后台认证」。",
        ):
            return

        def job():
            ok, message = core.logout(core.load_config())
            if ok and core.service_state()[1]:
                core.stop_service()
                message += "\n\n后台自动认证已暂停，恢复请点「保存并启用后台认证」。"
            return ok, message

        self._run_async("正在下线", job, show_dialog=True)

    def _on_stop(self) -> None:
        _, running, _ = core.service_state()
        if not running and not core.agent_installed():
            self._set_message("后台认证当前未运行。")
            return
        if not messagebox.askyesno(
            "停止后台认证",
            "将停止后台自动认证服务。\n账号密码会保留，之后可随时重新启用。",
        ):
            return
        self._run_async("正在停止后台认证",
                        lambda: (core.stop_service() or True, "后台认证已停止"))

    def _on_repair(self) -> None:
        self._run_async("正在重新注册后台服务", core.start_service)

    def _open_log(self) -> None:
        if not os.path.exists(core.LOG_PATH):
            messagebox.showinfo(
                "暂无日志文件",
                "尚未记录任何日志。\n\n日志默认不记录，打开「记录运行日志」后才会生成日志文件。",
            )
            return
        subprocess.run(["open", "-R", core.LOG_PATH], capture_output=True)

    def _on_toggle_logging(self) -> None:
        """日志开关立即生效，无需点保存。"""
        enabled = bool(self.var_logging.get())
        cfg = core.load_config()
        cfg["logging"] = enabled
        core.save_config(cfg)
        self.cfg = cfg
        if core.agent_loaded():
            # 重写服务定义，让守护进程的输出目标随之切换
            core.install_agent()
        core.log("日志记录已{}".format("开启" if enabled else "关闭"))
        self._refresh_log()
        self._set_message("日志记录已{}".format("开启" if enabled else "关闭"))

    def _on_clear_log(self) -> None:
        if not os.path.exists(core.LOG_PATH):
            self._set_message("当前没有日志内容。")
            return
        if not messagebox.askyesno("清空日志", "确定删除已记录的日志内容吗？"):
            return
        core.clear_log()
        self._refresh_log()
        self._set_message("日志已清空")

    # ================================================================== #
    # 异步任务与状态刷新
    # ================================================================== #
    def _run_async(self, busy_text: str, job, show_dialog: bool = False) -> None:
        if self.busy:
            return
        self.busy = True
        self._set_message(busy_text + "…")

        def worker():
            try:
                result = job()
            except Exception as exc:  # noqa: BLE001
                result = (False, "操作出错：{}: {}".format(type(exc).__name__, exc))
            self.results.put((result, show_dialog))

        threading.Thread(target=worker, daemon=True).start()

    def _poll_results(self) -> None:
        try:
            while True:
                (result, show_dialog) = self.results.get_nowait()
                self.busy = False
                ok, message = result
                self._set_message(message, ok)
                if show_dialog:
                    (messagebox.showinfo if ok else messagebox.showerror)(
                        "测试结果", message)
                self._refresh_status()
                self._refresh_log()
        except queue.Empty:
            pass
        self.root.after(120, self._poll_results)

    def _set_message(self, message: str, ok=None) -> None:
        color = self.palette["sub"]
        if ok is True:
            color = self.palette["ok"]
        elif ok is False:
            color = self.palette["err"]
        self.status_pill.configure(text="  {}  ".format(message), fg=color)

    def _refresh_status(self) -> None:
        mode, running, _pid = core.service_state()
        p = self.palette
        if mode == "launchd":
            if running:
                text, color = "  ●  后台认证运行中（后台服务）  ", p["ok"]
            else:
                text, color = "  ●  服务已注册未运行  ", p["warn"]
        elif mode == "process":
            text, color = "  ●  后台认证运行中（独立进程）  ", p["ok"]
        else:
            text, color = "  ●  后台认证未启用  ", p["sub"]
        self.status_pill.configure(text=text, fg=color)
        self.btn_stop.configure(
            state="normal" if (running or core.agent_installed()) else "disabled")
        self._refresh_log()

    def _maybe_autostart(self) -> None:
        """应用启动时，若用户此前已启用后台认证但服务没在跑，自动恢复。"""
        cfg = core.load_config()
        if not cfg.get("enabled") or not cfg.get("username"):
            return
        if core.service_state()[1]:
            return
        self._run_async("正在恢复后台认证", core.start_service)

    def _refresh_log(self) -> None:
        if core.logging_enabled():
            content = core.read_log_tail(200) or "(暂无日志内容)"
        else:
            content = ("日志记录未开启（默认关闭，不写入任何日志文件）。\n"
                       "如需排查认证问题，请打开右上角「记录运行日志」。\n")
            if os.path.exists(core.LOG_PATH):
                content += "\n—— 以下为关闭日志前记录的历史内容 ——\n"
                content += core.read_log_tail(60)
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.insert("1.0", content)
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _schedule_autorefresh(self) -> None:
        def tick():
            if not self.busy:
                self._refresh_status()
            self.root.after(8000, tick)

        self.root.after(8000, tick)


def run_gui() -> int:
    root = tk.Tk()
    if not core.load_config().get("username"):
        core.log("首次启动：等待用户配置校园网账号")
    app = App(root)  # noqa: F841 - 显式持有引用，避免实例被回收
    try:
        # macOS 上 Tk（尤其系统自带的 8.5）从 .app 启动时常「窗口已建出但首帧未绘制」，
        # 表现为打开后一片空白、需缩放/点击才显示。强制 deiconify + 完整 update()
        # 触发首帧绘制，并再延迟补刷两次，确保内容稳定显示。
        root.deiconify()
        root.lift()
        root.attributes("-topmost", True)
        root.update_idletasks()
        root.update()
        root.after(60, root.update)
        root.after(300, lambda: (root.attributes("-topmost", False), root.update()))

        # 几何抖动：先 +1px 再还原，强制 macOS 窗口服务器重算并刷新整窗缓冲，
        # 兜底应对「首帧不重绘」类问题（缩放窗口即可显示，说明是重绘没被触发）。
        def _jitter():
            try:
                w, h = root.winfo_width(), root.winfo_height()
                root.geometry("{}x{}".format(w + 1, h))
                root.geometry("{}x{}".format(w, h))
            except tk.TclError:
                pass
        root.after(400, _jitter)
    except tk.TclError:
        pass
    root.mainloop()
    return 0
