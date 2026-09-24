# SYNY 校园网自动认证

[![Release](https://img.shields.io/badge/release-v2.2.0-blue)](https://github.com/luyiheng1111/MacAutoSYNY/releases/tag/v2.2.0)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://github.com/luyiheng1111/MacAutoSYNY/releases)
[![Arch](https://img.shields.io/badge/arch-Apple%20Silicon-ff69b4)](https://github.com/luyiheng1111/MacAutoSYNY/releases)

macOS 菜单栏小工具，自动登录 **嘉兴南洋职业技术学院** 的锐捷 eportal 校园网。
连上 `syny` 开头的 WiFi 后，无需再手动打开认证页输账号密码——后台会自动探测、自动认证。

> 纯 Swift 实现，安装包内 **不含任何 Python 运行时**，Mac 用户开箱即用。

---

## 功能特性

- **自动认证**：连上校园网后自动完成锐捷 eportal 登录，断网/切换网络后自动重连。
- **菜单栏常驻**：图标常驻屏幕右上角，不占用程序坞（Dock）。
- **开机自启**：开启后台认证后，重启电脑会自动在后台运行，无需手动打开。
- **手动控制**：可在图形界面或命令行手动触发一次认证 / 立即下线。
- **状态可视**：随时查看当前配置、校园网判定依据、门户会话有无。
- **密码安全**：账号密码保存在 macOS 系统钥匙串（Keychain），不落地明文。
- **零 Python 依赖**：后端、守护进程、GUI 全部原生 Swift，单可执行文件五合一。

---

## 系统要求

- macOS 13.0（Ventura）及以上
- Apple 芯片（M1 / M2 / M3 / M4）
- 仅针对嘉兴南洋职业技术学院校园网（锐捷 eportal）适配

---

## 安装

1. 前往 [Releases](https://github.com/luyiheng1111/MacAutoSYNY/releases) 下载 `SYNY-<版本>.dmg`；
2. 打开 DMG，把 **SYNY** 拖到右侧的 **应用程序** 文件夹；
3. 首次打开会被 Gatekeeper 拦截（本工具未购买 Apple 开发者签名证书），这是正常的系统安全机制：
   - **macOS 15 (Sequoia) 及以上**：双击触发拦截后，进入「系统设置 → 隐私与安全性」，点「仍要打开」（该按钮在拦截后约 1 小时内出现，找不到就重新双击一次 SYNY 再回来找）。
   - **macOS 14 (Sonoma) 及更早**：在「应用程序」里按住 Control 键点 SYNY，选「打开」。
4. 若提示「SYNY 已损坏，无法打开」，在终端执行：
   ```sh
   xattr -dr com.apple.quarantine /Applications/SYNY.app
   ```
   再重新打开即可。

---

## 使用

1. 打开 SYNY，菜单栏（右上角）出现图标；
2. 若系统弹出「SYNY 想要查找并连接到本地网络上的设备」，请点 **允许**（校园网认证需要本地网络权限）；
3. 点菜单栏图标，填写校园网账号和密码，点 **保存并启用后台认证**；
4. 完成。之后连上 `syny` 的 WiFi 即自动登录。

---

## 命令行工具

`SYNY.app/Contents/MacOS/SYNY` 是同一份可执行文件，兼具 GUI 与命令行能力，
便于在图形界面之外排查问题：

| 命令 | 作用 |
| --- | --- |
| `SYNY` | 打开菜单栏设置界面（默认） |
| `SYNY daemon` | 前台运行后台认证循环（launchd 即以此方式托管） |
| `SYNY test` | 立即执行一次「探测 + 认证」并输出结果 |
| `SYNY logout` | 手动下线（注销门户会话），并说明到底有没有会话可注销 |
| `SYNY status` | 查看配置、校园网判定依据与后台服务状态 |
| `SYNY -h` | 查看帮助 |

示例：

```sh
# 查看当前状态（校园网判定 + 门户会话一目了然）
/Applications/SYNY.app/Contents/MacOS/SYNY status
```

---

## 工作原理

- **探测**：定时请求连通性探针 `http://connect.rom.miui.com/generate_204`，
  若需认证则说明当前处于校园网环境。
- **校园网判定**：优先按 WiFi 名称（含 `syny`）判断；当系统未授权定位、
  SSID 被脱敏时，降级为「校园门户 TCP 可达」判定，日志会写明是哪一种来源。
- **认证**：向锐捷门户 `172.16.100.201` 发起 eportal 登录。门户正文为 GBK 编码，
  程序按 `charset → UTF-8 → GB18030` 顺序解码，避免中文关键字判定失效。
- **会话口径**：以下线 / 状态判断「是否真有会话」时，统一以门户口径
  `InterFace.do?method=getOnlineUserInfo` 为准（比解析 `index.jsp` 跳转可靠）。
- **后台托管**：通过 LaunchAgent（`com.syny.auth`）常驻，配置与日志位于
  `~/Library/Application Support/SYNYAuth/`。

---

## 常见问题

**Q：菜单栏里找不到图标？**
A：SYNY 只在菜单栏显示，不会出现在程序坞。把鼠标移到屏幕右上角图标区找一找。

**Q：电脑重启后自动认证还生效吗？**
A：生效。点过「保存并启用后台认证」后，重启会自动在后台运行，无需手动打开。

**Q：账号密码存在哪里？安全吗？**
A：密码保存在 macOS 系统钥匙串，经系统加密，不写任何明文配置文件。

**Q：连上 WiFi 但没自动认证 / 下线没反应？**
A：先在终端跑 `SYNY status` 看「校园网判定」和「门户会话」两行：
- 若判定为「非校园网环境」，检查 WiFi 名称或门户可达性；
- 若门户返回「WEB认证设备未注册…」，属于学校 SAM+/portal 配置问题，
  需联系学校网络中心，与软件无关；
- 若门户侧无会话但网络直通，说明处于 **免认证 / MAC 白名单放行** 状态，
  此时上线/下线无从验证，同样需学校侧处理。

---

## 卸载

1. 退出菜单栏的 SYNY（点图标里的「退出」）；
2. 把「应用程序」里的 SYNY 拖到废纸篓；
3. 如需彻底清除配置，访达按 `Command+Shift+G`，输入
   `~/Library/Application Support/SYNYAuth` 删除其中文件。

---

## 从源码构建

依赖：Xcode 命令行工具（`swift` 与 `swift package`）。

```sh
# 1) 仅编译 SYNY.app 到项目根目录
./scripts/build-swift.sh

# 2) 打包为可分发 DMG（会自动先构建 app，产物在 dist/）
./scripts/build-dmg.sh

# 可选参数：
#   --skip-build   跳过 app 构建，直接用现有 SYNY.app 打包
#   --open         打包完成后自动打开 DMG 预览
#   --relayout     用 Finder 重新生成窗口布局（需「自动化 → 访达」权限）
```

产物：`SYNY.app`（菜单栏应用）与 `dist/SYNY-<版本>.dmg`（安装盘）。
版本号唯一来源为 `scripts/build-swift.sh` 中 Info.plist 的 `CFBundleShortVersionString`。

---

## 隐私与安全

- 密码仅存于本机钥匙串，不上传、不联网外发。
- 仅与校园网认证门户及连通性探针通信，无其他网络行为。
- 应用未做开发者签名，首次打开需手动放行 Gatekeeper（见上方安装说明）。

---

## 已知限制

- 仅适配嘉兴南洋职业技术学院的锐捷 eportal，其他学校门户不保证可用。
- 若学校开启免认证 / MAC 白名单放行，门户侧无会话但网络直通，
  上线/下线功能无法验证，需学校网络中心配合。
- 当前仅提供 Apple 芯片（arm64）构建。

---

## License

本项目仅供嘉兴南洋职业技术学院在校师生校园网便利使用。
