#!/usr/bin/env node
//
// gateway-bridge.js — fnOS 统一网关 ↔ MoviePilot 前端 反向代理桥
//
// 设计动机：
//   fnOS 统一网关把 /app/moviepilot/** 整路径（不剥前缀）转发到 gatewaySocket
//   声明的 Unix Socket。但 MoviePilot 前端 service.js（上游 public/service.js）
//   只监听 TCP:3000，且所有路由（express.static、/api、/cookiecloud、SPA
//   fallback）都假设根路径，没有剥前缀能力，也没有 listen Unix Socket 的分支。
//   不改上游任何文件的前提下，本桥在两者之间充当翻译：
//     1. 监听 fnOS 要求的 Unix Socket（${LISTEN_SOCKET}）；
//     2. 收到请求时剥掉 GATEWAY_PREFIX（默认 /app/moviepilot）；
//     3. 把剥前缀后的 HTTP / WebSocket 请求转发到前端 127.0.0.1:${UP_PORT}。
//
// 上游在线更新（moviepilot update）只重写 ${MP_ROOT}/public/，本桥位于
// ${TRIM_APPDEST}/bin/（fnOS 包自己的 target 目录），更新不会触碰它。
//
// 零第三方依赖：仅用 node 内置 http / net / fs，复用 install_callback 下载的自带 Node 运行时。
// 由 src/cmd/main 以 moviepilot 用户身份启动，PID 写入 ${TRIM_PKGVAR}/gateway-bridge.pid。
//
'use strict';

const http = require('node:http');
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');

// ---------- 配置（环境变量由 cmd/main 注入）----------
const PREFIX = (process.env.GATEWAY_PREFIX || '/app/moviepilot').trim();
const SOCK = process.env.LISTEN_SOCKET;                       // 形如 ${TRIM_APPDEST}/app.sock
const UP_HOST = process.env.UPSTREAM_HOST || '127.0.0.1';
const UP_PORT = Number(process.env.UPSTREAM_PORT || 3000);     // 前端 service.js 端口
// 前端就绪探测：启动后等前端 :3000 出现再 listen socket，避免网关先连上却 502
const READY_TIMEOUT_MS = Number(process.env.READY_TIMEOUT_MS || 120000);
const READY_INTERVAL_MS = Number(process.env.READY_INTERVAL_MS || 2000);

// ---------- 网桥免登录配置 ----------
// 后端登录接口（OAuth2PasswordRequestForm：username/password/otp_password，表单编码）。
// 成功返回 { access_token, token_type, super_user, user_id, ... }。
// 失败（密码错/需 MFA）返回 401；桥记录后跳过免登录，前端正常走登录页。
const LOGIN_PATH = process.env.BRIDGE_LOGIN_API || '/api/v1/login/access-token';
// 凭据来源优先级：显式注入的 env > app.env 自动读取 > 无（关闭免登录）。
// cmd/main 注入 BRIDGE_LOGIN_USER/PASS（取自 app.env 的 SUPERUSER/SUPERUSER_PASSWORD，
// 可被 config_callback 改绑覆盖）。留空 → 关闭免登录，前端走正常登录。
const LOGIN_USER = (process.env.BRIDGE_LOGIN_USER || '').trim();
const LOGIN_PASS = process.env.BRIDGE_LOGIN_PASS || '';
// 登录态刷新周期（重新调登录接口，刷新 level/wizard 等可变状态）。
// ★ 关键：登录响应里的 level（站点认证等级）、wizard（是否显示向导）是后端可变状态，
//   会随用户操作变化（做完向导 wizard→false，站点认证后 level→2）。如果长期缓存首次
//   登录的响应，会注入过期的 level/wizard → 前端用旧值判定，出现"用户认证"弹窗等错乱。
//   所以登录态必须定期刷新。bcrypt 一次约 100ms，5 分钟一次完全可接受。
const LOGIN_REFRESH_MS = Number(process.env.BRIDGE_LOGIN_REFRESH_MS || 5 * 60 * 1000);
// JWT 缓存有效期（MoviePilot 默认 ACCESS_TOKEN_EXPIRE_MINUTES=11520 即 8 天）。
// 提前 30 分钟过期，避免边界。此值仅用于估算（实际以 JWT exp 为准，见 mintLogin 解码校验）。
const TOKEN_REFRESH_MS = Number(process.env.BRIDGE_TOKEN_REFRESH_MS || (8 * 24 * 60 * 60 * 1000 - 30 * 60 * 1000));

// ---------- 日志（与 cmd/main 的 info.log 同风格）----------
const LOG = process.env.BRIDGE_LOG || '/dev/stderr';
function ts() { return new Date().toISOString().replace('T', ' ').slice(0, 19); }
function log(msg) {
  const line = `${ts()} - [bridge] ${msg}\n`;
  try { fs.appendFileSync(LOG, line); } catch (_) { process.stderr.write(line); }
}

// ============================================================================
// 网桥免登录：用 SUPERUSER 凭据向后端换 JWT，缓存复用，注入到前端 SPA。
//
// 为什么这样实现（而非离线伪造 JWT / 注 X-API-KEY）：
//   MoviePilot 的 SECRET_KEY 每次启动随机生成（secrets.token_urlsafe(32)），不写
//   app.env，桥无法离线签发 JWT。X-API-KEY 虽能过后端鉴权，但前端 SPA 路由守卫
//   只认 localStorage 里 pinia persist 的 JWT（router/index.ts: if (!authStore.token)
//   return '/login'），X-API-KEY 到不了 localStorage，页面仍跳登录。
//   唯一可靠路径：用真凭据走真正的登录接口换真 JWT，再由浏览器侧 JS 写进 pinia store。
//
// 流程：桥读 app.env 的 SUPERUSER/SUPERUSER_PASSWORD → POST /api/v1/login/access-token
//   （表单编码，OAuth2PasswordRequestForm）→ 拿 access_token（HS256 JWT）→ 缓存。
//   注入：拦截 text/html 的 SPA 入口响应（index.html），在 <head> 顶部插一段
//   inline <script>，浏览器执行后把 JWT 写进 localStorage 的 pinia auth store。
//   仅 socket 入口（fnOS 网关路径）注入；TCP 入口（局域网直连）不注入，需手动登录。
// ============================================================================

// 登录响应缓存（进程内存）。失效条件：① 到期 ② 凭据变更。
// 缓存整个登录响应（access_token + 用户信息），注入时同时写 auth + user 两个 store。
//   为什么不只存 token：前端 SPA 的路由/权限/菜单全靠 user store（superUser/userID/
//   permissions 等），而这些字段在登录响应里，不在 JWT payload 的前端可读层。
//   前端没有"启动时按 token 自动拉 user/current"的自愈机制，必须由桥把 user 信息
//   一起注入 localStorage，否则 SPA 认为是匿名普通用户（user store 全是默认值）。
let cachedLogin = null;        // { authState, userState, exp }，exp 是 ms 时间戳
let loginInflight = null;      // 正在进行中的登录 Promise（避免并发重复登录）

// 首次登录重试配置。
// 问题场景：前端 :3000 已 listen（service.js 过了后端 health check），但后端数据库/
// ORM/插件仍在初始化，此时调登录接口会 500/401。如果首次 HTML 请求时一次登录失败就
// 放弃 → HTML 无注入 → 用户看到登录页（得关了重开才好）。重试覆盖这个就绪窗口。
const LOGIN_RETRY_MAX = Number(process.env.BRIDGE_LOGIN_RETRY_MAX || 5);   // 最多重试次数
const LOGIN_RETRY_INTERVAL_MS = Number(process.env.BRIDGE_LOGIN_RETRY_INTERVAL_MS || 2000); // 每次间隔

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// 单次登录尝试。成功返回 { authState, userState }，失败返回 null（不重试，由调用方决定）。
async function _loginOnce() {
  const body = new URLSearchParams({
    username: LOGIN_USER,
    password: LOGIN_PASS,
  }).toString();
  // 登录接口在后端 :3001，经前端 service.js :3000 代理为 /api/v1/login/access-token。
  // 走 UP_HOST:UP_PORT（即前端 :3000）与其它请求同路径，无需另开后端端口。
  const resp = await fetchPlain(UP_HOST, UP_PORT, 'POST', LOGIN_PATH, body);
  if (resp.statusCode !== 200) {
    const detail = safeJsonDetail(resp.body);
    log(`免登录尝试失败：${resp.statusCode} ${detail}（user=${LOGIN_USER}）`);
    return null;
  }
  const data = safeParseJson(resp.body);
  if (!data || !data.access_token) {
    log(`免登录尝试失败：响应缺少 access_token（${resp.body.slice(0, 120)}）`);
    return null;
  }
  // 构造两个 pinia store 的 state（字段名对齐前端 stores/auth.ts + stores/user.ts）
  const authState = {
    token: data.access_token,
    remember: false,
    originalPath: null,
  };
  // user state: 字段名 camelCase（后端响应是 snake_case，需转换）
  const userState = {
    superUser: !!data.super_user,
    userID: data.user_id,
    userName: data.user_name || '',
    avatar: data.avatar || '',
    level: data.level || 1,
    permissions: data.permissions || {},
    wizard: !!data.wizard,
  };
  cachedLogin = { authState, userState, exp: Date.now() + LOGIN_REFRESH_MS };
  log(`免登录成功：登录态已缓存（user=${LOGIN_USER}, superUser=${userState.superUser}, userID=${userState.userID}, level=${userState.level}, wizard=${userState.wizard}，${Math.round(LOGIN_REFRESH_MS / 60000)}min 后刷新）`);
  return { authState, userState };
}

// 用 SUPERUSER 凭据向后端换登录态。返回 { authState, userState } 或 null。
//   authState  = 写 pinia 'auth' store（token）
//   userState  = 写 pinia 'user' store（superUser/userID/...）
// 并发去重：同一时刻只有一个登录链在飞，其余等待复用结果。
// 重试：首次（缓存空）时最多重试 LOGIN_RETRY_MAX 次，覆盖后端启动就绪窗口。
async function mintLogin() {
  if (!LOGIN_USER || !LOGIN_PASS) return null;  // 未配置免登录

  // 命中缓存（未到期）直接返回
  if (cachedLogin && Date.now() < cachedLogin.exp) {
    return { authState: cachedLogin.authState, userState: cachedLogin.userState };
  }

  // 已有在飞的登录链 → 复用
  if (loginInflight) return loginInflight;

  loginInflight = (async () => {
    try {
      // 首次登录（无缓存）带重试；缓存过期重签不重试（后端早已就绪，失败大概率是凭据问题）
      const isFirstTime = !cachedLogin;
      const maxAttempts = isFirstTime ? LOGIN_RETRY_MAX : 1;
      for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
        const result = await _loginOnce();
        if (result) return result;
        if (attempt < maxAttempts) {
          log(`免登录重试 ${attempt}/${maxAttempts - 1}（等待 ${LOGIN_RETRY_INTERVAL_MS}ms）...`);
          await sleep(LOGIN_RETRY_INTERVAL_MS);
        }
      }
      log(`免登录失败：${maxAttempts} 次尝试均未成功，本次放弃（下次请求会再试）`);
      return null;
    } catch (err) {
      log(`免登录异常：${err.message}`);
      return null;
    } finally {
      loginInflight = null;
    }
  })();
  return loginInflight;
}

// 收到后端 401 时作废缓存（下次请求会自动重新登录）。
// 当前未启用：桥代理的 API 401 是 SPA 持有的 JWT 过期所致，桥作废缓存无法
// 阻止 SPA 跳登录。保留函数供未来按需启用（如桥直接代理鉴权时）。
// function invalidateToken() { cachedToken = null; }

// 最小同步 HTTP 客户端（不依赖 fetch，Node 18 内置 fetch 是实验性/异步）。
// 返回 { statusCode, headers, body }。失败抛异常。
function fetchPlain(host, port, method, reqPath, body) {
  return new Promise((resolve, reject) => {
    const headers = {
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    if (body) headers['Content-Length'] = Buffer.byteLength(body);
    const up = http.request({ host, port, method, path: reqPath, headers }, (upRes) => {
      let chunks = [];
      upRes.on('data', (c) => chunks.push(c));
      upRes.on('end', () => {
        resolve({
          statusCode: upRes.statusCode || 502,
          headers: upRes.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        });
      });
    });
    up.on('error', reject);
    up.setTimeout(10000, () => up.destroy(new Error('login timeout')));
    if (body) up.write(body);
    up.end();
  });
}

function safeParseJson(s) {
  try { return JSON.parse(s); } catch (_) { return null; }
}
function safeJsonDetail(s) {
  const j = safeParseJson(s);
  return j && j.detail ? String(j.detail) : s.slice(0, 120);
}

// ---------- HTML 拦截：把 JWT 注入 SPA index.html ----------
// 检测响应是否是 SPA HTML 入口（text/html + 请求路径是 / 或 /index.html 或 /xxx.html）。
// 命中则在 <head> 后注入 inline <script>，由浏览器把 JWT 写进 pinia auth store。
function shouldInjectHtml(reqPath, contentType) {
  if (!contentType) return false;
  if (!/text\/html/i.test(contentType)) return false;
  // 只对 HTML 入口注入（/、/index.html、/vite.svg 等 .html）。API/JS/CSS 不动。
  // reqPath 已剥前缀。
  if (reqPath === '/' || reqPath === '/index.html') return true;
  if (reqPath.endsWith('.html')) return true;
  return false;
}

// 构造注入的 inline <script> 字符串。
// 逻辑：
//   ① 如果 localStorage 已有 pinia auth store 且含 token → 不覆盖（保留用户手动登录态）。
//   ② 否则把桥下发的登录态写进 auth + user 两个 pinia store：
//      - 'auth' store（stores/auth.ts）：{ token, remember, originalPath }
//      - 'user' store（stores/user.ts）：{ superUser, userID, userName, avatar, level, permissions, wizard }
//      缺任一都会导致前端身份异常（只有 token 没 user → 前端判定匿名普通用户，无法进 dashboard）。
//   ③ 登录态经 data-attribute 传入（JSON 序列化），避免在 JS 字面量里拼接（防 XSS 转义坑）。
//   meta 节点在脚本执行后立即移除，减少凭据在 DOM 中的残留窗口。
function buildInjectScript(authState, userState) {
  // 整个 payload 序列化到 data-attr（含 auth + user 两个 store 的 state）
  const payload = JSON.stringify({ a: authState, u: userState });
  const meta = `<meta name="mp-bridge-autologin" data-payload="${escapeAttr(payload)}">`;
  const script = `<script>(function(){
    try {
      var AUTH_KEY='auth', USER_KEY='user';
      // 已有合法 auth token → 不覆盖（用户手动登录过 / 切了账号）
      var rawAuth=localStorage.getItem(AUTH_KEY);
      if(rawAuth){var sa=JSON.parse(rawAuth);if(sa&&sa.token){return;}}
      var m=document.querySelector('meta[name="mp-bridge-autologin"]');
      if(!m)return;var pl=m.getAttribute('data-payload');
      if(!pl)return;
      var p=JSON.parse(pl);
      // pinia-plugin-persistedstate v4 默认存整个 state 的 JSON（key = store $id）
      // 在 app.use(pinia) + mount 之前写入，plugin 初始化时读到的就是含登录态的 state
      localStorage.setItem(AUTH_KEY, JSON.stringify(p.a));
      localStorage.setItem(USER_KEY, JSON.stringify(p.u));
      // 清理痕迹：移除 meta（凭据不再残留在 DOM）
      m.parentNode.removeChild(m);
    }catch(e){/* 静默失败，不影响页面 */}
  })();</script>`;
  return meta + script;
}

function escapeAttr(s) {
  return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// 把 inject 字符串插入 HTML 的 <head> 之后（确保在应用脚本之前执行）。
// 策略：匹配 <head...>（容错大小写/属性/空格），未命中则插到文档最前。
function injectHtml(buf, inject) {
  const html = buf.toString('utf8');
  // 匹配 <head> 或 <head ...>，i 忽略大小写
  const m = /<head[^>]*>/i.exec(html);
  if (m) {
    const idx = m.index + m[0].length;
    return Buffer.from(html.slice(0, idx) + inject + html.slice(idx), 'utf8');
  }
  // 无 <head>（异常 HTML），插到最前面
  return Buffer.from(inject + html, 'utf8');
}

// ---------- 剥网关前缀 ----------
// 先按 '?' 分出 path 与 query，只对 path 判定前缀，query 原样保留：
//   /app/moviepilot          -> /
//   /app/moviepilot?v=1      -> /?v=1
//   /app/moviepilot/api/v1/x -> /api/v1/x
//   /other                   -> /other （网关下理论上不会出现，原样透传）
function rewriteUrl(url) {
  const qi = url.indexOf('?');
  const path = qi === -1 ? url : url.slice(0, qi);
  const query = qi === -1 ? '' : url.slice(qi);
  let rewritten;
  if (path === PREFIX) rewritten = '/';
  else if (path.startsWith(PREFIX + '/')) rewritten = path.slice(PREFIX.length);
  else rewritten = path;
  return rewritten + query;
}

// ---------- HTTP 反向代理 ----------
const server = http.createServer((req, res) => {
  const original = req.url;

  // 精确匹配前缀根路径（无尾斜杠）时，301 重定向到带斜杠形式。
  // 原因：前端 vite base='./'，资源用相对路径 ./assets/x.js。若浏览器停在
  // /app/moviepilot（无斜杠），会把其当作文件、目录是 /app/，相对资源解析成
  // /app/assets/x.js 丢失 moviepilot 段 → 404。重定向到 /app/moviepilot/ 后，
  // 浏览器把目录正确识别为 /app/moviepilot/，./assets/x.js → /app/moviepilot/assets/x.js。
  // query 形如 /app/moviepilot?v=1 也要重定向（保留 query）。
  const qi0 = original.indexOf('?');
  const pathOnly0 = qi0 === -1 ? original : original.slice(0, qi0);
  if (pathOnly0 === PREFIX) {
    const loc = PREFIX + '/' + (qi0 === -1 ? '' : original.slice(qi0));
    res.writeHead(301, { Location: loc, 'Content-Type': 'text/plain' });
    res.end('Redirecting to ' + loc);
    return;
  }

  req.url = rewriteUrl(req.url);

  // 复制 headers，去掉 Node 自动加的、可能冲突的 hop-by-hop / 长度头，让上游重算
  const headers = { ...req.headers };
  delete headers['content-length'];
  delete headers['transfer-encoding'];
  delete headers['connection'];
  delete headers['keep-alive'];

  const up = http.request(
    { host: UP_HOST, port: UP_PORT, method: req.method, path: req.url, headers },
    async (upRes) => {
      const contentType = upRes.headers['content-type'] || '';
      const isHtml = shouldInjectHtml(req.url, contentType);

      // 非 HTML 入口：直接透传（流式，零缓冲，保持原性能）
      if (!isHtml || !LOGIN_USER) {
        res.writeHead(upRes.statusCode || 502, upRes.headers);
        upRes.pipe(res);
        return;
      }

      // HTML 入口 + 配置了免登录：尝试换登录态，有则注入 auth + user store
      // 缓冲整个 body（index.html 通常 < 50KB，可接受）
      const chunks = [];
      upRes.on('data', (c) => chunks.push(c));
      upRes.on('end', async () => {
        let body = Buffer.concat(chunks);
        try {
          const login = await mintLogin();
          if (login) {
            const inject = buildInjectScript(login.authState, login.userState);
            body = injectHtml(body, inject);
            // 重算 content-length（注入后长度变了）
            const newHeaders = { ...upRes.headers, 'content-length': String(body.length) };
            res.writeHead(upRes.statusCode || 200, newHeaders);
            res.end(body);
            return;
          }
        } catch (err) {
          log(`HTML 注入异常：${err.message}（${req.method} ${original}），降级透传`);
        }
        // 无 token 或异常 → 原样透传（不阻塞用户访问）
        res.writeHead(upRes.statusCode || 200, upRes.headers);
        res.end(body);
      });
      upRes.on('error', (err) => {
        log(`upRes 读取错误：${err.message}`);
        if (!res.headersSent) {
          res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end('Bad Gateway');
        }
      });
    }
  );
  up.on('error', (err) => {
    log(`HTTP upstream error: ${err.message} (${req.method} ${original})`);
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Bad Gateway');
    } else {
      res.destroy();
    }
  });
  req.pipe(up);
});

// ---------- WebSocket upgrade 透传 ----------
// WebSocket 握手是裸 HTTP/1.1 Upgrade，不能用 http.request（它会伪装非升级请求）。
// 这里用 net.connect 拿到上游裸 socket，手工写一行带剥前缀 path 的请求行，再把两个
// socket 直接 pipe，实现零内容改动的双向透传。
server.on('upgrade', (req, sock, head) => {
  const upPath = rewriteUrl(req.url);
  const up = net.connect(UP_PORT, UP_HOST, () => {
    const lines = [
      `${req.method} ${upPath} HTTP/${req.httpVersion}`,
    ];
    for (const [k, v] of Object.entries(req.headers)) {
      // 透传全部头（含 Upgrade/Connection/Sec-WebSocket-*），仅剥 Connection 的 keep-alive 语义
      lines.push(`${k}: ${v}`);
    }
    lines.push('', '');
    up.write(lines.join('\r\n'));
    if (head && head.length) up.write(head);
    sock.pipe(up);
    up.pipe(sock);
  });
  const cleanup = () => { sock.destroy(); up.destroy(); };
  up.on('error', (err) => { log(`WS upstream error: ${err.message}`); cleanup(); });
  sock.on('error', () => cleanup());
});

// ---------- 进程信号 ----------
function shutdown(sig) {
  log(`received ${sig}, closing`);
  server.close(() => {
    try { fs.rmSync(SOCK, { force: true }); } catch (_) {}
    process.exit(0);
  });
  // 兜底：3 秒内没关完就硬退
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// ---------- 前端就绪探测 ----------
// 前端 service.js 自身会等后端健康才 listen :3000（见上游 LOCAL_FRONTEND_SERVICE_SCRIPT
// 的 waitForBackendReady）。我们探到 :3000 能建连即认为前端就绪，再 listen socket。
function waitForUpstream(done) {
  const start = Date.now();
  const probe = () => {
    const c = net.connect(UP_PORT, UP_HOST, () => { c.end(); done(true); });
    c.on('error', () => {
      if (Date.now() - start >= READY_TIMEOUT_MS) return done(false);
      setTimeout(probe, READY_INTERVAL_MS);
    });
  };
  probe();
}

// ---------- 运行期 upstream 存活监控 ----------
// 启动时 waitForUpstream 只保证"开始监听那一刻前端在"。运行中前端可能因
// `moviepilot update` / 崩溃而消失，此时桥转发全 502 却不自知。定期探 :3000，
// 连续失败超过阈值则主动退出（退出前 fnOS 的 do_status 会因 socket 消失报未运行，
// 触发 cmd/main start 重新拉起整套服务，实现自愈）。
const WATCH_INTERVAL_MS = Number(process.env.WATCH_INTERVAL_MS || 30000);
const WATCH_MAX_FAILURES = Number(process.env.WATCH_MAX_FAILURES || 6); // ~3 分钟连续失败
function startUpstreamWatchdog() {
  let failures = 0;
  const timer = setInterval(() => {
    const c = net.connect(UP_PORT, UP_HOST, () => { c.end(); failures = 0; });
    c.on('error', () => {
      failures += 1;
      log(`upstream watchdog: ${UP_HOST}:${UP_PORT} unreachable (${failures}/${WATCH_MAX_FAILURES})`);
      if (failures >= WATCH_MAX_FAILURES) {
        log(`upstream unreachable for ${WATCH_MAX_FAILURES} checks, exiting to trigger restart`);
        clearInterval(timer);
        server.close(() => { try { fs.rmSync(SOCK, { force: true }); } catch (_) {} process.exit(1); });
        setTimeout(() => process.exit(1), 3000).unref();
      }
    });
  }, WATCH_INTERVAL_MS);
  timer.unref();
}

// ---------- 启动 ----------
function listen() {
  if (!SOCK) { log('LISTEN_SOCKET 未设置，桥无法监听'); process.exit(1); }
  // 清理残留 socket 文件（上次异常退出可能留下）
  try { fs.rmSync(SOCK, { force: true }); } catch (_) {}
  server.listen(SOCK, () => {
    // 网关以其他用户身份连接，必须放开权限（0666）。目录 ${TRIM_APPDEST} 由 fnOS 管理。
    try { fs.chmodSync(SOCK, 0o666); } catch (_) {}
    log(`listening on ${SOCK} -> ${UP_HOST}:${UP_PORT} (prefix=${PREFIX})`);
    startUpstreamWatchdog();
  });
  server.on('error', (err) => {
    log(`listen error: ${err.message}`);
    process.exit(1);
  });
}

waitForUpstream(async (ok) => {
  if (!ok) { log(`upstream ${UP_HOST}:${UP_PORT} not ready after ${READY_TIMEOUT_MS}ms, exit`); process.exit(1); }
  log(`upstream ${UP_HOST}:${UP_PORT} ready`);

  // 免登录预热（best-effort）：前端 :3000 就绪后、listen 前先尝试登录。
  // 前端就绪 ≠ 后端数据库就绪（service.js 的 health check 只测 /api/v1/system/global
  // 返回 200，不保证登录接口能查数据库）。预热失败不阻塞 listen——首次 HTML 请求时
  // mintLogin 会带重试继续尝试。预热成功则首次请求直接命中缓存，用户无感免登录。
  if (LOGIN_USER && LOGIN_PASS) {
    log(`预热免登录（best-effort）...`);
    const warmed = await mintLogin();
    if (warmed) {
      log(`免登录预热成功，首请求将直接命中缓存`);
    } else {
      log(`免登录预热未就绪（后端初始化中），将在首次请求时重试`);
    }
  }

  listen();
});
