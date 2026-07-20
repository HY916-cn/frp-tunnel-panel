# frp 隧道面板

管理 [frp](https://github.com/fatedier/frp) 隧道的 macOS 菜单栏小工具。把本机跑的服务通过一台有公网 IP 的服务器暴露出去——加/删隧道、看连接状态、清日志、启停服务，都在菜单栏点一点完成，不用每次手动改 `frpc.toml` 或 SSH 上服务器查端口。

---

## 架构

由两部分组成，菜单栏 app 通过本机 HTTP API 调用后端服务：

- **`app/`** —— 菜单栏 SwiftUI 应用，负责界面与交互，所有逻辑都调用本机 `server/` 的 HTTP API。
- **`server/`** —— 本机 Node.js/Express 服务，监听 `127.0.0.1:8000`，负责读写 `frpc.toml`、用 `launchctl` 控制本地 `frpc`、用 SSH 控制远程 `frps`。
- **连接状态用真实信号判断**：本地查 TCP 连接，远程查 `systemctl is-active`，不解析日志文字。

其余目录：

- **`launchd/`** —— 后端服务与 `frpc` 的 launchd plist 模板。
- **`docs/`** —— 架构与说明素材。

---

## 环境要求

- macOS 26+（用了 Liquid Glass：`glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)`）
- Xcode Command Line Tools 即可，不需要完整 Xcode（纯 Swift Package，没有 `.xcodeproj`）
- Node.js ≥ 18
- 一台公网服务器，SSH 可登录，装好 frp 的 `frps` 并跑成 systemd 服务
- 本机的 `frpc` 二进制（从 [releases](https://github.com/fatedier/frp/releases) 下载对应平台）
- 一把单独生成的 SSH 密钥专供此工具连服务器用，不要复用日常登录的密钥

---

## 配置

### 1. 远程服务器跑 frps

按 frp 官方文档配好，记下公网 IP、控制端口（默认 7000）、`auth.token`。

### 2. 本机装 frpc

```bash
mkdir -p ~/frp
# 将 frpc 放到 ~/frp/frpc
```

`~/frp/frpc.toml`：

```toml
serverAddr = "<SERVER_IP>"
serverPort = 7000

[auth]
method = "token"
token = "<YOUR_TOKEN>"
```

把 `launchd/com.user.frpc.plist.template` 里的 `YOUR_USERNAME` 换成自己的用户名，存到 `~/Library/LaunchAgents/com.user.frpc.plist`：

```bash
launchctl load ~/Library/LaunchAgents/com.user.frpc.plist
```

### 3. 后端服务

```bash
cd server
npm install
npm start   # 等同于 node server.js
```

可选环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FRP_SSH_KEY` | `~/.ssh/id_ed25519_frp_server` | 连服务器用的私钥 |
| `FRP_SSH_USER` | `root` | SSH 用户名 |

同样用 `launchd/com.user.frp-panel.plist.template` 改好路径存到 `~/Library/LaunchAgents/com.user.frp-panel.plist`：

```bash
launchctl load ~/Library/LaunchAgents/com.user.frp-panel.plist
```

想先跑起来看看，直接 `cd server && node server.js` 也行。

### 4. 菜单栏 app

```bash
cd app
./build.sh
```

脚本会编译、生成图标、打包成 `.app`、装到 `/Applications`，并做本地 ad-hoc 签名。首次打开时 Gatekeeper 会拦一下，右键「打开」放行一次即可。

开机自启：系统设置 → 通用 → 登录项添加，或执行：

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/frp 隧道面板.app", hidden:false}'
```

---

## 用法

- 点菜单栏图标开/关面板，右键可退出。
- 图标颜色跟随隧道状态变化（异常变红）；15 秒轮询一次，面板打开时 5 秒一次。
- 新增隧道会实时检测端口占用（本机用 `lsof`，远程 SSH 查 `ss`），冲突直接标红。
- 隧道名称不能重复；建议本地端口 = 远程端口，方便对照。
- 日志可清空；启停/重载本地 frpc 时也会自动清一次。

---

## 安全

- 后端只监听本机/局域网，`8000` 端口本身不经过 frp 隧道对外暴露。
- SSH 仅用于只读探测和固定的 `systemctl` 命令，不拼接用户输入。
- 建议单独开一把 SSH 密钥给此工具使用；若不放心 root，可换一个权限受限的用户。

---

## 限制

- 仅支持 macOS，远程端假设为 systemd。
- 远程日志「清空」是按时间戳过滤，并非真正删除 journalctl 记录。
- 一个面板对应 `frpc.toml` 中配置的一台服务器。

---

## License

[MIT](LICENSE) © HY916-cn
