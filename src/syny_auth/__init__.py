"""SYNY 校园网自动认证（macOS 版）。

把原来运行在路由器上的 ruijie_auto.sh 移植成一个 macOS 本地应用：
- 图形界面用于设置账号 / 密码（密码存入系统钥匙串，不落明文）
- launchd 后台服务常驻，断网自动重新认证
"""

__version__ = "1.0.0"
__all__ = ["__version__"]
