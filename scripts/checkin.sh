#!/bin/bash
# ============================================================
# WorkBuddy 每日积分签到（通用版，可分发）
#
# 流程：自动更新检查 → 读取本地令牌 → 直接调用签到接口（幂等）→ 写日志
# 用法：
#   ./checkin.sh                      # 自动探测运行时（Node 优先，Electron 回退）
#   WB_CHECKIN_NODE=<path> ./checkin.sh
#   WB_CHECKIN_ELECTRON=<path> ./checkin.sh
# 定时（示例，每天 09:00）：
#   crontab -e
#   0 9 * * * /path/to/checkin.sh >> /path/to/logs/checkin.log 2>&1
#
# 运行时策略：
#   - 优先用 Node 读取 v5.3.8+ 的新版明文登录态（无需 Electron）。
#   - 新版明文文件缺失时，回退到 Electron + safeStorage 解密旧版 state.vscdb。
#
# ⚠️ 凭据安全提示：
#   - 本地令牌（accessToken）等同 WorkBuddy 账号密码，仅在本脚本内存中使用，
#     通过管道立即消费，不写入日志、不落地、不回显。
#   - 日志（logs/checkin.log）只记录签到结果（积分/连续天数），不含令牌。
#   - 切勿将日志、脚本输出粘贴分享或提交到任何仓库。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/../logs"

# ---------- Windows / Git Bash 路径归一化 ----------
# MSYS 的 pwd 返回 /c/... 形式，原样传给原生 node.exe 会被拼成 C:\c\Users\... ，
# 报 "Cannot find module '<path>'" → 取不到令牌 → 误报「未找到 Node 运行时」
# （真实原因被 decrypt 调用的 2>/dev/null 吞掉，排查方向完全跑偏）。
# 凡是要交给原生 Windows 程序（node.exe / electron.exe）的路径，都先转原生形式。
to_native_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

# 注意：DECRYPT_JS 用原生路径；LOG_DIR 仍用 MSYS 路径（只给 mkdir/tee 用）
DECRYPT_JS="$(to_native_path "$SCRIPT_DIR")/decrypt-token.js"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/checkin.log"

# ---------- 探测 Node 运行时（v5.3.8+ 新版明文登录态优先用 Node 直读） ----------
find_node() {
  # 1) 显式指定
  if [ -n "${WB_CHECKIN_NODE:-}" ] && [ -x "$WB_CHECKIN_NODE" ]; then
    echo "$WB_CHECKIN_NODE"; return
  fi
  # 2) PATH 上的 node + 常见绝对路径（cron/launchd 的 PATH 可能很精简）
  local cands=(
    "$(command -v node 2>/dev/null)"
    "$HOME/.local/bin/node"
    "/opt/homebrew/bin/node"
    "/usr/local/bin/node"
    "$HOME/.nvm/versions/node"/*/bin/node
  )
  for c in "${cands[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

# ---------- 探测 Electron 运行时（仅旧版 state.vscdb 回退分支需要） ----------
find_electron() {
  # 1) 显式指定
  if [ -n "${WB_CHECKIN_ELECTRON:-}" ] && [ -x "$WB_CHECKIN_ELECTRON" ]; then
    echo "$WB_CHECKIN_ELECTRON"; return
  fi
  # 2) 本 skill 常见安装位置（含 Windows/Git Bash 路径，electron.exe）
  local cands=(
    "$HOME/.workbuddy/tools/electron/Electron.app/Contents/MacOS/Electron"
    "$HOME/.workbuddy/tools/electron/electron.exe"
    "$HOME/.workbuddy/skills/workbuddy-checkin/.runtime/electron/Electron.app/Contents/MacOS/Electron"
    "$HOME/.workbuddy/skills/workbuddy-checkin/.runtime/electron/electron.exe"
    "$SCRIPT_DIR/../.runtime/electron/Electron.app/Contents/MacOS/Electron"
    "$SCRIPT_DIR/../.runtime/electron/electron.exe"
    "$(command -v electron 2>/dev/null)"
  )
  for c in "${cands[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

# ---------- 读取令牌：Node 优先，Electron 回退 ----------
# 保留 decrypt-token.js 的全部输出（token + 账号字段），供后续提取鉴权头使用。
DECRYPT_OUT=""
read_token() {
  local node_bin electron_bin
  node_bin="$(find_node)"
  if [ -n "$node_bin" ]; then
    DECRYPT_OUT=$("$node_bin" "$DECRYPT_JS" 2>/dev/null)
  fi
  # Node 未产出结果（未装 Node / 崩溃）→ 回退 Electron
  if [ -z "$DECRYPT_OUT" ] || ! printf '%s\n' "$DECRYPT_OUT" | grep -q "^DECRYPT_RESULT:"; then
    electron_bin="$(find_electron)"
    if [ -n "$electron_bin" ]; then
      DECRYPT_OUT=$(env -u ELECTRON_RUN_AS_NODE "$electron_bin" "$DECRYPT_JS" 2>/dev/null)
    fi
  fi
  # Node 报 ERR（ERR 行同样带 DECRYPT_RESULT: 前缀，如旧版账户无明文文件、
  # 纯 Node 无法解密 state.vscdb）→ 同样回退 Electron 解旧版库，对齐 1.0.4 行为。
  # 否则旧版账户在装有 Electron 的机器上会直接 exit 1，丢掉唯一可用路径。
  if printf '%s\n' "$DECRYPT_OUT" | grep -q "^DECRYPT_RESULT:ERR"; then
    electron_bin="$(find_electron)"
    if [ -n "$electron_bin" ]; then
      DECRYPT_OUT=$(env -u ELECTRON_RUN_AS_NODE "$electron_bin" "$DECRYPT_JS" 2>/dev/null)
    fi
  fi
}

# 从解密输出提取 token 与账号字段（逆向自客户端 buildHeaders 的鉴权头）
extract_fields() {
  TOKEN=$(printf '%s\n' "$DECRYPT_OUT" | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')
  ACC_UID=$(printf '%s\n' "$DECRYPT_OUT" | grep "^ACCOUNT_UID:" | sed 's/^ACCOUNT_UID://')
  ACC_DOMAIN=$(printf '%s\n' "$DECRYPT_OUT" | grep "^AUTH_DOMAIN:" | sed 's/^AUTH_DOMAIN://')
  ACC_EID=$(printf '%s\n' "$DECRYPT_OUT" | grep "^ENTERPRISE_ID:" | sed 's/^ENTERPRISE_ID://')
}

# 构造鉴权头数组：Authorization 必带，X-User-Id 等按账号字段补齐。
# APISIX 网关缺 X-User-Id 等会判未授权（401）；原 sh 版漏带这些头，此处对齐 ps1 版。
build_auth_headers() {
  AUTH_HEADERS=(-H "Content-Type: application/json" -H "Accept: application/json" \
    -H "Authorization: Bearer $TOKEN" -H "X-User-Id: $ACC_UID")
  if [ -n "$ACC_DOMAIN" ]; then AUTH_HEADERS+=(-H "X-Domain: $ACC_DOMAIN"); fi
  if [ -n "$ACC_EID" ]; then AUTH_HEADERS+=(-H "X-Enterprise-Id: $ACC_EID" -H "X-Tenant-Id: $ACC_EID"); fi
}

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

# ---------- 可选：Telegram 推送（签到结束后通知） ----------
# 配置状态三态（面向他人分发时「首次使用引导」的判定依据，详见 SKILL.md）：
#   unset    未配置：无显式开关、也无凭据 —— 首次使用时由 agent 询问是否启用推送
#   enabled  已启用：显式开关为开，或未设开关但凭据齐全（兼容 1.1.0 起无显式开关的既有配置）
#   declined 已拒绝：显式开关为 0/false/no/off/declined —— 直接签到，不再重复询问
# 开关：WB_CHECKIN_TELEGRAM —— 上表「拒绝态」的持久化落点；置 0 即永久关闭且不再询问。
# 凭据：TG_BOT_TOKEN + TG_CHAT_ID —— 由用户自备，按「环境变量 > 本地配置文件」读取，
#       缺一即静默跳过。两种来源均支持：
#         1) 环境变量：TG_BOT_TOKEN / TG_CHAT_ID
#         2) 本地配置文件：<skill 根目录>/.env.local（已被 .gitignore 忽略，切勿提交）
#            格式：每行 KEY=VALUE，# 或空行为注释，值两端的空白与成对引号会被去掉。
#            仅识别白名单键（TG_BOT_TOKEN / TG_CHAT_ID / TG_PROXY /
#            WB_CHECKIN_TELEGRAM / WB_CHECKIN_TG_TIMEOUT）；逐行解析而非 source，
#            避免配置文件里的任意代码被执行。
# 代理：TG_PROXY（如 http://127.0.0.1:7890）；未设置时依次回退常见代理环境变量
#       （HTTPS_PROXY / ALL_PROXY / HTTP_PROXY，含小写写法），与 checkin.ps1 的
#       Get-TgProxy 行为对齐 —— 显式解析，不依赖 curl 对不同大小写变量名的隐式差异；
#       都为空时交给 curl 自身处理。
# 超时：WB_CHECKIN_TG_TIMEOUT（秒，默认 10）。
# 约束：推送属「尽力而为」（best-effort），任何异常一律吞掉，绝不改变退出码；
#       仅在「已启用但凭据缺失」或「发送失败」时向日志追加一行可见提示（便于发现
#       代理未配置等问题），其余情况不写日志；消息内容不含 accessToken 等敏感字段。
TG_CONF_FILE="$SCRIPT_DIR/../.env.local"

# 读取本地配置文件中的单个键：逐行解析、只认白名单键，文件缺失或无该键则返回空。
tg_conf_get() {
  [ -f "$TG_CONF_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                       # 兼容 CRLF 写法
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [ "$key" = "$1" ] || continue
    case "$key" in
      TG_BOT_TOKEN|TG_CHAT_ID|TG_PROXY|WB_CHECKIN_TELEGRAM|WB_CHECKIN_TG_TIMEOUT) ;;
      *) continue ;;
    esac
    val="${line#*=}"
    val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
    printf '%s' "$val"
    return 0
  done < "$TG_CONF_FILE"
  return 0
}

# 取值：环境变量优先，其次本地配置文件；都没有则输出空串。
tg_setting() {
  case "$1" in
    TG_BOT_TOKEN)
      [ -n "${TG_BOT_TOKEN:-}" ] && { printf '%s' "$TG_BOT_TOKEN"; return 0; } ;;
    TG_CHAT_ID)
      [ -n "${TG_CHAT_ID:-}" ] && { printf '%s' "$TG_CHAT_ID"; return 0; } ;;
    TG_PROXY)
      # 与 checkin.ps1 的 Get-TgProxy 对齐：显式回退常见代理环境变量
      local _p
      for _p in "${TG_PROXY:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" \
                "${ALL_PROXY:-}" "${all_proxy:-}" "${HTTP_PROXY:-}" "${http_proxy:-}"; do
        [ -n "$_p" ] && { printf '%s' "$_p"; return 0; }
      done ;;
    WB_CHECKIN_TELEGRAM)
      [ -n "${WB_CHECKIN_TELEGRAM:-}" ] && { printf '%s' "$WB_CHECKIN_TELEGRAM"; return 0; } ;;
    WB_CHECKIN_TG_TIMEOUT)
      [ -n "${WB_CHECKIN_TG_TIMEOUT:-}" ] && { printf '%s' "$WB_CHECKIN_TG_TIMEOUT"; return 0; } ;;
  esac
  tg_conf_get "$1"
}

# 配置状态三态：unset（未配置，需询问）/ enabled（已启用）/ declined（已拒绝，不再询问）。
# 判定顺序：显式开关（含 declined）> 凭据是否齐全（兼容既有「无显式开关」的配置）> unset。
telegram_state() {
  local switch_val
  switch_val="$(tg_setting WB_CHECKIN_TELEGRAM)"
  case "$switch_val" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]|[Dd][Ee][Cc][Ll][Ii][Nn][Ee][Dd]) printf 'declined'; return 0 ;;
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|[Ee][Nn][Aa][Bb][Ll][Ee][Dd]) printf 'enabled'; return 0 ;;
  esac
  if [ -n "$(tg_setting TG_BOT_TOKEN)" ] && [ -n "$(tg_setting TG_CHAT_ID)" ]; then
    printf 'enabled'; return 0
  fi
  printf 'unset'; return 0
}

notify_telegram() {
  # $1 = 消息正文（中文），仅用于 Telegram；不影响签到主流程与退出码。
  # declined：用户已明确不需要推送 → 静默跳过，不再重复询问
  # unset   ：从未配置 → 静默跳过（面向他人分发时由 SKILL.md 的「首次使用引导」负责询问）
  [ "$(telegram_state)" = "enabled" ] || return 0
  local bot_token chat_id timeout proxy proxy_args=() text_file="" sent=0
  bot_token="$(tg_setting TG_BOT_TOKEN)"
  chat_id="$(tg_setting TG_CHAT_ID)"
  if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
    # 已启用却缺凭据：写一行可见提示（不改退出码），便于用户发现配置没写全
    log "⚠️ Telegram 推送已启用但凭据缺失（TG_BOT_TOKEN / TG_CHAT_ID 至少缺一项），本次跳过推送；请运行 node scripts/tg-config.js set --token <token> --chat <chat id> 完成配置，或将 WB_CHECKIN_TELEGRAM 设为 0 关闭推送。"
    return 0
  fi
  timeout="$(tg_setting WB_CHECKIN_TG_TIMEOUT)"
  case "$timeout" in ''|*[!0-9]*) timeout=10 ;; esac
  proxy="$(tg_setting TG_PROXY)"
  [ -n "$proxy" ] && proxy_args=(-x "$proxy")
  # 正文经 UTF-8 临时文件交给 curl，而不是直接放在命令行参数里：
  # Git Bash(MSYS) 会把非 ASCII 的命令行参数按本地代码页转换，中文会变成非法
  # UTF-8，Telegram 直接返回 400 "strings must be encoded in UTF-8"。
  # 文件路径需转成 Windows 原生形式才能被 curl.exe 打开。
  text_file="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/wb_checkin_tg.$$")"
  printf '%s' "$1" > "$text_file" 2>/dev/null || { rm -f "$text_file" 2>/dev/null; return 0; }
  # 响应体与错误一律丢弃，只保留「发消息」这一副作用。数组在 bash 3.2（macOS 自带）
  # 下展开空数组会触发 set -u，故用 ${arr[@]+...} 兼容写法。
  if curl -s -m "$timeout" -o /dev/null -X POST \
    ${proxy_args[@]+"${proxy_args[@]}"} \
    "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text@$(to_native_path "$text_file")" \
    >/dev/null 2>&1; then
    sent=1
  fi
  rm -f "$text_file" 2>/dev/null
  if [ "$sent" -eq 1 ]; then
    return 0
  fi
  # 发送失败（含代理未配置导致的网络层失败）：写一行可见提示，不改退出码
  log "⚠️ Telegram 推送发送失败（网络或代理不可用），本次未收到通知；若本机无法直连 api.telegram.org，请配置 TG_PROXY 后重试（签到本身不受影响）。"
  return 0
}

# ---------- 可选：随机错峰（避免整点风暴） ----------
# 设置 WB_CHECKIN_JITTER=<正整数秒> 时，脚本在开始前随机等待 0~N 秒
# 须 > 0：RANDOM % 0 会触发除零异常；非数字也会被 `[ -gt 0 ]` 拒绝（静默跳过）
if [ "${WB_CHECKIN_JITTER:-0}" -gt 0 ] 2>/dev/null; then
  jitter=$((RANDOM % WB_CHECKIN_JITTER))
  [ "$jitter" -gt 0 ] && sleep "$jitter"
fi

# ---------- 0. 自动更新检查（git 仓库时拉取最新代码） ----------
# 设 WB_CHECKIN_SKIP_UPDATE=1 可跳过；非 git 仓库（压缩包安装等）静默跳过。
# 更新检查为「尽力而为」：网络超时或 pull 失败均不阻塞签到，不影响退出码。
auto_update_check() {
  [ "${WB_CHECKIN_SKIP_UPDATE:-}" = "1" ] && return 0
  local skill_root="$SCRIPT_DIR/.."
  [ -d "$skill_root/.git" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  # git fetch（15 秒超时，超时静默跳过）
  local fetch_rc=1
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 git -C "$skill_root" fetch --quiet 2>/dev/null && fetch_rc=0
  else
    git -C "$skill_root" fetch --quiet 2>/dev/null && fetch_rc=0
  fi
  [ "$fetch_rc" -eq 0 ] || return 0
  # 比较本地与远程：behind 表示远程有新提交
  if git -C "$skill_root" status -sb 2>/dev/null | grep -q '\[behind'; then
    log "检测到远程更新，正在拉取最新版本..."
    if git -C "$skill_root" pull --ff-only --quiet 2>/dev/null; then
      log "更新完成，重新执行签到脚本"
      exec "$0" "$@"
    else
      log "⚠️ 自动更新失败，使用本地版本继续签到"
    fi
  fi
}
auto_update_check "$@"

# ---------- 1. 读取令牌并提取字段 ----------
TOKEN=""; ACC_UID=""; ACC_DOMAIN=""; ACC_EID=""; AUTH_HEADERS=()
read_token
extract_fields

if [ -z "$TOKEN" ]; then
  log "❌ 未找到 Node 或 Electron 运行时，或运行时未能产出令牌。请安装 Node.js，或设置 WB_CHECKIN_NODE / WB_CHECKIN_ELECTRON 指向可用运行时。"
  notify_telegram "❌ WorkBuddy 签到失败
原因：未找到本地登录态或可用运行时（缺少 Node.js / Electron）
建议：安装 Node.js，或设置 WB_CHECKIN_NODE 指向可用运行时"
  exit 1
fi
if [[ "$TOKEN" == ERR* ]]; then
  log "❌ 获取令牌失败（${TOKEN}）。请确认已安装并登录 WorkBuddy 桌面端。"
  notify_telegram "❌ WorkBuddy 签到失败
原因：读取本地登录态失败
建议：确认已安装并登录 WorkBuddy 桌面端后重试"
  exit 1
fi

API="https://copilot.tencent.com"
build_auth_headers

# ---------- 2. 执行签到（幂等，code=10001 表示当日已签） ----------
# 说明：原「先查 checkin-status 再决定是否签到」的链路依赖 today_checked_in 字段，
# 而该字段在 v5.3.8 实测不可靠（签到成功后仍可能为 false）——既会假阴性多打请求，
# 也会假阳性（显示已签实际未签）导致在真正签到前 exit 0、当日漏签、连签中断（第 7 天 1000 积分奖励作废）。
# 因此直接调用 daily-checkin；该接口幂等，已签时返回 code=10001，下方统一兜底为成功。
RESP=$(curl -s -m 15 -w '\n%{http_code}' -X POST "$API/billing/meter/daily-checkin" \
  "${AUTH_HEADERS[@]}" -d '{}' 2>/dev/null || echo "")
HTTP_CODE=$(printf '%s' "$RESP" | tail -n 1)
RESULT=$(printf '%s' "$RESP" | sed '$d')

if [ -z "$RESP" ] || [ "$HTTP_CODE" = "000" ]; then
  log "❌ 签到请求失败（网络异常，无法连接签到接口）"
  notify_telegram "❌ WorkBuddy 签到失败
原因：网络异常，无法连接签到接口
建议：检查本机网络或代理后重试"
  exit 1
fi
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
  log "❌ 令牌已过期或无权限（HTTP $HTTP_CODE），请打开 WorkBuddy 桌面端刷新登录态后重试"
  notify_telegram "❌ WorkBuddy 签到失败
原因：登录状态已过期
建议：打开 WorkBuddy 桌面端重新登录后重试"
  exit 1
fi
if [ -z "$RESULT" ]; then
  log "❌ 签到请求失败（响应为空，HTTP $HTTP_CODE）"
  notify_telegram "❌ WorkBuddy 签到失败
原因：接口未返回内容，签到结果未知
建议：稍后重新运行脚本确认"
  exit 1
fi

# 解析接口返回：仅提取接口真实存在的字段（与桌面端 app.asar 实现一致）
#   code=0     → data 内含 credit（本次获得积分）、streak_days（连续签到天数）、is_streak_day（是否连签奖励日）
#   code=10001 → 当日已签到，仅返回 code + msg，不含 data；连续天数等改由签到活动接口补充
STATE_RAW=""
NODE_BIN="$(find_node)"
if [ -n "$NODE_BIN" ]; then
  STATE_RAW=$(JSON_PAYLOAD="$RESULT" "$NODE_BIN" -e '
const s = process.env.JSON_PAYLOAD || "";
const kv = (k, v) => (v === undefined || v === null || v === "") ? "" : " " + k + "=" + v;
try {
  const d = JSON.parse(s);
  if (d.code === 0) {
    const dd = d.data || {};
    console.log("OK" + kv("credit", dd.credit) + kv("streak_days", dd.streak_days) + (dd.is_streak_day === true ? " is_streak_day=1" : ""));
  } else if (d.code === 10001) {
    console.log("ALREADY today");   // 当日已签到：接口幂等拒绝，视为成功
  } else {
    console.log("FAIL" + kv("code", d.code) + kv("msg", d.msg));
  }
} catch (e) { console.log("PARSE_ERR"); }
' 2>/dev/null)
fi
if [ -z "$STATE_RAW" ]; then
  STATE_RAW=$(printf '%s' "$RESULT" | python3 -c "
import sys, json
def kv(k, v):
    return '' if v is None or v == '' else ' ' + k + '=' + str(v)
try:
    d = json.load(sys.stdin)
    if d.get('code') == 0:
        dd = d.get('data') or {}
        print('OK' + kv('credit', dd.get('credit')) + kv('streak_days', dd.get('streak_days')) + (' is_streak_day=1' if dd.get('is_streak_day') is True else ''))
    elif d.get('code') == 10001:
        print('ALREADY today')
    else:
        print('FAIL' + kv('code', d.get('code')) + kv('msg', d.get('msg')))
except Exception:
    print('PARSE_ERR')
" 2>/dev/null)
fi

# 从 "OK credit=100 streak_days=14" 这类串里取键值；缺失时输出空串
kv_get() { printf '%s' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1; }

# 尽力而为读取签到活动状态：仅用于补充连续天数 / 今日积分 / 累计积分。
# 任何失败（网络、未登录、字段缺失）一律静默忽略，保持空值，绝不展示接口未返回的数值。
ST_STREAK=""; ST_TODAY=""; ST_TOTAL=""
fetch_activity_status() {
  ST_STREAK=""; ST_TODAY=""; ST_TOTAL=""
  local resp http body parsed
  # 官方客户端使用 /v2 前缀；本机实测 /v2/... 与 /... 两种前缀均可被网关接受
  resp=$(curl -s -m 15 -w '\n%{http_code}' -X POST "$API/v2/billing/meter/checkin-activity-status" \
    "${AUTH_HEADERS[@]}" -d '{}' 2>/dev/null || echo "")
  body=$(printf '%s' "$resp" | sed '$d')
  [ -n "$body" ] || return 0
  parsed=""
  if [ -n "$NODE_BIN" ]; then
    parsed=$(STATUS_PAYLOAD="$body" "$NODE_BIN" -e '
const s = process.env.STATUS_PAYLOAD || "";
const kv = (k, v) => (v === undefined || v === null || v === "") ? "" : " " + k + "=" + v;
try {
  const d = JSON.parse(s);
  if (d.code !== 0 || !d.data) process.exit(0);
  const dd = d.data;
  console.log(("OK" + kv("streak_days", dd.streak_days) + kv("today_credit", dd.today_credit) + kv("total_credits", dd.total_credits)).trim());
} catch (e) {}
' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    parsed=$(printf '%s' "$body" | python3 -c "
import sys, json
def kv(k, v):
    return '' if v is None or v == '' else ' ' + k + '=' + str(v)
try:
    d = json.load(sys.stdin)
    if d.get('code') == 0 and d.get('data'):
        dd = d['data']
        print(('OK' + kv('streak_days', dd.get('streak_days')) + kv('today_credit', dd.get('today_credit')) + kv('total_credits', dd.get('total_credits'))).strip())
except Exception:
    pass
" 2>/dev/null)
  else
    return 0
  fi
  ST_STREAK=$(kv_get "$parsed" streak_days)
  ST_TODAY=$(kv_get "$parsed" today_credit)
  ST_TOTAL=$(kv_get "$parsed" total_credits)
  http=$(printf '%s' "$resp" | tail -n 1)
  return 0
}

# ---------- 3. 结果判定与退出码 ----------
# exit 0：成功 / 已签 / 结果未知（缺 Node.js 与 python3 无法解析，服务端可能已成功，不误报失败）
# exit 1：明确失败（code 非 0 非 10001）或解析失败——便于定时任务捕获并告警
if [[ "$STATE_RAW" == OK* ]]; then
  P_CREDIT=$(kv_get "$STATE_RAW" credit)
  P_STREAK=$(kv_get "$STATE_RAW" streak_days)
  P_ISSTREAK=$(kv_get "$STATE_RAW" is_streak_day)
  log "🎉 签到成功！本次获得积分 ${P_CREDIT:-未知}，连续签到 ${P_STREAK:-未知} 天"
  fetch_activity_status
  msg="✅ WorkBuddy 签到成功"
  [ -n "$P_STREAK" ] && msg="$msg
🔥 连续签到：$P_STREAK 天"
  [ -n "$P_CREDIT" ] && msg="$msg
🎁 本次获得：$P_CREDIT 积分"
  [ "$P_ISSTREAK" = "1" ] && msg="$msg
🎉 今日为连续签到奖励日"
  [ -n "$ST_TOTAL" ] && msg="$msg
💰 累计积分：$ST_TOTAL"
  notify_telegram "$msg"
  exit 0
elif [[ "$STATE_RAW" == ALREADY* ]]; then
  log "✅ 今日已签到，无需重复领取（接口返回 10001）"
  fetch_activity_status
  msg="⚠️ WorkBuddy 今日已签到"
  [ -n "$ST_STREAK" ] && msg="$msg
🔥 连续签到：$ST_STREAK 天"
  [ -n "$ST_TODAY" ] && msg="$msg
🎁 今日获得：$ST_TODAY 积分"
  [ -n "$ST_TOTAL" ] && msg="$msg
💰 累计积分：$ST_TOTAL"
  [ "$msg" = "⚠️ WorkBuddy 今日已签到" ] && msg="⚠️ WorkBuddy 今日已签到，无需重复领取"
  notify_telegram "$msg"
  exit 0
elif [ -z "$STATE_RAW" ]; then
  # 多为缺 Node.js 与 python3 导致结果无法解析：服务端可能已成功，不能误报失败
  log "⚠️ 签到请求已提交，但缺少 Node.js / python3 无法解析结果（请打开 WorkBuddy 确认；安装后可恢复明细）"
  notify_telegram "⚠️ WorkBuddy 签到结果未知
原因：本机缺少 Node.js / python3，无法解析接口返回内容（签到请求已提交）
建议：打开 WorkBuddy 桌面端确认签到状态"
  exit 0
elif [[ "$STATE_RAW" == "PARSE_ERR" ]]; then
  log "❌ 签到未成功：签到结果解析失败（PARSE_ERR），请求已提交但结果未知"
  notify_telegram "⚠️ WorkBuddy 签到结果未知
原因：无法解析接口返回内容，签到请求已提交
建议：稍后重新运行脚本确认结果"
  exit 1
else
  P_FAILCODE=$(kv_get "$STATE_RAW" code)
  P_FAILMSG=$(kv_get "$STATE_RAW" msg)
  log "❌ 签到未成功：接口返回 code=${P_FAILCODE:-未知} msg=${P_FAILMSG:-未知}（HTTP ${HTTP_CODE}）"
  reason="${P_FAILMSG:-接口返回异常，签到未成功}"
  notify_telegram "❌ WorkBuddy 签到失败
原因：$reason
建议：稍后重试；若持续失败，请打开 WorkBuddy 桌面端确认登录状态"
  exit 1
fi
