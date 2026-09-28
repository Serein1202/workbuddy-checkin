#!/usr/bin/env node
/**
 * ============================================================
 * tg-config.js —— WorkBuddy 签到 skill 的 Telegram 推送配置助手
 *
 * 目的：让 agent（或用户）无需手工拼接配置文件，即可完成
 *       「状态查询 / 凭据写入 / 测试推送 / 拒绝推送」四件事。
 *       跨平台（Windows / macOS / Linux），仅依赖 Node.js 与系统自带 curl。
 *
 * 子命令：
 *   status  [--json]                                  查看配置状态（三态）
 *   test    [--token T] [--chat C] [--proxy P] [--json]  用现有（或临时指定）凭据发一条测试消息
 *   set     --token T --chat C [--proxy P] [--no-test] [--json]
 *                                                     收集到的凭据先做连通性测试，成功才落盘
 *   decline [--json]                                  持久化「拒绝推送」状态（写 WB_CHECKIN_TELEGRAM=0）
 *
 * 配置状态三态（与 checkin.sh / checkin.ps1 的 telegram_state 判定完全一致）：
 *   unset     未配置：无显式开关、也无凭据 —— 首次使用时需要询问用户
 *   enabled   已启用：显式开关为开，或未设开关但凭据齐全（兼容 1.1.0 起无显式开关的既有配置）
 *   declined  已拒绝：显式开关为 0/false/no/off/declined —— 直接签到，不再重复询问
 *
 * 取值优先级：环境变量 > <skill 根目录>/.env.local（逐行解析，只认白名单键，不执行任何代码）。
 * 安全约束：
 *   - 本脚本只读写上述白名单键，凭据值绝不回显到输出（status 仅报 set/missing）。
 *   - .env.local 已被 .gitignore 忽略，切勿提交或分享。
 * ============================================================
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SKILL_ROOT = path.resolve(__dirname, '..');
const CONF_FILE = path.join(SKILL_ROOT, '.env.local');

// 与 checkin.sh / checkin.ps1 保持一致的白名单
const WHITELIST = [
  'TG_BOT_TOKEN',
  'TG_CHAT_ID',
  'TG_PROXY',
  'WB_CHECKIN_TELEGRAM',
  'WB_CHECKIN_TG_TIMEOUT',
];
const PROXY_FALLBACK = ['HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy'];
const DEFAULT_TIMEOUT = 10;
const TEST_TEXT = '✅ WorkBuddy 签到推送测试成功。本对话将接收每日签到结果通知。';

const OFF_VALUES = ['0', 'false', 'no', 'off', 'declined'];
const ON_VALUES = ['1', 'true', 'yes', 'on', 'enabled'];

/* ---------------- 配置读取 ---------------- */

function readConfMap() {
  const map = {};
  if (!fs.existsSync(CONF_FILE)) return map;
  let text = '';
  try {
    text = fs.readFileSync(CONF_FILE, 'utf8');
  } catch (e) {
    return map;
  }
  for (let line of text.split(/\r?\n/)) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i < 1) continue;
    const key = line.slice(0, i).trim();
    if (!WHITELIST.includes(key)) continue;
    let val = line.slice(i + 1).trim();
    if (val.length >= 2 && ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'")))) {
      val = val.slice(1, -1);
    }
    map[key] = val;
  }
  return map;
}

function getSetting(name) {
  const env = process.env[name];
  if (env) return env;
  return readConfMap()[name] || '';
}

// 凭据来源（只报告来源，不报告值）
function getSource(name) {
  if (process.env[name]) return 'env';
  if (readConfMap()[name]) return 'file';
  return 'none';
}

function getProxy() {
  const p = getSetting('TG_PROXY');
  if (p) return p;
  for (const n of PROXY_FALLBACK) {
    if (process.env[n]) return process.env[n];
  }
  return '';
}

function getTimeout() {
  const t = parseInt(getSetting('WB_CHECKIN_TG_TIMEOUT'), 10);
  return Number.isFinite(t) && t > 0 ? t : DEFAULT_TIMEOUT;
}

function getState() {
  const sw = (getSetting('WB_CHECKIN_TELEGRAM') || '').trim().toLowerCase();
  if (OFF_VALUES.includes(sw)) return 'declined';
  if (ON_VALUES.includes(sw)) return 'enabled';
  if (getSetting('TG_BOT_TOKEN') && getSetting('TG_CHAT_ID')) return 'enabled';
  return 'unset';
}

function stateLabel(state) {
  if (state === 'enabled') return '已启用（签到后自动推送；凭据齐备）';
  if (state === 'declined') return '已拒绝（直接签到、不再询问；如需重新启用请删除 WB_CHECKIN_TELEGRAM 或改为 1）';
  return '未配置（首次使用需询问用户是否需要 TG 推送）';
}

// 代理串可能含认证信息（http://user:pass@host），输出前打码
function maskProxy(p) {
  if (!p) return '';
  try {
    const u = new URL(p);
    if (u.username || u.password) {
      u.username = '***';
      u.password = '***';
    }
    return u.toString();
  } catch (e) {
    return String(p).replace(/\/\/[^@/]*@/, '//***@');
  }
}

/* ---------------- 配置写入 ---------------- */

// 就地更新白名单键：保留文件里其他键与全部注释，缺失的键追加到末尾
function writeConf(updates) {
  const existed = fs.existsSync(CONF_FILE);
  let text = '';
  if (existed) {
    try {
      text = fs.readFileSync(CONF_FILE, 'utf8');
    } catch (e) {
      text = '';
    }
  }
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const remaining = new Map(Object.entries(updates));
  const out = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw;
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) {
      out.push(line);
      continue;
    }
    const i = line.indexOf('=');
    if (i < 1) {
      out.push(line);
      continue;
    }
    const key = line.slice(0, i).trim();
    if (!WHITELIST.includes(key)) {
      out.push(line);
      continue;
    }
    if (remaining.has(key)) {
      out.push(key + '=' + remaining.get(key));
      remaining.delete(key);
    } else {
      out.push(line);
    }
  }
  while (out.length && out[out.length - 1].trim() === '') out.pop();
  if (out.length) out.push('');
  for (const [k, v] of remaining) out.push(k + '=' + v);
  out.push('');
  fs.writeFileSync(CONF_FILE, out.join(eol), { mode: 0o600 });
  try {
    fs.chmodSync(CONF_FILE, 0o600);
  } catch (e) {
    /* Windows 上无 POSIX 权限位，忽略 */
  }
}

/* ---------------- 测试推送 ---------------- */

function classifyHttp(code, bodyText) {
  let desc = '';
  try {
    const j = JSON.parse(bodyText);
    if (j && typeof j.description === 'string') desc = j.description;
  } catch (e) {
    /* 非 JSON 响应体 */
  }
  if (code === '200') return { ok: true, reason: 'OK', detail: '' };
  if (code === '000' || code === '') {
    return {
      ok: false,
      reason: 'NETWORK',
      detail: '未能建立连接（本机可能无法直连 api.telegram.org）：' + (desc || 'HTTP 000'),
    };
  }
  if (code === '401' || code === '404') {
    return { ok: false, reason: 'BAD_TOKEN', detail: 'HTTP ' + code + '：Bot Token 不正确或已失效' + (desc ? '（' + desc + '）' : '') };
  }
  if (code === '403') {
    return { ok: false, reason: 'FORBIDDEN', detail: 'HTTP 403：机器人被对方屏蔽，或 TA 尚未向该机器人发送过 /start' + (desc ? '（' + desc + '）' : '') };
  }
  if (code === '400') {
    return { ok: false, reason: 'BAD_CHAT', detail: 'HTTP 400：chat id 不正确，或该对话尚未与机器人建立过会话（请先向机器人发送 /start）' + (desc ? '（' + desc + '）' : '') };
  }
  return { ok: false, reason: 'HTTP_ERROR', detail: 'HTTP ' + code + (desc ? '：' + desc : '') };
}

// 用 curl 发送一条消息（中文经临时文件传递，避免 Windows 命令行编码问题）
function sendTestMessage(token, chatId, proxy, timeout) {
  const tmpFile = path.join(os.tmpdir(), 'wb-checkin-tg-' + process.pid + '-' + Date.now() + '.txt');
  try {
    fs.writeFileSync(tmpFile, TEST_TEXT, 'utf8');
  } catch (e) {
    return { ok: false, reason: 'TEMP_FILE', detail: '无法写入临时文件：' + e.message };
  }
  const curlBin = process.platform === 'win32' ? 'curl.exe' : 'curl';
  const args = ['-s', '-m', String(timeout), '-w', '\\n%{http_code}', '-X', 'POST'];
  if (proxy) args.push('-x', proxy);
  args.push(
    'https://api.telegram.org/bot' + token + '/sendMessage',
    '--data-urlencode', 'chat_id=' + chatId,
    '--data-urlencode', 'text@' + tmpFile
  );
  let r;
  try {
    r = spawnSync(curlBin, args, { encoding: 'utf8', windowsHide: true });
  } catch (e) {
    r = { error: e };
  } finally {
    try {
      fs.unlinkSync(tmpFile);
    } catch (e) {
      /* 忽略清理失败 */
    }
  }
  if (!r || r.error) {
    const msg = r && r.error ? r.error.message : '未知错误';
    return { ok: false, reason: 'CURL_MISSING', detail: '无法执行 curl（' + msg + '）。Windows 10 1803+ / macOS / Linux 自带 curl，请检查 PATH。' };
  }
  const out = (r.stdout || '').replace(/\r/g, '');
  const lines = out.split('\n');
  const httpCode = (lines.pop() || '').trim();
  const body = lines.join('\n').trim();
  const verdict = classifyHttp(httpCode, body);
  if (!verdict.ok && (r.status !== 0 || httpCode === '')) {
    const code = r.status;
    let detail = '网络层失败（curl 退出码 ' + code + '）';
    if ([5, 6].includes(code)) detail += '：域名解析失败，请检查网络或代理';
    else if (code === 7) detail += '：连接被拒绝，本机可能无法直连 api.telegram.org，请配置代理';
    else if (code === 28) detail += '：请求超时，请检查网络或代理';
    else if ([35, 60].includes(code)) detail += '：TLS 握手失败，代理或网络可能拦截了连接';
    return { ok: false, reason: 'NETWORK', detail: detail };
  }
  return verdict;
}

/* ---------------- 子命令 ---------------- */

function printUsage() {
  console.log([
    '用法：node scripts/tg-config.js <子命令> [选项]',
    '',
    '子命令：',
    '  status   查看配置状态（unset 未配置 / enabled 已启用 / declined 已拒绝）',
    '  test     用当前（或临时指定的）凭据发一条测试消息',
    '  set      写入凭据；默认先做连通性测试，测试成功才落盘',
    '  decline  持久化「不需要推送」状态，之后签到直接跳过、不再询问',
    '',
    '选项：',
    '  --token <t>     Telegram Bot Token（set 必填）',
    '  --chat <c>      接收消息的 chat id / user id（set 必填）',
    '  --proxy <url>   访问 Telegram 的代理，如 http://127.0.0.1:7890',
    '  --no-test       set 时跳过连通性测试直接落盘（不建议；仅用于离线排障）',
    '  --json          仅输出机器可读 JSON',
    '  -h, --help      显示本帮助',
  ].join('\n'));
}

function parseArgs(args) {
  const opts = { _: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!a.startsWith('--')) {
      opts._.push(a);
      continue;
    }
    const eq = a.indexOf('=');
    if (eq > -1) {
      opts[a.slice(2, eq)] = a.slice(eq + 1);
      continue;
    }
    const key = a.slice(2);
    if (key === 'json' || key === 'no-test' || key === 'help') {
      opts[key] = true;
      continue;
    }
    const next = args[i + 1];
    if (next === undefined || next.startsWith('--')) {
      opts[key] = true;
    } else {
      opts[key] = next;
      i++;
    }
  }
  return opts;
}

function out(obj, textLines, opts) {
  if (opts.json) {
    console.log(JSON.stringify(obj, null, 2));
  } else {
    console.log(textLines.join('\n'));
  }
}

function cmdStatus(opts) {
  const state = getState();
  const hasToken = !!getSetting('TG_BOT_TOKEN');
  const hasChat = !!getSetting('TG_CHAT_ID');
  const proxy = getProxy();
  const timeout = getTimeout();
  const skipHint = () => {
    if (state === 'enabled' && (!hasToken || !hasChat)) {
      return '已启用但凭据缺失：请执行 set 补齐凭据，或执行 decline 关闭推送（签到主脚本会在日志里提示该问题）。';
    }
    if (state === 'enabled') return '无需处理：签到后会自动推送。';
    if (state === 'declined') return '无需处理：签到后不推送，也不再询问；如需启用请执行 set 或把 WB_CHECKIN_TELEGRAM 改为 1。';
    return '首次使用：请先询问用户是否需要 TG 推送 —— 需要则收集 Bot Token 与 chat id 后执行 set；不需要则执行 decline。';
  };

  const obj = {
    state: state,
    stateLabel: stateLabel(state),
    credentials: {
      TG_BOT_TOKEN: hasToken ? 'set' : 'missing',
      TG_CHAT_ID: hasChat ? 'set' : 'missing',
    },
    credentialSource: {
      TG_BOT_TOKEN: getSource('TG_BOT_TOKEN'),
      TG_CHAT_ID: getSource('TG_CHAT_ID'),
    },
    proxy: maskProxy(proxy),
    proxySet: !!proxy,
    timeout: timeout,
    configFile: CONF_FILE,
    configFileExists: fs.existsSync(CONF_FILE),
    suggestNextAction: skipHint(),
  };

  out(obj, [
    'Telegram 推送配置状态',
    '- 状态：' + state + ' —— ' + stateLabel(state),
    '- 凭据：TG_BOT_TOKEN ' + (hasToken ? '已配置' : '缺失') + '；TG_CHAT_ID ' + (hasChat ? '已配置' : '缺失')
      + (hasToken || hasChat ? '（来源：token=' + getSource('TG_BOT_TOKEN') + '，chat=' + getSource('TG_CHAT_ID') + '）' : ''),
    '- 代理：' + (proxy ? maskProxy(proxy) : '未配置（本机可直连 api.telegram.org 时无需配置）'),
    '- 超时：' + timeout + ' 秒',
    '- 配置文件：' + CONF_FILE + (fs.existsSync(CONF_FILE) ? '（存在）' : '（不存在）'),
    '- 建议动作：' + skipHint(),
  ], opts);
  return 0;
}

function validToken(t) {
  return /^\d{6,}:[A-Za-z0-9_-]{20,}$/.test(t);
}

function validChat(c) {
  return /^-?\d+$/.test(c) || /^@[A-Za-z0-9_]{4,}$/.test(c);
}

function runTest(token, chatId, proxy, opts) {
  const timeout = getTimeout();
  const result = sendTestMessage(token, chatId, proxy, timeout);
  const obj = {
    ok: result.ok,
    reason: result.reason,
    detail: result.detail,
    proxySet: !!proxy,
  };
  if (result.ok) {
    out(obj, ['✅ 测试消息已发送成功：请到 Telegram 确认是否收到。'], opts);
    return 0;
  }
  const lines = ['❌ 测试推送失败（' + result.reason + '）：' + result.detail];
  if (result.reason === 'NETWORK') {
    lines.push('   → 本机可能无法直连 api.telegram.org，请加 --proxy <代理地址> 重试（例如 --proxy http://127.0.0.1:7890）。');
  } else if (result.reason === 'BAD_TOKEN') {
    lines.push('   → 请在 Telegram 里找 @BotFather 核对 Token 是否复制完整（形如「数字ID:字母数字串」）。');
  } else if (result.reason === 'BAD_CHAT') {
    lines.push('   → 请让接收人先向该机器人发送 /start，再用其 user id 重试；群组 chat id 为负数。');
  } else if (result.reason === 'CURL_MISSING') {
    lines.push('   → 请确认系统已安装 curl（Windows 10 1803+ / macOS / Linux 自带）。');
  }
  out(obj, lines, opts);
  return 1;
}

function cmdTest(opts) {
  const token = typeof opts.token === 'string' ? opts.token : getSetting('TG_BOT_TOKEN');
  const chatId = typeof opts.chat === 'string' ? opts.chat : getSetting('TG_CHAT_ID');
  const proxy = typeof opts.proxy === 'string' ? opts.proxy : getProxy();
  if (!token || !chatId) {
    const obj = { ok: false, reason: 'NO_CREDENTIALS', detail: '缺少 TG_BOT_TOKEN 或 TG_CHAT_ID' };
    out(obj, ['❌ 缺少凭据：未提供 --token/--chat，且环境变量与 .env.local 中也没有完整凭据。'], opts);
    return 1;
  }
  return runTest(token, chatId, proxy, opts);
}

function cmdSet(opts) {
  const token = typeof opts.token === 'string' ? opts.token.trim() : '';
  const chatId = typeof opts.chat === 'string' ? opts.chat.trim() : '';
  const proxy = typeof opts.proxy === 'string' ? opts.proxy.trim() : '';

  if (!token || !chatId) {
    const obj = { ok: false, reason: 'MISSING_ARGS', detail: 'set 需要 --token 与 --chat' };
    out(obj, [
      '❌ 参数不足：set 需要同时提供 --token 与 --chat。',
      '   用法：node scripts/tg-config.js set --token <Bot Token> --chat <chat id> [--proxy <代理地址>]',
    ], opts);
    return 2;
  }
  if (!validToken(token)) {
    const obj = { ok: false, reason: 'INVALID_TOKEN', detail: 'Bot Token 格式不正确' };
    out(obj, ['❌ Bot Token 格式不正确：应为 @BotFather 给出的「数字ID:字母数字串」形式。'], opts);
    return 2;
  }
  if (!validChat(chatId)) {
    const obj = { ok: false, reason: 'INVALID_CHAT', detail: 'chat id 格式不正确' };
    out(obj, ['❌ chat id 格式不正确：应为整数（群组为负数，如 -1001234567890）或 @频道名。'], opts);
    return 2;
  }

  const effectiveProxy = proxy || getProxy();

  // 默认先做连通性测试，成功才落盘（避免把错 token / 不可达配置写进文件）
  if (!opts['no-test']) {
    const timeout = getTimeout();
    const result = sendTestMessage(token, chatId, effectiveProxy, timeout);
    if (!result.ok) {
      const obj = { ok: false, reason: result.reason, detail: result.detail, saved: false };
      const lines = [
        '❌ 连通性测试失败，配置未写入（' + result.reason + '）：' + result.detail,
      ];
      if (result.reason === 'NETWORK') {
        lines.push('   → 本机可能无法直连 api.telegram.org：请加 --proxy <代理地址> 重试（例如 --proxy http://127.0.0.1:7890）；');
        lines.push('     或询问用户是否放弃推送：node scripts/tg-config.js decline');
      } else if (result.reason === 'BAD_TOKEN') {
        lines.push('   → 请与用户在 @BotFather 处核对 Token 后重试。');
      } else if (result.reason === 'BAD_CHAT') {
        lines.push('   → 请让用户先向该机器人发送 /start，并核对其 user id / chat id 后重试。');
      }
      lines.push('   → 若确需离线写入（不测试），可加 --no-test，但请自行确认凭据正确。');
      out(obj, lines, opts);
      return 1;
    }
  }

  const updates = {
    TG_BOT_TOKEN: token,
    TG_CHAT_ID: chatId,
    WB_CHECKIN_TELEGRAM: '1',
  };
  if (effectiveProxy) updates.TG_PROXY = effectiveProxy;
  try {
    writeConf(updates);
  } catch (e) {
    const obj = { ok: false, reason: 'WRITE_FAILED', detail: e.message, saved: false };
    out(obj, ['❌ 写入配置文件失败：' + e.message], opts);
    return 1;
  }

  const obj = {
    ok: true,
    saved: true,
    state: 'enabled',
    configFile: CONF_FILE,
    proxySet: !!effectiveProxy,
    tested: !opts['no-test'],
  };
  const lines = [
    opts['no-test'] ? '✅ 凭据已写入（未做连通性测试）。' : '✅ 连通性测试通过，凭据已写入。',
    '- 配置文件：' + CONF_FILE + '（已被 .gitignore 忽略，切勿提交或分享）',
    '- 状态：enabled —— 之后每次签到完成都会自动推送。',
  ];
  if (!effectiveProxy) {
    lines.push('- 提示：当前未配置代理；若本机无法直连 api.telegram.org，推送会失败并在签到日志里给出提示，届时可用 --proxy 重新执行 set。');
  }
  out(obj, lines, opts);
  return 0;
}

function cmdDecline(opts) {
  try {
    writeConf({ WB_CHECKIN_TELEGRAM: '0' });
  } catch (e) {
    const obj = { ok: false, reason: 'WRITE_FAILED', detail: e.message };
    out(obj, ['❌ 写入配置文件失败：' + e.message], opts);
    return 1;
  }
  const obj = {
    ok: true,
    state: 'declined',
    configFile: CONF_FILE,
  };
  out(obj, [
    '✅ 已记录「不需要推送」（WB_CHECKIN_TELEGRAM=0，已持久化）。',
    '- 配置文件：' + CONF_FILE,
    '- 之后签到会直接执行、不再询问；如需重新启用，删除该行或把它改为 1（也可再次执行 set）。',
  ], opts);
  return 0;
}

function main() {
  const argv = process.argv.slice(2);
  const cmd = (argv[0] || '').toLowerCase();
  const opts = parseArgs(argv.slice(1));
  switch (cmd) {
    case 'status':
      return cmdStatus(opts);
    case 'test':
      return cmdTest(opts);
    case 'set':
      return cmdSet(opts);
    case 'decline':
      return cmdDecline(opts);
    case '':
    case 'help':
    case '-h':
      printUsage();
      return 0;
    default:
      console.error('未知子命令：' + cmd);
      printUsage();
      return 2;
  }
}

process.exit(main());
