# ============================================================
# WorkBuddy 每日积分签到（Windows PowerShell 版，兼容 PS 5.1）
#
# 流程：读取本地令牌 -> 直接调用签到接口（幂等）-> 写日志
# 用法：
#   powershell -ExecutionPolicy Bypass -File checkin.ps1
# 或（显式指定运行时）：
#   $env:WB_CHECKIN_NODE="C:/path/to/node.exe"
#   $env:WB_CHECKIN_ELECTRON="C:/path/to/electron.exe"
#   powershell -ExecutionPolicy Bypass -File checkin.ps1
# 定时（示例，每天 09:00，管理员或普通用户均可）：
#   schtasks /Create /TN WorkBuddyDailyCheckin /TR "powershell -ExecutionPolicy Bypass -File C:/path/checkin.ps1" /SC DAILY /ST 09:00 /F
#
# 运行时策略：Node 优先（读取 v5.3.8+ 新版明文登录态），缺失时回退到 Electron + safeStorage。
#
# 凭据安全提示：
#   - 本地令牌（accessToken）等同 WorkBuddy 账号密码，仅在本脚本内存中使用，
#     通过管道立即消费，不写入日志、不落地、不回显。
#   - 日志（logs/checkin.log）只记录签到结果（积分/连续天数），不含令牌。
#   - 切勿将日志、脚本输出粘贴分享或提交到任何仓库。
# ============================================================
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DecryptJs = Join-Path $ScriptDir "decrypt-token.js"
$SkillRoot = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $SkillRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "checkin.log"

function Write-Log([string]$msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
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
#         2) 本地配置文件：<skill 根目录>\.env.local（已被 .gitignore 忽略，切勿提交）
#            格式：每行 KEY=VALUE，# 或空行为注释，值两端的空白与成对引号会被去掉。
#            仅识别白名单键（TG_BOT_TOKEN / TG_CHAT_ID / TG_PROXY /
#            WB_CHECKIN_TELEGRAM / WB_CHECKIN_TG_TIMEOUT）；逐行解析，不执行其中任何代码。
# 代理：TG_PROXY（如 http://127.0.0.1:7890）；未设置时依次回退 HTTPS_PROXY / ALL_PROXY /
#       HTTP_PROXY（含小写）环境变量；都为空则沿用系统代理（IE 选项里配置的代理）。
# 超时：WB_CHECKIN_TG_TIMEOUT（秒，默认 10）。
# 约束：推送属「尽力而为」，任何异常一律吞掉，绝不改变退出码；仅在「已启用但凭据缺失」
#       或「发送失败」时向日志追加一行可见提示（便于发现代理未配置等问题），其余情况
#       不写日志；消息内容不含 accessToken 等敏感字段。
# 实现：Invoke-RestMethod + 显式 UTF-8 字节体，规避 PS 5.1 默认编码把中文转成乱码。
$TgConfFile = Join-Path $SkillRoot ".env.local"

# 读取本地配置文件中的单个键：逐行解析、只认白名单键，文件缺失或无该键则返回空。
function Get-TgConfValue([string]$Key) {
    try {
        if (-not (Test-Path $TgConfFile)) { return "" }
        foreach ($line in (Get-Content -Path $TgConfFile -Encoding UTF8)) {
            $l = "$line".Trim()
            if (-not $l -or $l.StartsWith("#")) { continue }
            $i = $l.IndexOf("=")
            if ($i -lt 1) { continue }
            $k = $l.Substring(0, $i).Trim()
            if ($k -ne $Key) { continue }
            $v = $l.Substring($i + 1).Trim()
            if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
                $v = $v.Substring(1, $v.Length - 2)
            }
            return $v
        }
    } catch { }
    return ""
}

# 取值：环境变量优先，其次本地配置文件；都没有则返回空串。
function Get-TgSetting([string]$Name) {
    if ($Name -notin @("TG_BOT_TOKEN", "TG_CHAT_ID", "TG_PROXY", "WB_CHECKIN_TELEGRAM", "WB_CHECKIN_TG_TIMEOUT")) {
        return ""
    }
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v }
    return Get-TgConfValue $Name
}

# 代理：TG_PROXY（环境变量/配置文件）优先，其次常见代理环境变量，最后留空（走系统代理）。
function Get-TgProxy {
    $p = Get-TgSetting "TG_PROXY"
    if ($p) { return $p }
    foreach ($n in @("HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy")) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { return $v }
    }
    return ""
}

# 配置状态三态：unset（未配置，需询问）/ enabled（已启用）/ declined（已拒绝，不再询问）。
# 判定顺序：显式开关（含 declined）> 凭据是否齐全（兼容既有「无显式开关」的配置）> unset。
function Get-TelegramState {
    $sw = Get-TgSetting "WB_CHECKIN_TELEGRAM"
    if ($sw) {
        switch ($sw.Trim().ToLower()) {
            "0"        { return "declined" }
            "false"    { return "declined" }
            "no"       { return "declined" }
            "off"      { return "declined" }
            "declined" { return "declined" }
            "1"        { return "enabled" }
            "true"     { return "enabled" }
            "yes"      { return "enabled" }
            "on"       { return "enabled" }
            "enabled"  { return "enabled" }
        }
    }
    if ((Get-TgSetting "TG_BOT_TOKEN") -and (Get-TgSetting "TG_CHAT_ID")) { return "enabled" }
    return "unset"
}

function Send-TelegramNotice([string]$Text) {
    try {
        # declined（用户已明确不需要推送）/ unset（从未配置）→ 静默跳过，不影响签到
        if ((Get-TelegramState) -ne "enabled") { return }
        $botToken = Get-TgSetting "TG_BOT_TOKEN"
        $chatId = Get-TgSetting "TG_CHAT_ID"
        if (-not $botToken -or -not $chatId) {
            # 已启用却缺凭据：写一行可见提示（退出码不变），便于用户发现配置没写全
            Write-Log "⚠️ Telegram 推送已启用但凭据缺失（TG_BOT_TOKEN / TG_CHAT_ID 至少缺一项），本次跳过推送；请运行 node scripts/tg-config.js set --token <token> --chat <chat id> 完成配置，或将 WB_CHECKIN_TELEGRAM 设为 0 关闭推送。"
            return
        }
        $timeout = 10
        $ts = Get-TgSetting "WB_CHECKIN_TG_TIMEOUT"
        if ($ts) {
            try { $t = [int]$ts; if ($t -gt 0) { $timeout = $t } } catch {}
        }
        # Telegram 强制 TLS 1.2，PS 5.1 默认协议可能过旧导致握手失败
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $payload = @{ chat_id = "$chatId"; text = $Text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $req = @{
            Uri         = "https://api.telegram.org/bot$botToken/sendMessage"
            Method      = "Post"
            ContentType = "application/json; charset=utf-8"
            Body        = $bytes
            TimeoutSec  = $timeout
        }
        $proxy = Get-TgProxy
        if ($proxy) { $req["Proxy"] = $proxy }
        Invoke-RestMethod @req | Out-Null
    } catch {
        # 推送失败不影响签到主流程（退出码不变），但写一行日志便于发现代理未配置等问题。
        # 只写异常类型名，绝不写异常 Message —— 其中可能包含带 Bot Token 的请求 URI。
        try {
            Write-Log "⚠️ Telegram 推送发送失败（$($_.Exception.GetType().Name)：网络或代理不可用），本次未收到通知；若本机无法直连 api.telegram.org，请配置 TG_PROXY 后重试（签到本身不受影响）。"
        } catch {}
    }
}

# ---------- 可选：随机错峰（避免整点风暴） ----------
# 设置环境变量 WB_CHECKIN_JITTER=<秒> 时，开始前随机等待 0~N 秒
if ($env:WB_CHECKIN_JITTER) {
    try {
        $max = [int]$env:WB_CHECKIN_JITTER
        if ($max -gt 0) { Start-Sleep -Seconds (Get-Random -Maximum $max) }
    } catch {}
}

function Find-Node {
    if ($env:WB_CHECKIN_NODE -and (Test-Path $env:WB_CHECKIN_NODE)) { return $env:WB_CHECKIN_NODE }
    $cands = @(
        (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return ""
}

function Find-Electron {
    if ($env:WB_CHECKIN_ELECTRON -and (Test-Path $env:WB_CHECKIN_ELECTRON)) {
        return $env:WB_CHECKIN_ELECTRON
    }
    $cands = @(
        (Join-Path $HOME ".workbuddy\tools\electron\electron.exe"),
        (Join-Path $HOME ".workbuddy\skills\workbuddy-checkin\.runtime\electron\electron.exe"),
        (Join-Path $SkillRoot ".runtime\electron\electron.exe"),
        (Join-Path $ScriptDir "..\node_modules\electron\dist\electron.exe")
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return ""
}

# 1. 读取令牌：Node 优先，Electron 回退
$Token = ""; $AccUid = ""; $AccDomain = ""; $EntId = ""
$NodeBin = Find-Node
if ($NodeBin) {
    try {
        $outLines = & $NodeBin $DecryptJs 2>$null
        foreach ($l in $outLines) {
            if ($l -match "^DECRYPT_RESULT:") { $Token = ($l -replace "^DECRYPT_RESULT:", "").Trim() }
            elseif ($l -match "^ACCOUNT_UID:") { $AccUid = ($l -replace "^ACCOUNT_UID:", "").Trim() }
            elseif ($l -match "^AUTH_DOMAIN:") { $AccDomain = ($l -replace "^AUTH_DOMAIN:", "").Trim() }
            elseif ($l -match "^ENTERPRISE_ID:") { $EntId = ($l -replace "^ENTERPRISE_ID:", "").Trim() }
        }
    } catch {}
}
# Electron 回退（Node 未取到有效 token，或 Node 报 ERR —— 如旧版账户无明文文件、纯 Node 无法解密 state.vscdb）
if (-not $Token -or $Token.StartsWith("ERR")) {
    $Electron = Find-Electron
    if ($Electron) {
        # 关键：若环境存在 ELECTRON_RUN_AS_NODE，必须移除，否则 require('electron') 拿不到 safeStorage
        Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        try {
            $outLines = & $Electron $DecryptJs 2>$null
            foreach ($l in $outLines) {
                if ($l -match "^DECRYPT_RESULT:") { $Token = ($l -replace "^DECRYPT_RESULT:", "").Trim() }
                elseif ($l -match "^ACCOUNT_UID:") { $AccUid = ($l -replace "^ACCOUNT_UID:", "").Trim() }
                elseif ($l -match "^AUTH_DOMAIN:") { $AccDomain = ($l -replace "^AUTH_DOMAIN:", "").Trim() }
                elseif ($l -match "^ENTERPRISE_ID:") { $EntId = ($l -replace "^ENTERPRISE_ID:", "").Trim() }
            }
        } catch {
            Write-Log "调用 Electron 解密脚本出错：$($_.Exception.Message)"
        }
    }
}

if (-not $Token) {
    Write-Log "未找到 Node 或 Electron 运行时，或运行时未能产出令牌。请安装 Node.js，或设置 WB_CHECKIN_NODE / WB_CHECKIN_ELECTRON。"
    Send-TelegramNotice "[失败] WorkBuddy 签到失败：未找到本地登录态或运行时（缺少 Node.js / Electron）。请安装 Node.js 或设置 WB_CHECKIN_NODE 指向可用运行时。"
    exit 1
}
if ($Token.StartsWith("ERR")) {
    Write-Log "获取令牌失败（$Token）。请确认已安装并登录 WorkBuddy 桌面端。"
    Send-TelegramNotice "[失败] WorkBuddy 签到失败：获取令牌失败。请确认已安装并登录 WorkBuddy 桌面端后重试。"
    exit 1
}

$Api = "https://copilot.tencent.com"

# 复刻 WorkBuddy 桌面端真实签名（逆向自 app.asar 的 buildHeaders）：
# 官方接口路径需 /v2/ 前缀，且必须带 X-User-Id（企业账号另带 X-Enterprise-Id / X-Tenant-Id）。
# 缺任一项都会被 APISIX 网关判定为未授权（HTTP 401）。
function Invoke-CheckinApi([string]$Path) {
    $a = @(
        "-s", "-m", "15", "-w", "\n%{http_code}", "-X", "POST",
        "$Api$Path",
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-H", "Authorization: Bearer $Token",
        "-H", "X-User-Id: $AccUid"
    )
    if ($AccDomain) { $a += "-H"; $a += "X-Domain: $AccDomain" }
    if ($EntId) { $a += "-H"; $a += "X-Enterprise-Id: $EntId"; $a += "-H"; $a += "X-Tenant-Id: $EntId" }
    $a += "-d"; $a += "{}"
    # 关键：PowerShell 解码原生进程输出用的是 [Console]::OutputEncoding，中文 Windows
    # 默认为 GB2312/GBK。接口返回的是 UTF-8 JSON，按 GBK 解码会把中文 msg 转成乱码，
    # 且乱码字节可能吃掉闭合引号 —— 结果是 ConvertFrom-Json 抛
    # 「传入的对象无效，应为“:”或“}”」，被外层 catch 成 PARSE_ERR，误报「签到未成功」。
    # 因此在调用 curl.exe 期间临时切到 UTF-8，结束后还原。
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $raw = & curl.exe @a 2>$null
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
    # 末行是 HTTP 状态码，其余为响应体；返回 [状态码, 响应体]
    if (-not $raw) { return @("000", "") }
    $lines = @($raw)
    $code = [string]($lines | Select-Object -Last 1)
    $body = if ($lines.Count -gt 1) { ($lines | Select-Object -First ($lines.Count - 1)) -join "" } else { "" }
    return @($code, $body)
}

# 2. 直接执行签到（不预先调用 checkin-status）
# 说明：原实现先调 checkin-status、再用 today_checked_in 字段短路。该字段在
# v5.3.8 实测不可靠（签到成功后仍可能为 false），既会假阴性多打请求，也会假阳性
#（显示已签实际未签）导致在真正签到前 exit 0、当日漏签、连续签到中断。
# daily-checkin 接口幂等：已签时返回 code=10001，下方统一兜底为成功。
$Result = ""; $HttpCode2 = "000"
try { $r2 = Invoke-CheckinApi "/v2/billing/meter/daily-checkin"; $HttpCode2 = $r2[0]; $Result = $r2[1] } catch { $HttpCode2 = "000"; $Result = "" }
if ($HttpCode2 -eq "000") {
    Write-Log "签到请求失败（网络异常）"
    Send-TelegramNotice "[失败] WorkBuddy 签到失败：网络异常，无法连接签到接口（HTTP 000）。"
    exit 1
}
if ($HttpCode2 -eq "401" -or $HttpCode2 -eq "403") {
    Write-Log "令牌已过期或无权限（HTTP $HttpCode2），请打开 WorkBuddy 桌面端刷新登录态后重试"
    Send-TelegramNotice "[警告] WorkBuddy 签到失败：令牌已过期或无权限（HTTP $HttpCode2）。请打开 WorkBuddy 桌面端刷新登录态后重试。"
    exit 1
}
if (-not $Result) {
    Write-Log "签到请求失败（响应为空，HTTP $HttpCode2）"
    Send-TelegramNotice "[失败] WorkBuddy 签到失败：接口返回空响应（HTTP $HttpCode2）。"
    exit 1
}

$Credit = ""
try {
    $d = $Result | ConvertFrom-Json
    if ($d.code -eq 0) { $Credit = "OK credit=$($d.data.credit) streak_days=$($d.data.streak_days)" }
    elseif ($d.code -eq 10001) { $Credit = "ALREADY today" }   # 当日已签到：接口幂等拒绝，视为成功
    else { $Credit = "FAIL code=$($d.code) msg=$($d.msg)" }
} catch { $Credit = "PARSE_ERR" }

if ($Credit -like "OK*") {
    Write-Log "签到成功！领取 $Credit"
    $detail = $Credit -replace '^OK\s+', ''
    Send-TelegramNotice "[成功] WorkBuddy 签到成功：$detail（HTTP $HttpCode2）"
    exit 0
}
elseif ($Credit -like "ALREADY*") {
    Write-Log "今日已签到，无需重复领取（接口返回已签到）"
    Send-TelegramNotice "[提示] WorkBuddy 今日已签到，无需重复领取（HTTP $HttpCode2）。"
    exit 0
}
elseif ($Credit -eq "PARSE_ERR") {
    Write-Log ("签到未成功：" + $Credit)
    Send-TelegramNotice "[失败] WorkBuddy 签到结果解析失败（PARSE_ERR，HTTP $HttpCode2）。请求已提交，但签到结果未知。"
    exit 1
}
else {
    Write-Log ("签到未成功：" + $Credit)
    Send-TelegramNotice "[失败] WorkBuddy 签到未成功：$Credit（HTTP $HttpCode2）"
    exit 1
}
