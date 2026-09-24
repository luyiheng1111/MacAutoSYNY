"""核心模块：配置读写、钥匙串、网络探测、锐捷 eportal 认证、launchd 服务管理。

认证流程完全沿用原 ruijie_auto.sh 的可正常使用逻辑：
  1. 访问连通性探测地址，若返回 204 说明已在线；
  2. 否则从响应正文 / Location 中取出认证页 URL（.../index.jsp?...）；
  3. 把 index.jsp 换成 InterFace.do?method=login，作为登录接口；
  4. 把认证页的 query 做「二次 URL 编码」后作为 queryString 放进 POST 表单；
  5. 解析返回的 JSON，result == success 即认证成功。
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

APP_TITLE = "SYNY 校园网自动认证"
LABEL = "com.syny.auth"
KEYCHAIN_SERVICE = "SYNYAuth"

SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/SYNYAuth")
CONFIG_PATH = os.path.join(SUPPORT_DIR, "config.json")
LOG_PATH = os.path.join(SUPPORT_DIR, "auth.log")
PID_PATH = os.path.join(SUPPORT_DIR, "daemon.pid")
PLIST_PATH = os.path.expanduser("~/Library/LaunchAgents/{}.plist".format(LABEL))
# 最近一次成功认证所用的门户主机与参数，供网络异常时重建认证地址
PORTAL_CACHE_PATH = os.path.join(SUPPORT_DIR, "portal_cache.json")
# 最近一次登录得到的会话标识 userIndex（手动下线需要），与会话同生命周期
SESSION_PATH = os.path.join(SUPPORT_DIR, "session.json")

# 默认连通性探测地址：大陆节点（小米 ROM 的 204 探针），
# 校园网内解析与回包都明显快于 google.cn，且不依赖境外线路。
DEFAULT_CAPTIVE_URL = "http://connect.rom.miui.com/generate_204"

# 历史版本的默认探测地址；加载旧配置时自动迁移到新默认值，
# 否则改默认值对老用户不生效（配置里存的仍是旧地址）。
LEGACY_CAPTIVE_URLS = frozenset({"http://www.google.cn/generate_204"})

# 备用探针：主探针不可用时依次尝试。
# 全部选大陆节点（小米 / vivo / 华为），校园网内一般都有 CDN 就近节点；
# 最后保留一个微软 connecttest（200 + 正文）作为兜底。
FALLBACK_PROBES = (
    "http://connect.rom.miui.com/generate_204",
    "http://wifi.vivo.com.cn/generate_204",
    "http://connectivitycheck.platform.hicloud.com/generate_204",
    "http://www.msftconnecttest.com/connecttest.txt",
)

# 触发式地址：用 IP 直连、不依赖 DNS。未认证时同样会被门户劫持，
# 从而在「DNS 不可用」的情况下依然能拿到带参数的认证页地址。
IP_TRIGGERS = (
    "http://110.242.68.66/",
    "http://180.101.50.242/",
    "http://1.1.1.1/",
)

DEFAULT_CONFIG = {
    # 校园网账号
    "username": "",
    # 检测间隔（秒）
    "check_interval": 30,
    # 连通性探测地址（204 探针，默认大陆节点）
    "captive_url": DEFAULT_CAPTIVE_URL,
    # 校园网认证门户地址：自动识别失败时作为兜底线索
    "portal_hint": "http://172.16.100.201/eportal/index.jsp",
    # 登录时自动拉起后台服务
    "auto_start": True,
    # 认证成功/失败时发系统通知
    "notify": True,
    # 是否记录运行日志（默认关闭：不手动开启就不写任何日志文件）
    "logging": False,
    # 仅当连接名称含 syny 的 WiFi 时才认证（避免在非校园网后台反复探测）
    "only_syny_wifi": True,
    # 用户是否已主动启用后台认证（用于区分「从未开启」和「手动停止」）
    "enabled": False,
}

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/61.0.3163.91 Safari/537.36"
)

MAX_LOG_BYTES = 1024 * 1024
KEEP_LOG_LINES = 800


# --------------------------------------------------------------------------- #
# 日志
# --------------------------------------------------------------------------- #
def ensure_support_dir() -> None:
    os.makedirs(SUPPORT_DIR, exist_ok=True)


def _rotate_log() -> None:
    try:
        if os.path.getsize(LOG_PATH) <= MAX_LOG_BYTES:
            return
        with open(LOG_PATH, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()[-KEEP_LOG_LINES:]
        with open(LOG_PATH, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
    except OSError:
        pass


def logging_enabled() -> bool:
    """日志是否记录。默认关闭——不手动开启就完全不落盘。"""
    return bool(load_config().get("logging", False))


def log(message: str, level: str = "INFO") -> None:
    """输出一条日志。

    只在「日志记录」开启时才写入文件；未开启则完全不创建、不写入日志文件。
    """
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = "[{}] {:<5} {}".format(stamp, level, message)

    if logging_enabled():
        ensure_support_dir()
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass
        _rotate_log()

    # 仅在终端前台运行时回显；后台运行时 stdout 已被重定向到日志文件，
    # 此时再 print 会造成同一条日志被记录两次。
    if sys.stdout.isatty():
        print(line, flush=True)


def clear_log() -> None:
    try:
        if os.path.exists(LOG_PATH):
            os.remove(LOG_PATH)
    except OSError:
        pass


def read_log_tail(max_lines: int = 300) -> str:
    try:
        with open(LOG_PATH, "r", encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-max_lines:])
    except OSError:
        return "(暂无日志)"


# --------------------------------------------------------------------------- #
# 配置（JSON 明文，仅存账号与开关；密码走钥匙串）
# --------------------------------------------------------------------------- #
def load_config() -> dict:
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            cfg.update({k: v for k, v in data.items() if k in DEFAULT_CONFIG})
    except (OSError, ValueError):
        pass
    # 旧配置里残留的旧默认探测地址自动迁移（用户自定义的地址不动）
    if cfg.get("captive_url") in LEGACY_CAPTIVE_URLS:
        cfg["captive_url"] = DEFAULT_CAPTIVE_URL
    try:
        cfg["check_interval"] = max(5, int(cfg["check_interval"]))
    except (TypeError, ValueError):
        cfg["check_interval"] = DEFAULT_CONFIG["check_interval"]
    return cfg


def save_config(updates: dict) -> None:
    """把 updates 合并进现有配置后落盘（未提到的项保持不变）。"""
    ensure_support_dir()
    current = load_config()
    current.update({k: v for k, v in updates.items() if k in DEFAULT_CONFIG})
    payload = {k: current.get(k, DEFAULT_CONFIG[k]) for k in DEFAULT_CONFIG}
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_PATH)


# --------------------------------------------------------------------------- #
# 钥匙串（密码不落盘）
# --------------------------------------------------------------------------- #
def keychain_set_password(username: str, password: str) -> bool:
    if not username:
        return False
    proc = subprocess.run(
        ["security", "add-generic-password", "-a", username, "-s", KEYCHAIN_SERVICE,
         "-w", password, "-U"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        log("钥匙串写入失败：{}".format(proc.stderr.strip()), "ERROR")
        return False
    return True


def keychain_get_password(username: str) -> str:
    if not username:
        return ""
    proc = subprocess.run(
        ["security", "find-generic-password", "-a", username, "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def keychain_delete_password(username: str) -> None:
    if not username:
        return
    subprocess.run(
        ["security", "delete-generic-password", "-a", username, "-s", KEYCHAIN_SERVICE],
        capture_output=True, text=True,
    )


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """禁止自动跟随跳转，方便读取认证页 URL。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: N802
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _decode_body(raw: bytes, content_type: str) -> str:
    """按响应声明的字符集解码正文，解不出来再靠试探兜底。

    为什么必须做这件事：锐捷 eportal 返回的是 **GBK**，且 Content-Type 里往往
    只写 ``text/html`` 不带 charset。旧实现一律 ``decode("utf-8", "replace")``，
    后果不只是「门户中文提示显示成乱码」，更严重的是**所有基于中文关键字的判断
    全部失效** —— 登录时的「已在线」、下线时的「下线/成功」、门户页的「登录」
    标记、以及识别「WEB认证设备未注册」这类异常页面，都会因为关键字匹配不上
    而走向错误分支。

    顺序：显式 charset → 严格 UTF-8 → GB18030 → 有损 UTF-8（保证不丢响应）。
    与 Swift 版 ``HTTP.decode`` 行为保持一致。
    """
    if not raw:
        return ""

    match = re.search(r"charset=([^\s;\"']+)", content_type or "", re.I)
    if match:
        declared = match.group(1).strip().lower()
        alias = {
            "utf-8": "utf-8", "utf8": "utf-8",
            "gbk": "gb18030", "gb2312": "gb18030", "gb-2312": "gb18030",
            "gb18030": "gb18030", "x-gbk": "gb18030", "cp936": "gb18030",
            "big5": "big5", "big-5": "big5",
            "iso-8859-1": "latin-1", "latin1": "latin-1",
            "us-ascii": "ascii", "ascii": "ascii",
        }.get(declared)
        if alias:
            try:
                return raw.decode(alias)
            except (LookupError, UnicodeDecodeError):
                pass

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        pass

    try:
        return raw.decode("gb18030")
    except UnicodeDecodeError:
        return raw.decode("utf-8", "replace")


def _http(url: str, data: bytes = None, headers: dict = None, timeout: int = 10):
    """返回 (status, text, headers)；status 为 None 表示网络层失败。"""
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    request = urllib.request.Request(url, data=data, headers=hdrs)
    try:
        with _OPENER.open(request, timeout=timeout) as resp:
            return (resp.status,
                    _decode_body(resp.read(), resp.headers.get("Content-Type", "")),
                    dict(resp.headers))
    except urllib.error.HTTPError as exc:
        return (exc.code,
                _decode_body(exc.read(), exc.headers.get("Content-Type", "")),
                dict(exc.headers))
    except Exception as exc:  # noqa: BLE001 - 网络异常种类多，统一降级
        return None, "{}: {}".format(type(exc).__name__, exc), {}


def _extract_portal(body: str, location: str) -> str:
    """从跳转头或响应正文里找出认证页 URL（原脚本取正文里第一个引号链接）。"""
    candidates = []
    if location:
        candidates.append(location)
    for match in re.finditer(r"""['"](https?://[^'"]+)['"]""", body or ""):
        candidates.append(match.group(1))
    for url in candidates:
        if "index.jsp" in url or "InterFace.do" in url:
            return url
    return candidates[0] if candidates else ""


def _looks_like_portal(url: str) -> bool:
    """判断一个 URL 是否像锐捷认证页（而非页面里的普通链接）。"""
    if not url:
        return False
    return ("index.jsp" in url) or ("InterFace.do" in url)


# 锐捷认证页里常见的几个参数（用于从页面正文重建认证页 URL）
_PORTAL_PARAM_KEYS = ("wlanuserip", "wlanacname", "nasip", "wlanacip", "usermac")


def _scrape_portal_params(body: str) -> dict:
    """从认证页 HTML/JS 里提取锐捷参数（wlanuserip/wlanacname/nasip 等）。

    未认证时 portal 服务器经常把本机 IP、AC 名、NAS IP 直接写进页面
    （隐藏表单域或 JS 变量），拿到这些就能拼出完整的 index.jsp 认证地址，
    从而不依赖路由器的拦截跳转。
    """
    if not body:
        return {}
    params: dict = {}
    for key in _PORTAL_PARAM_KEYS:
        # 1) <input ... name="wlanuserip" value="...">
        m = re.search(
            r'name=["\']%s["\'][^>]*?value=["\']([^"\']*)["\']' % re.escape(key),
            body, re.I)
        if not m:
            # 2) wlanuserip = "..." 或 wlanuserip:"..."（JS 赋值）
            m = re.search(
                r'%s\s*[=:]\s*["\']([^"\']+)["\']' % re.escape(key), body, re.I)
        if m:
            val = m.group(1).strip()
            if val:
                params[key] = val
    return params


def _reconstruct_portal(netloc: str, params: dict) -> str:
    """用抓取到的参数拼出 index.jsp 认证地址。"""
    keep = [k for k in _PORTAL_PARAM_KEYS if k in params]
    q = urllib.parse.urlencode({k: params[k] for k in keep})
    return "http://{}/eportal/index.jsp?{}".format(netloc, q)


def _probe_urls(cfg: dict):
    """按优先级返回要尝试的探针地址（去重）。"""
    urls = [cfg.get("captive_url") or DEFAULT_CONFIG["captive_url"]]
    urls.extend(FALLBACK_PROBES)
    seen, out = set(), []
    for url in urls:
        if url and url not in seen:
            seen.add(url)
            out.append(url)
    return out


def _local_ip() -> str:
    """取本机在当前网络下的出口 IP（UDP 连接不实际发包）。"""
    for target in (("223.5.5.5", 80), ("114.114.114.114", 80)):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(1)
            sock.connect(target)
            ip = sock.getsockname()[0]
            sock.close()
            if ip and not ip.startswith("127."):
                return ip
        except OSError:
            continue
    return ""


def current_wifi_ssid() -> str:
    """返回当前 WiFi 的 SSID；没有 WiFi 连接或无法读取时返回空串。

    依次尝试 en0/en1/en2（不同 Mac 上 WiFi 接口名不同），用 networksetup
    读取。未关联到任何 WiFi（如接以太网 / 飞行模式）时返回空串。

    networksetup 的输出会跟随系统语言本地化，因此这里强制 LANG/LC_ALL=C
    以稳定拿到英文输出，同时仍兼容中文标记，双保险。
    """
    markers = ("Current Wi-Fi Network:", "Wi-Fi 网络:", "Wi-Fi 网络：",
               "无线网络:", "无线网络：")
    env = dict(os.environ, LANG="C", LC_ALL="C")
    for iface in ("en0", "en1", "en2"):
        try:
            proc = subprocess.run(
                ["/usr/sbin/networksetup", "-getairportnetwork", iface],
                capture_output=True, text=True, timeout=5, env=env,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        out = (proc.stdout or proc.stderr or "").strip()
        for marker in markers:
            if marker in out:
                ssid = out.split(marker, 1)[1].strip()
                if ssid:
                    return ssid
        # 该接口不是 WiFi 或没有关联网络：尝试下一个接口
    return ""


def wifi_is_syny(cfg: dict = None) -> bool:
    """当前是否连接在名称含 syny 的 WiFi 上（大小写不敏感）。

    连到其他 WiFi、未关联 WiFi（以太网 / 离线）都返回 False。

    注意：读不到 SSID 时这里恒为 False，**不能**用它单独判断「是否在校园网」——
    macOS 13 起未获「定位服务」授权的进程一律拿不到 SSID，
    校园网判定请用 `evaluate_campus_access()`。
    """
    ssid = current_wifi_ssid()
    if not ssid:
        return False
    return "syny" in ssid.lower()


def _wifi_device() -> str:
    """解析 `networksetup -listallhardwareports`，找出 Wi-Fi 对应的设备名。"""
    env = dict(os.environ, LANG="C", LC_ALL="C")
    try:
        proc = subprocess.run(
            ["/usr/sbin/networksetup", "-listallhardwareports"],
            capture_output=True, text=True, timeout=5, env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = [ln.strip() for ln in (proc.stdout or proc.stderr or "").splitlines()]
    for idx, line in enumerate(lines):
        if line.startswith("Hardware Port:") and "Wi-Fi" in line:
            for follow in lines[idx + 1:]:
                if follow.startswith("Device:"):
                    return follow.split(":", 1)[1].strip()
    return ""


def _interface_has_ipv4(name: str) -> bool:
    """指定接口是否已拿到 IPv4 地址（即已连上某个网络）。"""
    if not name:
        return False
    try:
        proc = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", name],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return False
    return bool((proc.stdout or "").strip())


def wifi_status() -> dict:
    """采集无线网卡状态，供校园网降级判定与诊断输出使用。

    返回 dict：ssid / interface / has_interface / has_address /
    name_redacted / summary。
    """
    device = _wifi_device()
    has_iface = bool(device)
    has_addr = _interface_has_ipv4(device)
    if not device:
        # 解析失败时退回最常见的接口名（Apple Silicon 与多数 Intel Mac 都是 en0）
        for candidate in ("en0", "en1", "en2"):
            if _interface_has_ipv4(candidate):
                device, has_iface, has_addr = candidate, True, True
                break

    ssid = current_wifi_ssid()
    redacted = has_iface and has_addr and not ssid
    if ssid:
        summary = ssid
    elif redacted:
        summary = "(已连接，但系统未授权读取网络名)"
    elif has_iface:
        summary = "(未连接 Wi-Fi)"
    else:
        summary = "(无无线网卡)"
    return {
        "ssid": ssid,
        "interface": device,
        "has_interface": has_iface,
        "has_address": has_addr,
        "name_redacted": redacted,
        "summary": summary,
    }


def _portal_host(cfg: dict) -> str:
    """从配置的「认证门户」里取出主机名。"""
    hint = (cfg.get("portal_hint") or "").strip()
    try:
        return urllib.parse.urlsplit(hint).hostname or ""
    except ValueError:
        return ""


def _portal_port(cfg: dict) -> int:
    hint = (cfg.get("portal_hint") or "").strip()
    try:
        return urllib.parse.urlsplit(hint).port or 80
    except ValueError:
        return 80


def campus_portal_reachable(cfg: dict = None, timeout: float = 1.5) -> bool:
    """校园门户是否可达（纯 TCP 连接）。

    用 TCP 而非 HTTP：既不会触发 captive 弹窗，也不经过系统代理，
    判定结果不会被 VPN / 本地代理污染。门户是内网地址（如 172.16.100.201），
    只有身处校园网才连得上。
    """
    cfg = cfg or load_config()
    host = _portal_host(cfg)
    if not host:
        return False
    try:
        with socket.create_connection((host, _portal_port(cfg)), timeout=timeout):
            return True
    except OSError:
        return False


def evaluate_campus_access(cfg: dict = None):
    """判断「现在是否处于校园网」，返回 (is_on_campus, reason)。

    与 Swift 版 `PortalClient.evaluateCampusAccess` 同一语义：
      1. SSID 读得到 → 沿用「名称含 syny」的原语义；
      2. SSID 读不到（macOS 13+ 未授权定位服务时系统一律脱敏）→ 降级为
         「校园门户是否可达」。reason 会写进日志，便于排查。
    """
    cfg = cfg or load_config()
    status = wifi_status()

    if status["ssid"]:
        if "syny" in status["ssid"].lower():
            return True, "WiFi「{}」名称含 syny".format(status["ssid"])
        return False, "WiFi「{}」名称不含 syny".format(status["ssid"])

    host = _portal_host(cfg) or "?"
    situation = "Wi-Fi 已连接但名称不可读" if status["name_redacted"] else "未连接 Wi-Fi"
    if campus_portal_reachable(cfg):
        return True, "校园门户 {} 可达（{}）".format(host, situation)
    return False, "{}，且校园门户 {} 不可达".format(situation, host)


def probe(cfg: dict = None, timeout: int = 6):
    """探测网络状态。

    只以「配置的探测地址」为准判定是否在线 —— 部分校园网在未认证时会对
    其它探测域名放行，若把那些返回当作在线依据，就会漏掉认证。

    返回 (online, portal_url, detail)：

    - online=True  已联网，无需认证；
    - online=False 且 portal_url 非空，已定位到认证页；
    - online=False 且 portal_url 为空，未能判断（DNS/连接失败等），
      调用方仍应尝试认证，而不是直接放弃。
    """
    cfg = cfg or load_config()
    url = cfg.get("captive_url") or DEFAULT_CONFIG["captive_url"]
    status, body, headers = _http(url, timeout=timeout)

    if status == 204:
        return True, "", "{} → HTTP 204，网络正常".format(url)
    if status == 200:
        text = body or ""
        if not text.strip():
            return True, "", "{} → HTTP 200 空响应，网络正常".format(url)
        if "Microsoft Connect Test" in text:
            return True, "", "{} → 连通性正常".format(url)
    if status is None:
        return False, "", "{} → 连接失败（{}）".format(url, (body or "")[:80])

    portal = _extract_portal(body, headers.get("Location", ""))
    if _looks_like_portal(portal):
        return False, portal, "{} → HTTP {}，检测到认证页".format(url, status)
    return False, "", "{} → HTTP {}，未识别到认证页".format(url, status)


def detect(cfg: dict = None, timeout: int = 8):
    """兼容旧接口。返回 (state, portal_url, detail)，state ∈ online/offline/error。"""
    online, portal, detail = probe(cfg, timeout=timeout)
    if online:
        return "online", "", detail
    if portal:
        return "offline", portal, detail
    return "error", "", detail


def cache_portal(portal_url: str) -> None:
    """记录一次成功认证所用的门户主机与参数，供网络异常时重建。"""
    try:
        parsed = urllib.parse.urlsplit(portal_url)
        params = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        if not parsed.netloc or not params:
            return
        ensure_support_dir()
        payload = {
            "netloc": parsed.netloc,
            "path": parsed.path,
            "params": params,
            "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        tmp = PORTAL_CACHE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, PORTAL_CACHE_PATH)
    except (OSError, ValueError):
        pass


def _rebuild_portal_from_cache() -> str:
    """用上次成功的参数 + 当前本机 IP 重建认证页地址。"""
    try:
        with open(PORTAL_CACHE_PATH, "r", encoding="utf-8") as fh:
            cached = json.load(fh)
    except (OSError, ValueError):
        return ""
    netloc = cached.get("netloc") or ""
    params = dict(cached.get("params") or {})
    if not netloc or not params:
        return ""
    # wlanuserip 就是本机地址，网络重连后可能变化，用当前值覆盖
    if "wlanuserip" in params:
        ip = _local_ip()
        if ip:
            params["wlanuserip"] = ip
    path = cached.get("path") or "/eportal/index.jsp"
    if "index.jsp" not in path:
        path = "/eportal/index.jsp"
    return "http://{}{}?{}".format(netloc, path, urllib.parse.urlencode(params))


def cached_portal() -> str:
    """由上次成功认证的参数重建的认证页地址（无缓存时返回空串）。"""
    return _rebuild_portal_from_cache()


# --------------------------------------------------------------------------- #
# 会话标识 userIndex（手动下线需要）
# --------------------------------------------------------------------------- #
def save_session_userindex(user_index: str) -> None:
    """记录本次登录得到的 userIndex（锐捷会话标识），供「手动下线」使用。"""
    if not user_index:
        return
    try:
        ensure_support_dir()
        payload = {"userIndex": user_index,
                   "saved_at": time.strftime("%Y-%m-%d %H:%M:%S")}
        tmp = SESSION_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, SESSION_PATH)
        log("已记录会话标识 userIndex（手动下线可用）")
    except OSError:
        pass


def load_session_userindex() -> str:
    try:
        with open(SESSION_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return str(data.get("userIndex", "") or "")
    except (OSError, ValueError):
        return ""


def clear_session_userindex() -> None:
    try:
        if os.path.exists(SESSION_PATH):
            os.remove(SESSION_PATH)
    except OSError:
        pass


def _portal_netloc(cfg: dict = None) -> str:
    """返回认证门户主机（优先用缓存的门户，其次门户线索地址）。"""
    cfg = cfg or load_config()
    cached = _rebuild_portal_from_cache()
    if cached:
        netloc = urllib.parse.urlsplit(cached).netloc
        if netloc:
            return netloc
    hint = (cfg.get("portal_hint") or "").strip() or DEFAULT_CONFIG["portal_hint"]
    return urllib.parse.urlsplit(hint).netloc


# 抓取 userIndex 失败时的「内容指纹」，用于给重复失败去重。
# 守护进程每轮都会尝试抓取，失败原因通常一模一样，没必要反复写日志。
_CAPTURE_MISS_FINGERPRINT = ""


def portal_page_is_abnormal(text: str) -> bool:
    """门户页面是否处于「学校侧异常」状态。

    实测见过的一种：``/eportal/index.jsp`` 不再返回登录页，而是返回
    ``<script>alert('WEB认证设备未注册，请确认SAM+/portal/设备上的参数配置是否一致');</script>``。
    这属于学校认证设备（SAM+ / portal 对接参数）的配置问题，与本软件无关，
    但会让「抓 userIndex」「打开认证页」全部失效，因此单独识别出来，
    避免笼统地报成「未含 userIndex」误导排查方向。
    """
    if not text:
        return False
    lower = text.lower()
    if "<script>alert(" in lower and "未注册" in text:
        return True
    return "WEB认证设备未注册" in text


def fetch_online_userindex(cfg: dict = None, timeout: int = 6):
    """向门户口径查询「本机当前的在线会话」，返回 (userIndex, 门户说明)。

    锐捷 ``InterFace.do?method=getOnlineUserInfo`` 会直接给出当前会话的
    userIndex；门户侧没有会话时返回
    ``{"userIndex":null,"result":"fail","message":"获取用户信息失败，用户可能已经下线"}``。
    这是判断「到底有没有会话可下线」最权威的一手信息，比解析 index.jsp
    跳转可靠得多（后者在门户页面异常时完全拿不到线索）。
    userIndex 为空 = 门户侧确认没有会话。
    """
    cfg = cfg or load_config()
    host = _portal_netloc(cfg)
    if not host:
        return "", "门户地址未确定"
    url = "http://{}/eportal/InterFace.do?method=getOnlineUserInfo".format(host)
    status, text, _ = _http(url, timeout=timeout)
    if status is None:
        return "", "门户不可达（{}）".format(text[:60])

    payload = _try_json(text)
    index = ""
    message = ""
    if isinstance(payload, dict):
        raw_index = payload.get("userIndex")
        index = str(raw_index).strip() if raw_index else ""
        message = str(payload.get("message") or payload.get("msg") or "")
    if index:
        save_session_userindex(index)
        return index, message
    return "", message or (text or "").strip()[:120]


def capture_userindex_if_online(cfg: dict = None, timeout: int = 8) -> str:
    """已在线时访问门户入口，门户会 302 跳到 success.jsp?userIndex=...，借此拿到会话标识。

    锐捷门户在「已认证」状态下访问 index.jsp 会重定向到 success.jsp 并带上
    userIndex；断网（未认证）时则只返回登录表单、不含 userIndex。因此仅在确实
    在线时才可能拿到，拿到即持久化，供「手动下线」使用（即便本次登录不是由本软件发起）。
    """
    cfg = cfg or load_config()
    global _CAPTURE_MISS_FINGERPRINT
    host = _portal_netloc(cfg)
    if not host:
        log("抓取 userIndex：门户地址未知，跳过")
        return ""
    url = "http://{}/eportal/index.jsp".format(host)
    status, body, headers = _http(url, timeout=timeout)
    if status is None:
        log("抓取 userIndex：{} 连接失败".format(url))
        return ""
    hay = (headers.get("Location", "") or "") or (body or "")
    m = re.search(r"userIndex=([^&\s\"'<>]+)", hay)
    if m:
        ui = urllib.parse.unquote(m.group(1).strip())
        if ui:
            _CAPTURE_MISS_FINGERPRINT = ""
            save_session_userindex(ui)
            return ui

    # 失败很常见（门户口径无会话 / 门户页面异常 / 该门户不是本网段的认证设备），
    # 且守护进程会周期性重试，因此按「内容指纹」去重：同样的失败只记一次，
    # 避免每轮都往日志里灌一段 HTML 片段。
    fingerprint = "{}|{}".format(status, hay[:120])
    if fingerprint == _CAPTURE_MISS_FINGERPRINT:
        return ""
    _CAPTURE_MISS_FINGERPRINT = fingerprint

    if portal_page_is_abnormal(hay):
        log("抓取 userIndex：门户认证页异常（学校侧配置问题，非本软件故障），"
            "{} 返回：{}".format(url, hay[:90]))
    else:
        # 常见于「该门户不是当前网段的认证设备」或「本次会话非认证页建立」，
        # 记下来，方便判断手动下线失败的根因。
        log("抓取 userIndex：{} 返回 HTTP {}，未含 userIndex（响应片段：{}）".format(
            url, status, hay[:80]))
    return ""


def discover_portal(cfg: dict = None, timeout: int = 5, skip_probes: bool = False):
    """在探针未直接给出认证页时，多路尝试定位认证页地址。

    依次尝试：常规探针 → IP 直连触发（绕开 DNS）→ 门户地址线索（根路径会
    自动追到 /eportal/index.jsp 并抓取页面里的 wlanuserip/wlanacname/nasip
    参数重建）→ 用上次成功认证的参数重建。返回 (portal_url, 来源说明)。
    skip_probes=True 用于跳过常规探针（调用方刚刚试过，避免重复请求）。
    """
    cfg = cfg or load_config()
    tried = []

    def _learn(url: str) -> str:
        """对某个地址尝试：直接识别认证页 / 抓取参数重建 / 追到 index.jsp。"""
        status, body, headers = _http(url, timeout=timeout)
        if status is None:
            return ""
        portal = _extract_portal(body, headers.get("Location", ""))
        if _looks_like_portal(portal):
            return portal
        # 从页面正文抓取锐捷参数重建认证页（断网时路由器未做跳转也能用）
        params = _scrape_portal_params(body)
        if params:
            netloc = urllib.parse.urlsplit(url).netloc
            rebuilt = _reconstruct_portal(netloc, params)
            cache_portal(rebuilt)
            return rebuilt
        # 根路径或未知页：再追一层 /eportal/index.jsp（锐捷常用入口）
        netloc = urllib.parse.urlsplit(url).netloc
        if netloc:
            idx = "http://{}/eportal/index.jsp".format(netloc)
            s2, b2, h2 = _http(idx, timeout=timeout)
            if s2 is not None:
                p2 = _scrape_portal_params(b2)
                if p2:
                    rebuilt = _reconstruct_portal(netloc, p2)
                    cache_portal(rebuilt)
                    return rebuilt
                portal2 = _extract_portal(b2, h2.get("Location", ""))
                if _looks_like_portal(portal2):
                    return portal2
        return ""

    def _try(url: str, label: str) -> str:
        found = _learn(url)
        if found:
            return found
        tried.append("{}：未识别到认证页".format(label))
        return ""

    if not skip_probes:
        for url in _probe_urls(cfg):
            found = _try(url, url)
            if found:
                return found, "来自探针 {}".format(url)

    for url in IP_TRIGGERS:
        found = _try(url, url)
        if found:
            return found, "来自 IP 直连 {}".format(url)

    hint = (cfg.get("portal_hint") or "").strip()
    if hint:
        found = _try(hint, hint)
        if found:
            return found, "来自门户线索 {}".format(hint)

    rebuilt = _rebuild_portal_from_cache()
    if rebuilt:
        return rebuilt, "由上次成功认证的参数重建"

    return "", "；".join(tried)


def learn_portal_while_online(cfg: dict = None, timeout: int = 5) -> str:
    """在线时也尝试预学习门户地址并写入缓存，供断线后重建。

    返回缓存到的门户地址（未学到则返回空串）。这是「用户当前在线、
    无法复现 captive 页面」场景下的兜底：趁着门户服务器可达，先把
    wlanacname/nasip 等固定参数存下来，下次断网就能直接复用。
    """
    cfg = cfg or load_config()
    # 1) 用已缓存的门户直接刷新 wlanuserip（本机 IP 可能已变）
    cached = _rebuild_portal_from_cache()
    if cached:
        cache_portal(cached)
        return cached
    # 2) 尝试门户线索地址
    hint = (cfg.get("portal_hint") or "").strip()
    if hint:
        found, _ = discover_portal(cfg, timeout=timeout, skip_probes=True)
        if found:
            return found
    return ""


# 锐捷登录页里常见的标记，用于判断「门户是否仍要求登录」
_PORTAL_LOGIN_MARKERS = (
    "userId", "password", "登录", "logon", "InterFace.do?method=login",
    "wlanuserip", "eportal",
)


def portal_needs_login(cfg: dict = None, timeout: int = 5) -> bool:
    """交叉校验：探测域名若被放行（误判在线），直接问门户是否还需登录。

    仅在本机出口可达门户、且门户明显返回登录表单时才返回 True，
    避免误触发。连不上门户时返回 False（以探测域名为准）。
    """
    cfg = cfg or load_config()
    hint = (cfg.get("portal_hint") or "").strip()
    if not hint:
        return False
    status, body, headers = _http(hint, timeout=timeout)
    if status is None:
        return False
    # 已认证时门户通常 302 跳到 success 页，或正文含「已登录/成功」
    loc = (headers.get("Location", "") or "").lower()
    if "success" in loc or "already" in loc or "online" in loc:
        return False
    low = (body or "").lower()
    if any(m.lower() in low for m in _PORTAL_LOGIN_MARKERS):
        return True
    return False


def _try_json(text: str):
    text = (text or "").strip()
    for candidate in (text, None):
        if candidate is None:
            match = re.search(r"\{.*\}", text, re.S)
            candidate = match.group(0) if match else ""
        if not candidate:
            continue
        try:
            return json.loads(candidate)
        except ValueError:
            continue
    return None


def login(portal_url: str, username: str, password: str, timeout: int = 12):
    """向锐捷 eportal 提交登录。返回 (success, message)。"""
    parsed = urllib.parse.urlsplit(portal_url)
    path = parsed.path or "/"
    if "index.jsp" in path:
        path = path.replace("index.jsp", "InterFace.do")
    elif "InterFace.do" not in path:
        path = "/eportal/InterFace.do"
    login_url = "{}://{}{}?method=login".format(
        parsed.scheme or "http", parsed.netloc, path
    )

    query = parsed.query or ""
    # 与原脚本一致：query 做二次 URL 编码后放进 queryString
    doubled = urllib.parse.quote(urllib.parse.quote(query, safe=""), safe="")
    form = "&".join([
        "userId=" + urllib.parse.quote(username, safe=""),
        "password=" + urllib.parse.quote(password, safe=""),
        "service=",
        "queryString=" + doubled,
        "operatorPwd=",
        "operatorUserId=",
        "validcode=",
        "passwordEncrypt=false",
    ])

    status, text, _ = _http(
        login_url,
        data=form.encode("utf-8"),
        headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Referer": portal_url,
            "Cookie": "EPORTAL_COOKIE_USERNAME=; EPORTAL_COOKIE_PASSWORD=;",
        },
        timeout=timeout,
    )
    if status is None:
        return False, "登录请求失败：{}".format(text)

    payload = _try_json(text)
    if payload is None:
        return False, "响应无法解析(HTTP {})：{}".format(status, (text or "")[:160])

    # 记录会话标识 userIndex，供「手动下线」使用（响应未直接给则尝试从正文提取）
    ui = payload.get("userIndex")
    if not ui:
        m = re.search(r"userIndex=([^&\s\"'<>]+)", text or "")
        ui = m.group(1) if m else None
    if ui:
        ui = urllib.parse.unquote(str(ui).strip())
        if ui:
            save_session_userindex(ui)

    result = str(payload.get("result", "")).strip().lower()
    message = payload.get("message") or payload.get("msg") or ""
    if result == "success":
        return True, message or "认证成功"
    if "已在线" in message or "已经在线" in message:
        return True, message
    return False, message or "认证失败(HTTP {})".format(status)


def authenticate(cfg: dict = None):
    """执行一轮「探测 + 必要时认证」。

    返回 (ok, message, need_auth)：need_auth 表示本轮确实发起了认证请求。

    与原版的关键差别：探测失败（DNS 不通、连接超时）不再直接放弃，
    而是继续尝试定位认证页并登录 —— 这正是「断网后浏览器弹出认证页、
    自动认证却没反应」的根因。
    """
    cfg = cfg or load_config()
    username = cfg.get("username", "")
    if not username:
        return False, "尚未配置账号", False

    online, portal, detail = probe(cfg)
    if online:
        return True, "网络已在线，无需认证（{}）".format(detail), False

    password = keychain_get_password(username)
    if not password:
        return False, "钥匙串中没有该账号的密码，请重新保存设置", False

    source = "探测直接识别"
    if not _looks_like_portal(portal):
        portal, source = discover_portal(cfg, skip_probes=True)
    if not portal:
        return False, "未能定位认证页地址（{}）".format(source or detail), False

    log("尝试认证：认证页={}（{}）".format(portal, source))
    ok, message = login(portal, username, password)
    if ok:
        cache_portal(portal)
        # 顺手抓取 userIndex（已在线时门户会 302 到 success.jsp?userIndex=...），
        # 用于「手动下线」
        capture_userindex_if_online(cfg)
    return ok, message, True


def authenticate_once(cfg: dict = None):
    """探测 + 登录一次性完成。返回 (success, message)。"""
    ok, message, _ = authenticate(cfg)
    return ok, message


def logout(cfg: dict = None, timeout: int = 12):
    """手动下线（注销当前锐捷会话）。返回 (success, message)。

    调用锐捷标准的 InterFace.do?method=logout 接口，需要 userIndex 会话标识。
    userIndex 来自上次登录响应，或已在线时从门户跳转自动抓取；若都没有，
    则先尝试现场抓取一次，仍失败则提示用户先登录。

    下线后追加一次连通性复检：若校园网启用了无感知认证（按设备 MAC 自动
    放行），门户注销不会立刻断网。此时如实提示「门户已接受注销，但网络仍
    可访问」，而不是简单报成功或失败。
    """
    cfg = cfg or load_config()
    host = _portal_netloc(cfg)
    user_index = load_session_userindex()
    # 门户口径结论：本机是不是压根就没有可注销的会话。
    # 区分「拿不到 userIndex」和「本来就没有会话」很重要 —— 前者像软件故障，
    # 后者是网络放行机制决定的客观事实，提示文案完全不同。
    portal_session_absent = False
    portal_note = ""

    log("手动下线：门户={} userIndex={}".format(
        host or "(未确定)", user_index or "(无缓存)"))

    if not user_index:
        # 第一顺位：问门户口径。getOnlineUserInfo 是权威答案，且直接给 userIndex。
        portal_index, portal_note = fetch_online_userindex(cfg, timeout=timeout)
        if portal_index:
            user_index = portal_index
            log("手动下线：门户口径返回会话 userIndex={}，直接使用".format(portal_index))
        else:
            portal_session_absent = True
            log("手动下线：门户口径确认本机无在线会话（{}）".format(portal_note))
            # 第二顺位：部分门户未实现 getOnlineUserInfo，仍按老路子抓一次跳转兜底。
            user_index = capture_userindex_if_online(cfg, timeout=timeout)
            if user_index:
                portal_session_absent = False
                log("手动下线：改由门户跳转抓到 userIndex={}".format(user_index))

    if not host:
        message = "无法确定认证门户地址，请在「高级设置 → 认证门户」中填写。"
        log("手动下线失败：{}".format(message), "WARN")
        return False, message

    if not user_index:
        if portal_session_absent:
            message = ("门户（{}）侧确认本机当前没有在线会话，因此没有可注销的登录。\n\n"
                       "你的网络很可能由校园网侧「免认证 / MAC 白名单（无感知认证）」放行，"
                       "这种情况门户注销无法断开网络。\n"
                       "如需断开，请在系统 Wi-Fi 菜单里断开该网络，或改用有线 / 热点。").format(host)
            log("手动下线：无可注销会话（{}）".format(portal_note), "WARN")
            return False, message
        message = ("未检测到登录会话标识（userIndex）。\n"
                   "请先通过本软件登录，或在浏览器认证页点击「下线」后重试。")
        log("手动下线失败：{}".format(message), "WARN")
        return False, message

    url = "http://{}/eportal/InterFace.do?method=logout".format(host)
    form = "userIndex=" + urllib.parse.quote(user_index, safe="")
    status, text, _ = _http(
        url, data=form.encode("utf-8"),
        headers={
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "Referer": "http://{}/eportal/success.jsp".format(host),
            "Cookie": "EPORTAL_COOKIE_USERNAME=; EPORTAL_COOKIE_PASSWORD=;",
        },
        timeout=timeout,
    )
    if status is None:
        message = "下线请求失败：{}".format(text)
        log("手动下线失败：{}".format(message), "WARN")
        return False, message

    body = (text or "").strip()
    log("手动下线：HTTP {} 响应={}".format(status, body[:200]))

    succeeded = False
    message = ""
    payload = _try_json(text)
    if payload is not None:
        result = str(payload.get("result", "")).strip().lower()
        message = payload.get("message") or payload.get("msg") or ""
        if result in ("success", "logout") or "成功" in message or "下线" in message:
            succeeded = True
    if not succeeded:
        low = body.lower()
        if "success" in low or "下线" in body or "成功" in body:
            succeeded = True
            message = "已下线成功"

    if not succeeded:
        detail = message or body[:160]
        log("手动下线失败：HTTP {} {}".format(status, detail), "WARN")
        return False, "下线失败(HTTP {})：{}".format(status, detail)

    clear_session_userindex()

    # 复检：门户接受注销，但无感知认证会立刻重新放行，用户会感觉「下线没生效」
    still_online = bool(probe(cfg, timeout=4)[0])
    final_message = message or "已下线成功"
    if still_online:
        final_message += ("\n\n注意：注销请求已被门户接受，但复检显示网络仍可访问。"
                          "这通常意味着该网络启用了无感知认证（按设备 MAC 自动"
                          "放行），门户注销不会立即断网。")
        log("手动下线：门户已接受注销，但复检仍在线（疑似无感知认证）", "WARN")
    else:
        log("手动下线成功：{}".format(final_message))

    if cfg.get("notify", False):
        notify("SYNY 校园网", "网络仍可访问（已提交下线）" if still_online else "已手动下线")
    return True, final_message


# --------------------------------------------------------------------------- #
# 系统通知
# --------------------------------------------------------------------------- #
def notify(title: str, message: str, subtitle: str = "") -> None:
    script = 'display notification {} with title {}'.format(
        json.dumps(message, ensure_ascii=False), json.dumps(title, ensure_ascii=False)
    )
    if subtitle:
        script += " subtitle {}".format(json.dumps(subtitle, ensure_ascii=False))
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=5)
    except Exception:  # noqa: BLE001 - 通知失败不影响主流程
        pass


# --------------------------------------------------------------------------- #
# launchd 后台服务
# --------------------------------------------------------------------------- #
def app_resources_dir() -> str:
    """返回包含 syny_auth 包的目录（用于设置 PYTHONPATH）。"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _plist_payload() -> dict:
    cfg = load_config()
    # 未开启日志记录时，把守护进程的标准输出丢弃，避免 launchd 自行落盘产生日志
    out_path = LOG_PATH if cfg.get("logging", False) else os.devnull
    return {
        "Label": LABEL,
        "ProgramArguments": [
            sys.executable, "-m", "syny_auth", "daemon",
        ],
        "EnvironmentVariables": {
            "PYTHONPATH": app_resources_dir(),
            "PYTHONUNBUFFERED": "1",
        },
        "WorkingDirectory": SUPPORT_DIR,
        "RunAtLoad": bool(cfg.get("auto_start", True)),
        # 仅当异常退出时才被 launchd 拉起；正常退出（如尚未配置账号）不再重启，避免空转
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "StandardOutPath": out_path,
        "StandardErrorPath": out_path,
    }


def agent_installed() -> bool:
    return os.path.exists(PLIST_PATH)


def agent_state():
    """返回 (loaded, running, pid)。

    注意：launchctl print 对「已加载但进程已退出」的任务同样返回 0，
    因此必须额外解析 state / pid 才能判断是否真的在跑。
    """
    proc = subprocess.run(
        ["launchctl", "print", "gui/{}/{}".format(os.getuid(), LABEL)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return False, False, None
    out = proc.stdout
    pid_match = re.search(r"\bpid = (\d+)", out)
    state_match = re.search(r"\bstate = (\w+)", out)
    state = state_match.group(1) if state_match else ""
    running = bool(pid_match) and state in ("running", "")
    return True, running, int(pid_match.group(1)) if pid_match else None


def agent_running() -> bool:
    return agent_state()[1]


def agent_loaded() -> bool:
    return agent_state()[0]


def agent_pid():
    return agent_state()[2]


def _bootout() -> None:
    """仅把服务从 launchd 卸载，不删除 plist 文件。"""
    subprocess.run(
        ["launchctl", "bootout", "gui/{}/{}".format(os.getuid(), LABEL)],
        capture_output=True, text=True,
    )
    subprocess.run(
        ["launchctl", "unload", "-w", PLIST_PATH], capture_output=True, text=True
    )


def install_agent() -> bool:
    ensure_support_dir()
    os.makedirs(os.path.dirname(PLIST_PATH), exist_ok=True)
    # 先卸载旧实例（保留旧 plist 供 launchctl 识别），再写入新的服务定义
    _bootout()
    with open(PLIST_PATH, "wb") as fh:
        plistlib.dump(_plist_payload(), fh, fmt=plistlib.FMT_XML)

    target = "gui/{}".format(os.getuid())
    messages = []
    proc = subprocess.run(
        ["launchctl", "bootstrap", target, PLIST_PATH], capture_output=True, text=True
    )
    messages.append((proc.stderr or "").strip())
    if proc.returncode != 0:
        # 兼容旧版 launchctl；注意 load 即使失败也返回 0，必须看 stderr 并复核状态
        proc = subprocess.run(
            ["launchctl", "load", "-w", PLIST_PATH], capture_output=True, text=True
        )
        messages.append((proc.stderr or "").strip())
    if proc.returncode != 0:
        log("后台服务注册失败：{}".format(
            "；".join(m for m in messages if m) or "未知错误"), "ERROR")
        return False

    subprocess.run(
        ["launchctl", "enable", "gui/{}/{}".format(os.getuid(), LABEL)],
        capture_output=True, text=True,
    )

    # 复核：launchctl 的返回码不可靠，以实际加载状态为准
    if not agent_loaded():
        log("后台服务注册未生效：{}".format(
            "；".join(m for m in messages if m) or "服务未出现在 launchd 中"), "ERROR")
        return False

    log("后台服务已安装并启动")
    return True


def uninstall_agent(quiet: bool = False) -> None:
    _bootout()
    if os.path.exists(PLIST_PATH):
        try:
            os.remove(PLIST_PATH)
        except OSError:
            pass
    if not quiet:
        log("后台服务已停止并移除")


def restart_agent() -> bool:
    proc = subprocess.run(
        ["launchctl", "kickstart", "-k", "gui/{}/{}".format(os.getuid(), LABEL)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return install_agent()
    log("后台服务已重启")
    return True


# --------------------------------------------------------------------------- #
# 独立进程模式（launchd 不可用时的回退方案）
#
# 部分环境（如受限的虚拟机 / 沙箱）会拒绝 launchctl bootstrap，此时改用
# 「脱离终端的独立守护进程」，同样能实现窗口关闭后继续自动认证。
# --------------------------------------------------------------------------- #
def _read_pid_file():
    try:
        with open(PID_PATH, "r", encoding="utf-8") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def daemon_pid():
    """返回独立守护进程 PID；进程已不存在则返回 None。"""
    pid = _read_pid_file()
    return pid if pid and _pid_alive(pid) else None


def spawn_daemon():
    """直接拉起一个脱离终端的守护进程。返回 (ok, message)。"""
    if not load_config().get("username"):
        return False, "尚未配置校园网账号"
    stop_daemon()
    ensure_support_dir()

    cfg = load_config()
    target = LOG_PATH if cfg.get("logging", False) else os.devnull
    env = dict(os.environ)
    env["PYTHONPATH"] = app_resources_dir()
    env["PYTHONUNBUFFERED"] = "1"

    try:
        with open(target, "a", encoding="utf-8") as sink:
            proc = subprocess.Popen(
                [sys.executable, "-m", "syny_auth", "daemon"],
                cwd=SUPPORT_DIR, env=env, stdin=subprocess.DEVNULL,
                stdout=sink, stderr=sink, start_new_session=True,
            )
    except OSError as exc:
        return False, "守护进程启动失败：{}".format(exc)

    time.sleep(1.5)
    if daemon_pid():
        return True, "后台认证已启动（独立进程模式，PID {}）".format(proc.pid)
    return False, "守护进程启动后立即退出，请检查账号与密码是否正确"


def stop_daemon(timeout: float = 5.0) -> bool:
    """终止独立守护进程。返回是否真的结束了某个进程。"""
    pid = _read_pid_file()
    stopped = False
    if pid and _pid_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.time() + timeout
        while time.time() < deadline and _pid_alive(pid):
            time.sleep(0.2)
        if _pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        stopped = True
    if os.path.exists(PID_PATH):
        try:
            os.remove(PID_PATH)
        except OSError:
            pass
    return stopped


# --------------------------------------------------------------------------- #
# 统一的服务控制接口
# --------------------------------------------------------------------------- #
def service_state():
    """返回 (mode, running, pid)。mode ∈ {"launchd", "process", "stopped"}。"""
    if agent_loaded():
        return "launchd", agent_running(), agent_pid()
    pid = daemon_pid()
    if pid:
        return "process", True, pid
    return "stopped", False, None


def _set_enabled(flag: bool) -> None:
    save_config({"enabled": flag})


def start_service():
    """优先 launchd 托管；失败则回退到独立进程模式。

    返回 (ok, message)。
    """
    if install_agent():
        _set_enabled(True)
        return True, "后台认证已启用（登录自启，异常退出会自动重启）"
    ok, message = spawn_daemon()
    if ok:
        _set_enabled(True)
        return True, ("本机无法注册 launchd 服务，已改用独立进程模式运行："
                      "关闭窗口后仍会自动认证，但重启电脑后需重新打开本应用。")
    return False, message


def stop_service() -> None:
    _set_enabled(False)
    uninstall_agent(quiet=True)
    stop_daemon()
    log("后台服务已停止")
