# frp 隧道面板

一个 macOS 菜单栏小工具，用来管理 [frp](https://github.com/fatedier/frp) 内网穿透隧道——把本机（比如 Mac mini）跑的服务，通过一台有公网 IP 的服务器暴露出去。

不是 frp 本身的替代品，是一个"少改配置文件、少手动 SSH 上服务器查端口"的管理层：加/删隧道、看两端连接状态、清日志、启停服务，都在一个原生 UI 里点一点完成。

<!-- 建议在这里放一张截图 -->

## 架构

```
你的电脑 (Mac)                          公网服务器
┌─────────────────────┐                ┌──────────────────┐
│  frp 隧道面板.app    │  HTTP (本机)    │                  │
│  (菜单栏 SwiftUI)     │ ───────────▶   │                  │
│         │            │  127.0.0.1:8000│                  │
│         ▼            │                │                  │
│  server/ (Node.js)    │                │                  │
│    - 读写 frpc.toml   │  launchctl     │                  │
│    - 控制本地 frpc     │ ───────────▶   │                  │
│    - SSH 控制远程 frps │  SSH           │                  │
│                      │ ───────────▶   │  frps (systemd)   │
└─────────────────────┘                └──────────────────┘
         │                                       │
         └──────────── frp tunnel ───────────────┘
```

- **`app/`** —— 菜单栏 SwiftUI app，纯前端，所有实际逻辑都是调本机 `server/` 的 HTTP API
- **`server/`** —— 本机跑的 Node.js/Express 服务，只监听 `127.0.0.1:8000`（不经 frp 暴露到公网），负责：
  - 读写 `~/frp/frpc.toml`，加/删隧道配置
  - 用 `launchctl` 启停本地 `frpc`
  - 用 SSH（只读命令）探测远程端口占用、查询/控制远程 `frps`（`systemctl`）
- 两端连接状态靠真实信号判断（本地查 TCP ESTABLISHED 连接、远程查 `systemctl is-active`），不依赖日志文字解析

## 前置要求

- macOS 26+（用到了 [Liquid Glass](https://developer.apple.com/design/human-interface-guidelines/materials) API：`glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass)`）
- Xcode Command Line Tools（`xcode-select --install`），不需要装完整 Xcode——这个项目是纯 Swift Package，没有 `.xcodeproj`
- Node.js ≥ 18
- 一台有公网 IP、能 SSH 登录的服务器，装好 [frp](https://github.com/fatedier/frp) 的 `frps` 并跑成 systemd 服务
- 本机装好 `frp` 的 `frpc` 二进制（[releases 页面](https://github.com/fatedier/frp/releases) 下载对应平台的包）
- 一把专门给这个工具用的 SSH 密钥，对远程服务器免密登录（这个工具只会用它跑只读命令探测端口/服务状态，但请按最小权限原则单独生成一把，不要复用你日常登录用的密钥）

## 配置

### 1. 远程服务器：frps

参考 frp 官方文档跑起来 `frps`，记下：
- 公网 IP（下面记为 `<SERVER_IP>`）
- 控制端口（默认 `7000`）
- 你设置的 `auth.token`

### 2. 本机：frpc

```bash
mkdir -p ~/frp
# 把下载好的 frpc 放到 ~/frp/frpc
```

写 `~/frp/frpc.toml`：

```toml
serverAddr = "<SERVER_IP>"
serverPort = 7000

[auth]
method = "token"
token = "<YOUR_TOKEN>"

# 隧道条目由面板自动读写，这里留空即可，也可以手动先加几条
```

用 `launchd/com.user.frpc.plist.template` 做模板，把里面的 `YOUR_USERNAME` 换成你自己的用户名，另存为 `~/Library/LaunchAgents/com.user.frpc.plist`，然后：

```bash
launchctl load ~/Library/LaunchAgents/com.user.frpc.plist
```

### 3. 本机：后端服务

```bash
cd server
npm install
```

环境变量（可选，不设就用默认值）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FRP_SSH_KEY` | `~/.ssh/id_ed25519_frp_server` | 连远程服务器用的私钥路径 |
| `FRP_SSH_USER` | `root` | SSH 登录用户名 |

同样用 `launchd/com.user.frp-panel.plist.template` 做模板（替换用户名、`node` 的绝对路径、按需填 SSH 相关环境变量），另存为 `~/Library/LaunchAgents/com.user.frp-panel.plist`：

```bash
launchctl load ~/Library/LaunchAgents/com.user.frp-panel.plist
```

不想常驻、先跑起来看看效果的话，也可以直接：

```bash
cd server && node server.js
```

### 4. 本机：菜单栏 app

```bash
cd app
./build.sh
```

脚本会编译、生成图标、拼装 `.app`、装到 `/Applications/frp 隧道面板.app`，并做本地 ad-hoc 签名（仅供本机运行，没有走 Apple 公证，首次打开如果被 Gatekeeper 拦，右键"打开"绕过一次即可）。

想开机自启，在系统设置 → 通用 → 登录项 里把这个 app 加进去，或者：

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/frp 隧道面板.app", hidden:false}'
```

## 使用

- 点菜单栏图标唤出/收起面板，右键有"打开面板 / 退出"
- 图标颜色反映隧道健康状态（本地/远程任一异常会变红），15 秒轮询一次，面板打开时额外加密到 5 秒
- 「新增隧道」会对本地和远程端口分别做实时校验（本机 `lsof`、远程 SSH 查 `ss`），端口冲突或格式不对会直接标红，全部通过才能点添加
- 名称不可重复，本地/远程端口理论上可以不同（面板允许分别设置），但同一批服务建议统一用同一个数字，减少心智负担
- 日志区可以一键清空，启停/重载本地 frpc 时也会自动清空（远程日志走 `journalctl`，清空是按时间戳过滤，不是真删）

## 端口分配建议

这个工具本身不强制端口范围，但比较推荐：给"本机要通过隧道对外的服务"划一个专用区间（比如 `8001–8999`），跟系统级服务（SSH:22、frp 控制端口:7000、面板自身:8000）分开，新服务按顺序往后分配，本地端口 = 远程端口 = 容器/进程内部监听端口，三者保持一致，减少排查心智负担。

## 安全说明

- 面板后端只监听 `127.0.0.1:8000`（严格来说是 `0.0.0.0:8000`，方便局域网内其他设备访问面板，但这个端口本身**没有**通过 frp 隧道暴露到公网），不要把这个端口加进你自己的隧道配置里
- SSH 私钥只用来跑只读命令（`ss` 查端口、`systemctl is-active/show` 查状态），远程操作（启停 `frps`）走的是 `systemctl start/stop/restart`，同样是 SSH 执行固定命令，不接受用户输入拼接进 shell 命令
- 生产环境建议单独生成一把仅用于这个工具的 SSH 密钥，不要复用日常登录密钥；如果不放心 `root` 登录，可以给这把密钥单独配置一个权限受限的系统用户，通过 `FRP_SSH_USER` 指定

## 已知限制

- 只支持 macOS（菜单栏部分用了 AppKit + SwiftUI，远程端管理假设是 systemd）
- 远程日志"清空"是时间戳过滤，不是真的删除 `journalctl` 记录
- 没有做多用户/多服务器管理，一个面板实例对应 `~/frp/frpc.toml` 里配置的一个远程服务器

## License

MIT
