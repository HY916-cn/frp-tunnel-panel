const express = require('express');
const TOML = require('@iarna/toml');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const os = require('os');

const HOME = os.homedir();
const FRPC_TOML = path.join(HOME, 'frp', 'frpc.toml');
const FRPC_LOG = path.join(HOME, 'frp', 'frpc.log');
const PLIST = path.join(HOME, 'Library', 'LaunchAgents', 'com.user.frpc.plist');

// 远程服务器（frps 所在机器）SSH 访问参数，仅用于只读端口占用检测。
// 换成你自己的环境时，通过环境变量覆盖，不要直接改这两行——见 README「配置」一节。
const REMOTE_SSH_KEY = process.env.FRP_SSH_KEY || path.join(HOME, '.ssh', 'id_ed25519_frp_server');
const REMOTE_USER = process.env.FRP_SSH_USER || 'root';
const SSH_TIMEOUT_MS = 8000;

// 端口合法范围。<1024 需要 root 权限才能监听，frpc/frps 都以普通用户身份运行，实际用不了，直接拒绝。
const MIN_PORT = 1024;
const MAX_PORT = 65535;

// 本机管理工具自身占用的端口，即便当前空闲也不允许被新 proxy 复用，避免以后自相冲突
const RESERVED_LOCAL_PORTS = new Set([8000, 7000, 22]);

// 纯 API 服务，只给 "frp 隧道面板.app" 使用（网页界面已移除）
const app = express();
app.use(express.json());

function readConfig() {
  const raw = fs.readFileSync(FRPC_TOML, 'utf8');
  return TOML.parse(raw);
}

function writeConfig(cfg) {
  fs.writeFileSync(FRPC_TOML, TOML.stringify(cfg));
}

function getRemoteHost() {
  return readConfig().serverAddr;
}

function runLaunchctl(args) {
  return new Promise((resolve) => {
    execFile('launchctl', args, (error, stdout, stderr) => {
      resolve({ ok: !error, stdout, stderr, error: error && error.message });
    });
  });
}

async function reloadFrpc() {
  await runLaunchctl(['unload', PLIST]);
  return runLaunchctl(['load', PLIST]);
}

// 本地命令探测都应该是毫秒级的（launchctl/lsof 都是纯本机查询），但不设超时的话，
// 一旦系统卡顿或命令挂起，/api/status 会跟着无限期挂起，而这个接口还被 15 秒
// 健康轮询和面板 5 秒自动刷新反复调用——加个宽松超时兜底，超时按"探测失败"处理。
const LOCAL_PROBE_TIMEOUT_MS = 4000;

// 用 launchctl list <label> 而不是 pgrep -f 匹配进程：pgrep 按命令行文本模糊匹配，
// 机器上如果同时有别的进程命令行恰好包含 "frp/frpc -c"（比如手动调试时开了第二个实例、
// 或者路径里出现同名子串），就会抓到错的 PID。launchctl 是 launchd 自己记录的、
// 这个 label 唯一对应的权威 PID，没有歧义。
function getFrpcPid() {
  return new Promise((resolve) => {
    execFile(
      'launchctl',
      ['list', 'com.user.frpc'],
      { timeout: LOCAL_PROBE_TIMEOUT_MS },
      (error, stdout) => {
        if (error) return resolve(null); // job 未加载，或超时
        const match = stdout.match(/"PID"\s*=\s*(\d+);/);
        resolve(match ? match[1] : null); // job 已加载但当前没有运行中的进程，也算 null
      }
    );
  });
}

function isFrpcLoaded() {
  return new Promise((resolve) => {
    execFile(
      'launchctl',
      ['list'],
      { timeout: LOCAL_PROBE_TIMEOUT_MS },
      (error, stdout) => {
        resolve(!error && stdout.includes('com.user.frpc'));
      }
    );
  });
}

// "是否已连上 frps" 曾经靠在日志尾部找 "login to server success" 这行字判断，
// 但清空日志会把这行字冲掉，导致隧道明明健康却显示未连接——日志内容和连接状态
// 是两回事，不该耦合。改成直接查 frpc 进程有没有一条到 serverAddr:serverPort
// 的 ESTABLISHED TCP 连接，这是操作系统给出的真实状态，不受日志清空影响。
function isFrpcConnected(serverAddr, serverPort) {
  return getFrpcPid().then((pid) => {
    if (!pid) return false;
    return new Promise((resolve) => {
      execFile(
        'lsof',
        ['-nP', '-p', pid, '-iTCP', '-a'],
        { timeout: LOCAL_PROBE_TIMEOUT_MS },
        (lsofErr, stdout) => {
          if (lsofErr && !stdout) return resolve(false);
          const target = new RegExp(`->.*${serverAddr.replace(/\./g, '\\.')}:${serverPort}\\s+\\(ESTABLISHED\\)`);
          resolve(target.test(stdout));
        }
      );
    });
  });
}

// 远程日志来自 journalctl，没法像文件那样截断（vacuum 是全系统级的，会误伤别的服务）。
// 所以"清空"记录一个时间戳，之后只查询该时刻之后的条目。存文件里，后端重启也不丢。
const STATE_FILE = path.join(__dirname, 'state.json');

function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function writeState(patch) {
  const next = { ...readState(), ...patch };
  fs.writeFileSync(STATE_FILE, JSON.stringify(next, null, 2));
  return next;
}

// frpc 的日志由 launchd 以 O_APPEND 打开，截断后新日志会从头写起，不需要重启进程
function clearLocalLog() {
  try {
    fs.truncateSync(FRPC_LOG, 0);
    return { ok: true };
  } catch (err) {
    if (err.code === 'ENOENT') return { ok: true };
    return { ok: false, error: err.message };
  }
}

function tailLog(lines = 30) {
  if (!fs.existsSync(FRPC_LOG)) return [];
  const content = fs.readFileSync(FRPC_LOG, 'utf8');
  const stripped = content.replace(/\x1b\[[0-9;]*m/g, '');
  return stripped.trim().split('\n').slice(-lines);
}

// 端口格式/范围合法性检查，不涉及网络调用
function validatePortNumber(port) {
  const n = Number(port);
  if (!Number.isInteger(n)) return { valid: false, reason: '端口必须是整数' };
  if (n < MIN_PORT || n > MAX_PORT) {
    return { valid: false, reason: `端口必须在 ${MIN_PORT}-${MAX_PORT} 之间（<1024 是系统保留端口，普通用户进程无法监听）` };
  }
  return { valid: true };
}

// 本机端口占用检测：用 lsof 查询，避免误判（lsof 找不到即视为空闲）
function checkLocalPort(port) {
  return new Promise((resolve) => {
    execFile(
      'lsof',
      ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN'],
      { timeout: LOCAL_PROBE_TIMEOUT_MS },
      (error, stdout) => {
        if (error || !stdout.trim()) {
          return resolve({ occupied: false });
        }
        const lines = stdout.trim().split('\n');
        const dataLine = lines[1] || lines[0];
        const cols = dataLine.trim().split(/\s+/);
        resolve({ occupied: true, occupiedBy: cols[0] || '未知进程' });
      }
    );
  });
}

// 远程端口占用检测：SSH 到 frps 所在服务器执行只读的 ss 命令。
// 端口号在调用前已经过 validatePortNumber 校验为纯整数，这里用 execFile 参数数组传递，
// 不做字符串拼接，避免命令注入。
function checkRemotePort(port) {
  return new Promise((resolve) => {
    const host = getRemoteHost();
    const remoteCmd = `ss -tlnp 2>/dev/null | grep -E ":${port}\\s" || true`;
    execFile(
      'ssh',
      [
        '-i', REMOTE_SSH_KEY,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=6',
        '-o', 'StrictHostKeyChecking=accept-new',
        `${REMOTE_USER}@${host}`,
        remoteCmd,
      ],
      { timeout: SSH_TIMEOUT_MS },
      (error, stdout) => {
        if (error && !stdout) {
          return resolve({ occupied: false, checkFailed: true, reason: error.message });
        }
        const out = (stdout || '').trim();
        if (!out) return resolve({ occupied: false });
        const match = out.match(/users:\(\("([^"]+)"/);
        resolve({ occupied: true, occupiedBy: (match && match[1]) || '未知进程' });
      }
    );
  });
}

async function fullPortCheck(side, port) {
  const fmt = validatePortNumber(port);
  if (!fmt.valid) return { valid: false, occupied: null, reason: fmt.reason };
  const portNum = Number(port);
  if (side === 'local' && RESERVED_LOCAL_PORTS.has(portNum)) {
    return { valid: false, occupied: true, reason: '这个端口被本机管理工具自身占用（面板/frp 控制端口/SSH），不能复用' };
  }
  const cfg = readConfig();
  const collide = (cfg.proxies || []).find(
    (p) => (side === 'local' ? p.localPort : p.remotePort) === portNum
  );
  if (collide) {
    return { valid: false, occupied: true, reason: `已被现有隧道 "${collide.name}" 占用` };
  }
  const result = side === 'local' ? await checkLocalPort(portNum) : await checkRemotePort(portNum);
  if (result.checkFailed) {
    return { valid: true, occupied: null, reason: `无法连接远程服务器确认占用情况：${result.reason}` };
  }
  if (result.occupied) {
    return { valid: false, occupied: true, reason: `已被占用（进程：${result.occupiedBy}）` };
  }
  return { valid: true, occupied: false };
}

app.get('/api/check-port', async (req, res) => {
  const { side, port } = req.query;
  if (side !== 'local' && side !== 'remote') {
    return res.status(400).json({ error: 'side 必须是 local 或 remote' });
  }
  try {
    const result = await fullPortCheck(side, port);
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/status', async (req, res) => {
  try {
    const cfg = readConfig();
    const [loaded, connected] = await Promise.all([
      isFrpcLoaded(),
      isFrpcConnected(cfg.serverAddr, cfg.serverPort),
    ]);
    const log = tailLog(40);
    res.json({
      serverAddr: cfg.serverAddr,
      serverPort: cfg.serverPort,
      loaded,
      connected,
      proxies: (cfg.proxies || []).map((p) => ({
        name: p.name,
        type: p.type,
        localPort: p.localPort,
        remotePort: p.remotePort,
      })),
      log,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/proxies', async (req, res) => {
  try {
    const { name, localPort, remotePort } = req.body;
    if (!name || !/^[a-z0-9-]+$/.test(name)) {
      return res.status(400).json({ error: '名称只能包含小写字母、数字、连字符' });
    }

    const cfg = readConfig();
    cfg.proxies = cfg.proxies || [];
    if (cfg.proxies.some((p) => p.name === name)) {
      return res.status(400).json({ error: '这个名称已经存在' });
    }

    // 服务端权威校验：不信任前端的实时检查结果，提交时重新查一遍两端
    const [localCheck, remoteCheck] = await Promise.all([
      fullPortCheck('local', localPort),
      fullPortCheck('remote', remotePort),
    ]);
    if (!localCheck.valid) {
      return res.status(400).json({ error: `本地端口 ${localPort} 不可用：${localCheck.reason}` });
    }
    if (!remoteCheck.valid) {
      return res.status(400).json({ error: `远程端口 ${remotePort} 不可用：${remoteCheck.reason}` });
    }

    cfg.proxies.push({
      name,
      type: 'tcp',
      localIP: '127.0.0.1',
      localPort: Number(localPort),
      remotePort: Number(remotePort),
    });
    writeConfig(cfg);
    const reload = await reloadFrpc();
    res.json({
      ok: true,
      reload,
      warnings: [localCheck.reason, remoteCheck.reason].filter((r) => r && !r.includes('不可用')),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.delete('/api/proxies/:name', async (req, res) => {
  try {
    const cfg = readConfig();
    const before = (cfg.proxies || []).length;
    cfg.proxies = (cfg.proxies || []).filter((p) => p.name !== req.params.name);
    if (cfg.proxies.length === before) {
      return res.status(404).json({ error: '没找到这个 proxy' });
    }
    writeConfig(cfg);
    const reload = await reloadFrpc();
    res.json({ ok: true, reload });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 启停/重载时自动清空日志：这些操作是一次生命周期的分界，旧日志留着只会干扰排查。
// 截断都放在进程停下之后、拉起之前，避免和正在写入的 frpc 抢文件位置。

app.post('/api/reload', async (req, res) => {
  await runLaunchctl(['unload', PLIST]);
  clearLocalLog();
  const result = await runLaunchctl(['load', PLIST]);
  res.json(result);
});

app.post('/api/start', async (req, res) => {
  clearLocalLog();
  const result = await runLaunchctl(['load', PLIST]);
  res.json(result);
});

app.post('/api/stop', async (req, res) => {
  const result = await runLaunchctl(['unload', PLIST]);
  clearLocalLog();
  res.json(result);
});

app.post('/api/logs/clear', async (req, res) => {
  const side = req.query.side;
  if (side === 'local') {
    const result = clearLocalLog();
    return result.ok ? res.json({ ok: true }) : res.status(500).json({ error: result.error });
  }
  if (side === 'remote') {
    // 用远端自己的时钟取时间戳，避免两台机器时区/时差不一致导致过滤错位
    const now = await runRemote("date '+%Y-%m-%d %H:%M:%S'");
    if (!now.stdout) {
      return res.status(500).json({ error: `无法获取远端时间：${now.error || '未知错误'}` });
    }
    writeState({ remoteLogClearedAt: now.stdout.trim() });
    return res.json({ ok: true });
  }
  res.status(400).json({ error: 'side 必须是 local 或 remote' });
});

// ── 远程 frps 管理 ──────────────────────────────────────────────────────────
// 远端是 Ubuntu + systemd，frps 以 frps.service 常驻。这里通过 SSH 执行 systemctl。
// 所有命令都是固定字符串，不接受外部输入拼接。

function runRemote(command, { timeout = SSH_TIMEOUT_MS } = {}) {
  return new Promise((resolve) => {
    const host = getRemoteHost();
    execFile(
      'ssh',
      [
        '-i', REMOTE_SSH_KEY,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=6',
        '-o', 'StrictHostKeyChecking=accept-new',
        `${REMOTE_USER}@${host}`,
        command,
      ],
      { timeout },
      (error, stdout, stderr) => {
        resolve({
          ok: !error,
          stdout: (stdout || '').trim(),
          stderr: (stderr || '').trim(),
          error: error && error.message,
        });
      }
    );
  });
}

app.get('/api/remote/status', async (req, res) => {
  try {
    const host = getRemoteHost();
    // systemctl is-active 在服务未运行时返回非 0 退出码，属于正常结果而不是错误，
    // 所以这里只看 stdout 内容，不看 ok。
    // 清空过日志的话，只取标记时刻之后的条目。时间戳由远端 date 生成，格式固定，
    // 且只可能由本服务写入，不存在注入风险。
    const clearedAt = readState().remoteLogClearedAt;
    const sinceArg = clearedAt ? `--since "${clearedAt}"` : '';

    const [active, uptime, log] = await Promise.all([
      runRemote('systemctl is-active frps 2>/dev/null || true'),
      runRemote(
        "systemctl show frps --property=ActiveEnterTimestamp --value 2>/dev/null || true"
      ),
      runRemote(`journalctl -u frps -n 30 --no-pager ${sinceArg} 2>/dev/null || true`),
    ]);

    if (active.error && !active.stdout) {
      return res.json({
        reachable: false,
        host,
        reason: `SSH 连接失败：${active.error}`,
      });
    }

    res.json({
      reachable: true,
      host,
      active: active.stdout === 'active',
      rawState: active.stdout || 'unknown',
      since: uptime.stdout || null,
      log: log.stdout ? log.stdout.split('\n') : [],
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const REMOTE_ACTIONS = {
  start: 'systemctl start frps',
  stop: 'systemctl stop frps',
  restart: 'systemctl restart frps',
};

app.post('/api/remote/:action', async (req, res) => {
  const cmd = REMOTE_ACTIONS[req.params.action];
  if (!cmd) {
    return res.status(400).json({ error: '只支持 start / stop / restart' });
  }
  const result = await runRemote(cmd, { timeout: 15000 });
  res.json(result);
});

const LISTEN_PORT = 8000;
// 绑定 0.0.0.0：局域网内其他设备也能打开面板，但没有接入 frp 隧道，不会暴露到公网。
app.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`frp 管理面板已启动: http://0.0.0.0:${LISTEN_PORT}（局域网内可访问，未通过 frp 暴露到公网）`);
});
