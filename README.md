# workbuddy-checkin

自动领取 **WorkBuddy 每日积分** 的本地签到 skill：直接复用本机 WorkBuddy 桌面端已登录的登录态，调用腾讯官方签到接口完成签到。**无后端服务、无模拟点击、不启动 GUI**。

- 每日签到 **100 积分**，连续第 7 天 **1000 积分**（积分规则以官方为准）
- 全流程在本机完成：自动检查更新 → 读取本地登录态 → 调用官方接口 → 写本地日志
- **幂等**：重复运行不会重复领取，也不会中断连续签到
- 可选：把签到结果（状态 / 领取积分 / 连续天数）推送到你自己的 Telegram
- 跨平台：Windows（PowerShell 或 Git Bash）、macOS、Linux

> 本文档中的 `<skill根目录>` 指包含 `SKILL.md` 与 `scripts/` 的那个目录；`/path/to/workbuddy-checkin`、`C:\path\to\workbuddy-checkin` 均为占位符，请替换为你的实际安装路径。

---

## 1. 项目简介与能力

| 能力 | 说明 |
|---|---|
| 自动签到 | 读取本机 WorkBuddy 登录态中的 `accessToken`，调用官方 `daily-checkin` 接口领取当日积分 |
| 幂等重跑 | 今日已签到时接口返回业务码 `code=10001`，脚本视为「今日已签到」并按成功退出，可放心重复运行 |
| 本地日志 | 结果写入 `logs/checkin.log`，只含签到状态 / 积分 / 连续天数，不含令牌 |
| Telegram 推送（可选） | 签到流程结束后推送一条中文状态消息；未配置时不推送、不访问 Telegram |
| 定时运行 | 配合系统计划任务（任务计划程序 / launchd / crontab）实现每天多点补签，电脑任一时间点开机即可签上 |

**（做不到的事）**：

- 不提供账号登录、注册或代管；**必须本机 WorkBuddy 桌面端已登录过至少一次**，否则没有可读的令牌。
- 不修改 WorkBuddy 的任何文件与状态，不做 UI 自动化点击。
- 除腾讯官方签到接口外，仅当你自行启用推送时才访问 `api.telegram.org`，不向任何其他第三方上传数据。

---

## 2. 工作原理

0. **自动更新**：签到前脚本自动检查 skill 根目录是否为 git 仓库。是则 `git fetch` + 比较本地与远程，落后时 `git pull --ff-only` 拉取最新代码并重新执行脚本；非 git 仓库（压缩包安装等）静默跳过。设 `WB_CHECKIN_SKIP_UPDATE=1` 可跳过。网络超时 15 秒，超时或 pull 失败均不阻塞签到。

1. **登录态来源**：WorkBuddy 桌面端登录后把登录态保存在本机。
   - v5.3.8+（主路径）：明文 JSON 文件 `workbuddy-desktop.info`，内含 `account`、`auth.accessToken` 等，纯 Node 即可读取。
   - 旧版：Electron `safeStorage` 加密的 `state.vscdb`（需 Electron 运行时解密）。
2. **令牌形态**：v5.3.8 ~ 5.5.x 为明文 JWT 字符串；v5.6.2 起 `auth.accessToken` 变为 `$wbEncrypted` 信封对象（AES-256-GCM）。信封解密所需的静态钥编译在 WorkBuddy 定制 Electron 中，脚本以 `ELECTRON_RUN_AS_NODE=1`（纯 Node 模式，不启动 GUI）调用其原生绑定取得，再按官方 sym-v1 格式在本进程解密；**全程不硬编码任何密钥**。
3. **运行时策略**：**Node 优先**（读新版明文登录态，无需 Electron），缺失时回退 **Electron**（解旧版 `state.vscdb`）。
4. **调用官方接口**：
   - 查状态：`POST https://copilot.tencent.com/v2/billing/meter/checkin-status`
   - 执行签到：`POST https://copilot.tencent.com/v2/billing/meter/daily-checkin`
   - 认证：`Authorization: Bearer <accessToken>`，并按桌面端 `buildHeaders` 附带 `X-User-Id`（有 `auth.domain` 时加 `X-Domain`，企业账号另加 `X-Enterprise-Id` / `X-Tenant-Id`）。`checkin.ps1` 走 `/v2/` 全量签名，`checkin.sh` 走不带 `/v2/` 前缀的旧写法，两者实测均返回 200（网关当前未强制这些头，属前向兼容加固）。
5. **幂等实现**：脚本**不做**签到前预检（`checkin-status` 的 `today_checked_in` 字段实测不可靠，会产生假阳性导致漏签），而是直接调用幂等的 `daily-checkin`，以业务码 `code=10001` 兜底判定「今日已签到」。
6. **结果与日志**：脚本向 stdout 输出结论，同时追加写入 `logs/checkin.log`。

---

## 3. 环境要求与依赖

### 3.1 必须具备

| 组件 | 作用 | 获取方式 | 说明 |
|---|---|---|---|
| WorkBuddy 桌面端（**已登录**） | 提供本地登录态 | 官网：https://www.codebuddy.cn/work/ | 必须登录并打开过至少一次，否则无可读令牌 |
| Node.js（推荐 20+） | 读取 v5.3.8+ 明文登录态、解析 JSON（主路径） | nodejs.org 下载 LTS，或系统包管理器 | v5.3.8+ 用户必需；可用 `WB_CHECKIN_NODE=<node路径>` 指定 |
| curl / curl.exe | 调用签到 API 与 Telegram API | macOS / Linux 自带；Windows 10 1803+ 自带 `curl.exe` | 缺失时见 §10 排错 |

### 3.2 仅旧版账户需要

| 组件 | 作用 | 获取方式 | 说明 |
|---|---|---|---|
| Electron 运行时（≥ 30，推荐 37） | 仅旧版 `state.vscdb` 分支执行 `safeStorage.decryptString()` 解密令牌 | `scripts/setup.sh` / `scripts/setup.ps1`（`npm install electron@37`，约 100MB） | v5.3.8+ 新版账户**不需要**；旧版 CodeBuddy 用户需设 `WB_CHECKIN_APP_NAME=CodeBuddy` |

### 3.3 可选 / 回退依赖（缺失也能跑，只是走回退路径）

| 组件 | 缺失时的行为 |
|---|---|
| Node.js 内置 `node:sqlite` | 仅影响旧版分支读 `state.vscdb`，此时自动回退到 `python3` |
| `python3` | sh 版 JSON 解析降级为 `unknown`，签到请求仍会执行 |
| `npm` | 仅旧版 setup 自动下载 Electron 时需要；可手动放置 Electron 后用环境变量指定路径 |

> 新版明文分支为纯 JSON 文件读取，不涉及 sqlite；`python3` 回退默认关闭，需 `WB_CHECKIN_ALLOW_PY_FALLBACK=1` 才启用（缩小信任边界）。

### 3.4 平台差异速查

新版明文登录态（主路径）与旧版 `state.vscdb`（回退）均自动探测。

| 平台 | 运行脚本 | 新版登录态（v5.3.8+，主路径） | 旧版 `state.vscdb`（回退） |
|---|---|---|---|
| macOS | `scripts/checkin.sh` | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/Library/Application Support/WorkBuddy/User/globalStorage/state.vscdb` |
| Windows | `scripts/checkin.ps1`（Git Bash 下也可用 `checkin.sh`） | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`（回退 `%APPDATA%`） | `%APPDATA%\WorkBuddy\User\globalStorage\state.vscdb` |
| Linux | `scripts/checkin.sh` | `~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/.config/WorkBuddy/User/globalStorage/state.vscdb` |

> Windows / Linux 的新版路径由 v5.3.8 桌面端约定推导（macOS 已实测命中）；若你机器上路径不同，以实际安装为准。旧版 `state.vscdb` 分支在 Linux 需桌面会话 + 系统 keyring；新版明文分支无此要求。

### 3.5 网络要求

- 必须可访问 `https://copilot.tencent.com`（签到接口）。
- 仅旧版账户首次安装 Electron 时才需访问 `https://registry.npmjs.org`（或配置镜像）。
- 仅在启用 Telegram 推送时才需访问 `https://api.telegram.org`（详见 §6、§8）。

---

## 4. 安装与获取

### 4.1 用 git 获取（推荐）

```bash
git clone https://github.com/Serein1202/workbuddy-checkin.git
```

`git clone` 得到的是干净副本：`.gitignore` 已排除 `.env.local`、`logs/`、`.runtime/`、`node_modules/`，**不含任何凭据与本机日志**。

### 4.2 方式 A：交给 agent 安装（无需懂命令行）

**你不需要看懂命令行**：只要在对话框里把下面这句话发给你的 agent，它就会自行获取并安装本 skill（把 `<你的用户名>` 换成实际仓库地址中的用户名，本项目原始仓库地址见 §4.1）：

> 请帮我安装 workbuddy-checkin 这个 skill：从 https://github.com/Serein1202/workbuddy-checkin 获取，装好后按 SKILL.md 的「首次使用引导」问我是否需要 Telegram 推送，然后运行一次签到做验证。

- **安装完成后**：agent 会先查一次推送配置状态——未配置时会询问你是否要把签到结果推送到 Telegram（需要则引导你提供 Bot Token 与 chat id，流程见 §6.2）；已配置或你选择不推送时，直接进入签到。
- **若你拿到的是压缩包**：解压后即可使用（正常分发的包内不应包含 `.env.local` 与 `logs/`）。
- 目录放在任意位置均可：脚本内部用 `__dirname` / 脚本自身路径定位配置与依赖，**与工作目录无关**；建议放在纯英文、无空格的路径下，减少命令行转义问题。
- 安装路径示例（占位符）：`/path/to/workbuddy-checkin`（macOS / Linux）、`C:\path\to\workbuddy-checkin`（Windows）。

### 4.3 执行目录（重要）

**本文档中所有 `scripts/...` 相对路径命令，均须在 skill 根目录下执行**；否则会报 `Cannot find module .../scripts/xxx.js`。

- 从其他目录执行时，改用绝对路径，例如：`node /path/to/workbuddy-checkin/scripts/tg-config.js status --json`。
- Windows：`powershell -ExecutionPolicy Bypass -File C:\path\to\workbuddy-checkin\scripts\checkin.ps1`。
- 定时任务中的路径一律用**绝对路径**，不要依赖工作目录（见 §9）。

---

## 5. 快速开始

### 5.1 首次运行：环境检查

macOS / Linux / Git Bash：

```bash
bash /path/to/workbuddy-checkin/scripts/setup.sh
```

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\workbuddy-checkin\scripts\setup.ps1
```

setup 脚本会检测运行时（v5.3.8+ 只需 Node）并验证令牌链路。旧版账户若提示「未找到 Electron」，再执行同一脚本安装 Electron——**注意默认不自动下载**，需显式设 `WB_CHECKIN_AUTO_INSTALL_ELECTRON=1` 确认后才从官方 npm registry 下载 `electron@37`。

### 5.2 立即签到一次

macOS / Linux / Git Bash：

```bash
bash /path/to/workbuddy-checkin/scripts/checkin.sh
```

Windows（PowerShell）：

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\workbuddy-checkin\scripts\checkin.ps1
```

前提：本机已安装并**登录** WorkBuddy 桌面端，且已安装 Node.js。

### 5.3 看懂输出与退出码

- **退出码 `0`**：签到成功，或「今日已签到」（接口业务码 `code=10001`，属正常幂等结果）。
- **退出码非 `0`**：签到未成功，常见原因——令牌不可用（过期 / 未登录）、网络异常、响应解析失败。v5.6.2 信封解密相关的特定失败会以退出码 `7` 结束并给出确切原因（skill 1.0.6+）。
- 每次运行都会向 `logs/checkin.log` 追加一行结果（状态 / 积分 / 连续天数）。
- Telegram 推送是「尽力而为」：**推送成功与否都不改变退出码、不影响签到结果**。

---

## 6. Telegram 推送配置（可选，默认不推送）

### 6.1 默认状态与三态判定

**默认（未做任何配置）= 不推送**：脚本不会访问 Telegram，也不会影响签到。仅在「已启用」时才推送。

| 状态 | 判定条件 | 行为 |
|---|---|---|
| `unset` 未配置 | 未设 `WB_CHECKIN_TELEGRAM`，且 `TG_BOT_TOKEN` / `TG_CHAT_ID` 不齐全 | 只签到，不推送；由 agent 在首次使用时询问是否启用 |
| `enabled` 已启用 | `WB_CHECKIN_TELEGRAM` 为 `1` / `true` / `yes` / `on`；**或**未设开关但 Token + chat id 齐全（兼容旧配置） | 签到后推送 |
| `declined` 已拒绝 | `WB_CHECKIN_TELEGRAM` 为 `0` / `false` / `no` / `off` / `declined`（持久化） | 只签到，不推送且不再询问 |

`checkin.sh`、`checkin.ps1`、`scripts/tg-config.js` 三处判定完全一致。

### 6.2 方式 A：交给 agent 首次引导（推荐给 agent 安装场景）

首次在本机使用时，agent 会先执行只读状态查询，再决定是否打扰你：

```bash
node scripts/tg-config.js status --json
```

- `unset` → 询问你是否需要推送：需要则收集你的 **Bot Token** 与 **chat id**（必要时含代理）后执行：

  ```bash
  node scripts/tg-config.js set --token <Bot Token> --chat <chat id> [--proxy <你的代理地址>]
  ```

  `set` 会**先发一条测试消息，成功才写入配置**；失败会返回 `NETWORK` / `BAD_TOKEN` / `BAD_CHAT` 等原因码。
- 不需要推送 → 执行 `node scripts/tg-config.js decline`，持久化拒绝状态，之后不再询问。
- 已 `enabled` 或 `declined` → 直接签到，不询问、不改动既有配置。

获取凭据：在 Telegram 找 **@BotFather** 创建机器人拿到 **Bot Token**；chat id / user id 需先给该机器人发一条消息或 `/start`（私聊为数字 user id，群组为负数）。

### 6.3 方式 B：手工配置（复制 `.env.example`）

仓库自带模板 `.env.example`，**只含占位符、可安全分发**：

```bash
# macOS / Linux / Git Bash（在 skill 根目录执行）
cp .env.example .env.local
```

```powershell
# Windows PowerShell（在 skill 根目录执行）
Copy-Item .env.example .env.local
```

然后编辑 `.env.local`，去掉所需行行首的 `# ` 并填入**你自己的**值：

```ini
TG_BOT_TOKEN=<你的 Bot Token>
TG_CHAT_ID=<你的 chat id>
# TG_PROXY=<你的代理地址>
```

规则：

- 每行 `KEY=VALUE`；空行与 `#` 开头为注释；等号右侧不要加引号。
- 只识别 5 个白名单键，其余键与注释一律忽略；文件为**逐行解析**（不做 `source` / `Invoke-Expression`），**不会执行任何代码**。
- `.env.local` 已被 `.gitignore` 忽略，**切勿提交或分享**。
- 设 `WB_CHECKIN_TELEGRAM=1` 显式启用，或直接留空（凭据齐全即视为启用）。

### 6.4 方式 C：环境变量

适合临时验证，**优先级高于 `.env.local`**：

```bash
export TG_BOT_TOKEN="<你的 Bot Token>"
export TG_CHAT_ID="<你的 chat id>"
# export TG_PROXY="<你的代理地址>"
```

```powershell
$env:TG_BOT_TOKEN = "<你的 Bot Token>"
$env:TG_CHAT_ID   = "<你的 chat id>"
```

### 6.5 验证与关闭

```bash
node scripts/tg-config.js status                       # 查看状态（只报已配置/缺失，绝不回显凭据值）
node scripts/tg-config.js test                         # 用当前凭据发一条测试消息
node scripts/tg-config.js test --proxy <你的代理地址>    # 临时用指定代理测试
node scripts/tg-config.js decline                      # 关闭推送并持久化「已拒绝」
```

推送消息内容只含签到状态、`credit`、`streak_days`、HTTP 状态码与失败原因，**绝不含 `accessToken` 或任何凭据**。

---

## 7. 配置项与环境变量总表

| 变量 | 作用 | 默认 / 备注 |
|---|---|---|
| `TG_BOT_TOKEN` | Telegram Bot Token（用户自备，禁止编造或用示例值） | 未配置即不推送 |
| `TG_CHAT_ID` | 接收消息的 chat id / user id（用户自备） | 未配置即不推送 |
| `TG_PROXY` | 访问 Telegram 的代理地址 | 未设置时回退 `HTTPS_PROXY` / `ALL_PROXY` / `HTTP_PROXY`（含小写）；详见 §8 |
| `WB_CHECKIN_TELEGRAM` | 推送开关（三态落点） | 未设置＝按凭据判断；`1`/`true`/`yes`/`on` 启用；`0`/`false`/`no`/`off`/`declined` 已拒绝 |
| `WB_CHECKIN_TG_TIMEOUT` | 推送请求超时（秒） | `10` |
| `WB_CHECKIN_NODE` | 指定 Node 二进制路径 | 自动探测 |
| `WB_CHECKIN_WORKBUDDY_BIN` | 指定 WorkBuddy 主程序路径（v5.6.2+ 信封解密取静态钥用） | 自动探测失败时设置 |
| `WB_CHECKIN_ELECTRON` | 指定 Electron 二进制路径（仅旧版 `state.vscdb` 分支，sh 版） | 旧版账户按需 |
| `-ElectronPath <path>` | 同上（ps1 版参数） | 旧版账户按需 |
| `WB_CHECKIN_APP_NAME` | 兼容旧版应用名，设 `CodeBuddy`（仅旧版 `state.vscdb` 分支的 macOS 钥匙串密钥） | 未设置 |
| `WB_CHECKIN_JITTER` | 启动前随机等待 0~N 秒，避免整点风暴 | 未设置时不启用 |
| `WB_CHECKIN_ALLOW_PY_FALLBACK` | 设 `1` 才允许旧版分支回退调用外部 `python3` | 关闭（缩小信任边界） |
| `WB_CHECKIN_AUTO_INSTALL_ELECTRON` | 设 `1` 才允许 setup 自动从官方 npm registry 下载 `electron@37` | 关闭（避免静默引入大二进制） |
| `HTTPS_PROXY` / `ALL_PROXY` / `HTTP_PROXY`（含小写） | Telegram 代理的回退来源 | 仅在未设 `TG_PROXY` 时参考 |

完整依赖与平台差异另见 `references/dependencies.md`。

---

## 8. 代理配置说明与限制

- **仅作用于 Telegram 推送**：`TG_PROXY`（及其回退变量）只用于访问 `api.telegram.org`；**签到请求 `copilot.tencent.com` 不受其影响**。
- **取值优先级**：`TG_PROXY` → `HTTPS_PROXY` → `ALL_PROXY` → `HTTP_PROXY`（后三者含小写写法）。
- **都未设置时**：PowerShell 版沿用系统（IE 选项）代理设置，Git Bash 版交由 `curl` 自身处理。
- **限制**：若本机无法直连 `https://api.telegram.org` 又未配置代理，推送会失败——签到日志中会留一行**不含凭据**的提示（签到本身不受影响）；此时用 `node scripts/tg-config.js test --proxy <你的代理地址>` 验证，成功后用 `set --proxy <你的代理地址>` 写回配置。
- 代理串属于本机配置信息：`tg-config.js status` 在代理串含认证信息时会打码，本文档也不应填写真实代理地址。

---

## 9. 定时运行方案

脚本幂等，重复运行无副作用；推荐在 `09:00 / 12:00 / 15:00 / 18:00 / 21:00` 各尝试一次，只要能开机一次即可签上。**以下路径请全部替换为绝对路径。**

### 9.1 Windows（任务计划程序）

```powershell
schtasks /Create /TN WorkBuddyDailyCheckin /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\workbuddy-checkin\scripts\checkin.ps1" /SC DAILY /ST 09:00 /F
schtasks /Create /TN WorkBuddyDailyCheckin2 /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\workbuddy-checkin\scripts\checkin.ps1" /SC DAILY /ST 12:00 /F
```

`schtasks` 单任务只支持一个 `/ST`，多时间点需建多个任务（示例中另建 `...2`）。

### 9.2 macOS（launchd）

创建 `~/Library/LaunchAgents/com.user.workbuddy-checkin.plist`，用 `StartCalendarInterval` 数组配置多个时间点：

```xml
<key>ProgramArguments</key>
<array>
  <string>/bin/bash</string>
  <string>/path/to/workbuddy-checkin/scripts/checkin.sh</string>
</array>
<key>StartCalendarInterval</key>
<array>
  <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
</array>
```

```bash
launchctl load ~/Library/LaunchAgents/com.user.workbuddy-checkin.plist
```

### 9.3 Linux / macOS（crontab）

```bash
crontab -e
0 9,12,15,18,21 * * * /path/to/workbuddy-checkin/scripts/checkin.sh >> /path/to/workbuddy-checkin/logs/checkin.log 2>&1
```

### 9.4 在 WorkBuddy 内（Agent 自动化）

也可用 WorkBuddy 的自动化任务（recurring）驱动，RRULE 多值 `BYHOUR` 可用：

```jsonc
{
  "name": "WorkBuddy 每日积分签到",
  "scheduleType": "recurring",
  "rrule": "FREQ=DAILY;BYHOUR=9,12,15,18,21;BYMINUTE=0;BYSECOND=0",
  "cwds": ["<你的工作目录>"],
  "status": "ACTIVE",
  "prompt": "运行 checkin 脚本（macOS/Linux 用 bash scripts/checkin.sh，Windows 用 powershell -ExecutionPolicy Bypass -File scripts\\checkin.ps1）。脚本幂等，今日已签到会直接跳过。读取输出并汇报：签到成功领取多少积分 / 今日已签到 / 令牌失效需打开 WorkBuddy 刷新。"
}
```

---

## 10. 常见问题与排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `Cannot find module .../scripts/xxx.js` | 不在 skill 根目录执行相对路径命令 | `cd` 到 skill 根目录，或改用绝对路径（见 §4.3） |
| 「获取令牌失败（未知原因）」/ 未找到本地登录态 | 桌面端未登录、从未打开，或 skill 版本过旧（< 1.0.2 不识别 v5.3.8 新版明文存储） | 打开并登录 WorkBuddy 客户端后重试；升级 skill 到 1.0.2+；用 `node -v` 确认 Node 可用，或 `WB_CHECKIN_NODE` 指定 |
| 提示「未找到 Node 或 Electron 运行时」但 `node -v` 正常 | Git Bash 下 MSYS 路径（`/c/...`）被拼成 `C:\c\Users\...`（1.0.4 已修复） | 升级到 1.0.4+；或直接运行 `node "<skill绝对路径>/scripts/decrypt-token.js"` 查看真实报错 |
| 持续 401 令牌过期 | 登录态过期；或读到了过期的历史会话令牌（1.0.3 前 Windows 只探 `%APPDATA%`） | 打开 WorkBuddy 刷新登录态（脚本每次运行都会重读最新 token，次日自动恢复）；升级到 1.0.3+ |
| 报「无法从 WorkBuddy 定制 Electron 获取静态钥」 | v5.6.2+ 信封解密需定位桌面端主程序 | 用 `WB_CHECKIN_WORKBUDDY_BIN=<主程序路径>` 指定；若报「静态钥与信封 keyId 不匹配」说明官方已更换加密方案，请提 issue |
| 升级 5.6.2+ 后报「未找到新版明文认证文件」 | 桌面端把 `accessToken` 改为信封加密（skill < 1.0.6 不支持） | 升级 skill 到 1.0.6+ |
| 当日重跑提示「签到未成功 / code=10001」 | skill < 1.0.2 未把 `code=10001` 识别为已签到 | 升级到 1.0.2+ |
| 提示 curl 缺失（`CURL_MISSING`） | 系统无 curl | macOS / Linux 装 `curl`；Windows 10 1803+ 自带 `curl.exe`，确认 `PATH` 可见 |
| 重复签到返回 HTTP 400 | **正常行为**（首次签到为 200，重复时业务体为 `code=10001`） | 无需处理，脚本已按成功判定 |
| 推送收不到消息 | 未配置 / 已拒绝 / 凭据不全 / 代理不通 / chat id 错误 | 依次检查：`node scripts/tg-config.js status` 看状态 → 若为 `declined` 先 `set` 重新启用 → `test` 验证连通性 → 不通则加 `--proxy`；日志出现「Telegram 推送已启用但凭据缺失」「Telegram 推送发送失败」即对应这两种情况 |
| 收不到消息但签到正常 | 推送失败不影响签到（设计如此） | 按上一行排查推送本身 |
| 日志乱码 / PS 5.1 报「意外的标记 }」 | Windows 旧版编码问题（1.0.4 已修复：补 UTF-8 BOM、调用 curl 期间临时切 UTF-8） | 升级到 1.0.4+ |
| macOS 旧版账户解密报错 | 旧版迁移应用名仍为 `CodeBuddy` | `export WB_CHECKIN_APP_NAME=CodeBuddy` 后重试 |
| Electron 下载慢 / 失败（旧版账户） | 网络问题 | 配置 npm/Electron 镜像后重跑 setup，或手动放置 Electron 并用 `WB_CHECKIN_ELECTRON` / `-ElectronPath` 指定 |

---

## 11. 安全与隐私说明

- **令牌即账号凭证**：解出的 `accessToken` 等同你的 WorkBuddy 账号密码，仅在脚本内存中使用，经管道立即被签到请求消费，**不写入日志、不落盘、不回显终端、不提交仓库**。
- **日志不含令牌**：`logs/` 仅记录签到结果（状态 / 积分 / 连续天数），绝不含令牌原文；仍不建议把日志或脚本输出粘贴分享。
- **网络访问范围**：默认仅访问腾讯官方接口 `copilot.tencent.com/billing/meter/*` 与 `copilot.tencent.com/v2/billing/meter/*`。**仅当推送处于「已启用」**（显式 `WB_CHECKIN_TELEGRAM=1`，或未设开关但 `TG_BOT_TOKEN` + `TG_CHAT_ID` 齐全）时，才会额外向 `api.telegram.org` 发送一条签到状态消息（首次配置时发一条测试消息）；状态为「未配置」或「已拒绝」时完全不访问该域名。
- **凭据存放**：只从环境变量或 skill 根目录 `.env.local` 读取（环境变量优先）；该文件已被 `.gitignore` 忽略。读取为逐行字符串提取（不做 `source` / `Invoke-Expression`），**不会执行文件中任何代码**。
- **配置助手不泄密**：`scripts/tg-config.js` 只动 `.env.local` 的白名单键（就地更新、保留其余内容与注释），**从不回显凭据值**，代理串含认证信息时打码，也不把凭据写入任何其他位置。
- **推送内容**：只含签到状态与结果字段，绝不含 `accessToken` 或任何凭据；请求设超时，失败不重试、不阻塞。
- **环境变量读取范围**：`WB_CHECKIN_*`（路径 / 应用名 / 错峰 / 回退开关 / 推送开关与超时）与 `TG_BOT_TOKEN` / `TG_CHAT_ID` / `TG_PROXY`（并回退 `HTTPS_PROXY` / `ALL_PROXY` / `HTTP_PROXY` 及小写形式）。
- **本地写入范围**：仅 `.env.local`（由 `tg-config.js set` / `decline` 写入）与 `logs/checkin.log`；**不修改 WorkBuddy 任何文件**。
- **供应链**：默认不自动下载 Electron；`WB_CHECKIN_AUTO_INSTALL_ELECTRON=1` 时才从官方 npm registry 下载 `electron@37`。
- 请勿用于他人账户、批量注册刷分或任何违反 WorkBuddy 用户协议的用途，使用者自行承担风险。

---

## 12. 分发前必读：请勿分发本机凭据文件

**`.env.local` 与 `logs/` 只属于本机，切勿随 skill 分发给他人。**

| 文件 / 目录 | 内容 | 说明 |
|---|---|---|
| `.env.local` | 本机 Telegram Bot Token、chat id、代理地址 | 已被 `.gitignore` 忽略，但**整目录拷贝 / 压缩包 / 聊天传文件夹分发时仍会被一并带走** |
| `logs/` | 本机签到日志（含签到时间） | 同上，仅本机运行记录，无分享价值 |
| `.env.example` | 仅占位符的配置模板 | **可以分发**，接收方复制为 `.env.local` 后填自己的凭据 |

**正确的分发方式**（任选其一）：

1. **推荐：用 git 仓库分发**（接收方 `git clone`）。`.gitignore` 会自动排除 `.env.local`、`logs/`、`.runtime/`、`node_modules/`。
2. **必须打包整个目录时**：先删除 `.env.local` 与 `logs/` 再打包，并在打包后自检：

   ```powershell
   Get-ChildItem -Force    # 确认列表中不存在 .env.local
   ```

3. 接收方如需 Telegram 推送，复制 `.env.example` 为 `.env.local` 并填入**自己的**凭据（见 §6.3）。

> **凭据泄露后的处置**：立即在 Telegram 找 **@BotFather** 执行 `/revoke`（或 `/token`）重新签发 Bot Token，作废已泄露的 Token；随后清理已分发副本中的旧 Token，并更新本机 `.env.local`，最后用 `node scripts/tg-config.js test` 验证。签到的 `accessToken` 无法吊销，若怀疑其泄露，请直接在 WorkBuddy 客户端重新登录以刷新登录态。

---

## 13. 目录结构

```
workbuddy-checkin/
├── LICENSE                     # MIT
├── README.md                   # 本文档
├── SKILL.md                    # skill 定义与完整说明（首次引导 / 配置三态 / 排错 / 安全）
├── CHANGELOG.md                # 版本变更记录
├── .gitattributes              # 强制 *.sh 使用 LF 行尾
├── .gitignore                  # 忽略 logs/、.env*（例外 .env.example）、运行时产物
├── .env.example                # Telegram 推送配置模板（仅占位符，可分发）
├── references/
│   └── dependencies.md         # 依赖清单与平台差异
├── scripts/
│   ├── checkin.sh              # macOS / Linux / Git Bash 签到入口
│   ├── checkin.ps1             # Windows PowerShell 签到入口
│   ├── decrypt-token.js        # 读取 / 解密本机登录态（跨平台）
│   ├── tg-config.js            # Telegram 推送配置助手（status / set / test / decline）
│   ├── setup.sh                # macOS / Linux 环境检查
│   └── setup.ps1               # Windows 环境检查
├── logs/                       # 运行后自动创建（已忽略，勿分发）
└── .env.local                  # 运行后按需创建（已忽略，勿分发）
```

---

## 14. 许可

本项目基于 **MIT License** 开源，Copyright (c) 2026 Cx330，详见 [LICENSE](LICENSE)。