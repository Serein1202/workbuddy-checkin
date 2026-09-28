---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: c24c66f571a941975f0cfa91c4043623_bee8bd0ebb3411f19ba1525400638852
    ReservedCode1: w32cN2+MYQ10A8nCxWsBL5QnvgDN8tXWxZkCl9G3e3FNci1vzwXeiogphBGipNbit2ss4K030K+EJ2HRXIhBYOMwKSe+YtHu8C/EoRGHAyrEhnaCAmgqmhiXF0dQTDgEFQ5CDXEZ0WfSZ8J6EVtwUQ2djrHUpGCO8zRWKtZKdsQcAzOrT7nri6GPFaA=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: c24c66f571a941975f0cfa91c4043623_bee8bd0ebb3411f19ba1525400638852
    ReservedCode2: w32cN2+MYQ10A8nCxWsBL5QnvgDN8tXWxZkCl9G3e3FNci1vzwXeiogphBGipNbit2ss4K030K+EJ2HRXIhBYOMwKSe+YtHu8C/EoRGHAyrEhnaCAmgqmhiXF0dQTDgEFQ5CDXEZ0WfSZ8J6EVtwUQ2djrHUpGCO8zRWKtZKdsQcAzOrT7nri6GPFaA=
name: workbuddy-checkin
description: "WorkBuddy 每日积分自动签到技能：复用本机 WorkBuddy 桌面端已登录的登录态，直接调用腾讯官方签到接口领取每日积分（每日 100 积分，连续第 7 天 1000 积分），全程在本机完成、无后端服务、无模拟点击、不启动 GUI。当用户提到 WorkBuddy 签到 / 每日积分 / 打卡、需要批量签到、查询签到状态或签到历史，或需要配置 Windows 计划任务、Unix cron / launchd 实现定时或开机自动签到时使用。"
---







# WorkBuddy 每日积分签到

自动领取 WorkBuddy 每日积分（100 积分/天，连续第 7 天 1000 积分）。
全流程在本机完成：签到前自动检查并拉取远程更新（git 仓库时）→ 读取本地登录态 → 调用腾讯官方签到接口。无后端服务。

## 原理

0. 自动更新：签到主流程开始前，脚本检查 skill 根目录是否为 git 仓库。是则 `git fetch` + 比较本地与远程，落后时 `git pull --ff-only` 拉取最新代码并重新执行脚本；非 git 仓库（压缩包安装等）静默跳过。设 `WB_CHECKIN_SKIP_UPDATE=1` 可跳过。网络超时 15 秒，超时或 pull 失败均不阻塞签到、不影响退出码与日志格式。

1. WorkBuddy 桌面端登录后，会在本地保存登录态。**v5.3.8+ 的新版桌面端**使用 JSON 文件：
   - macOS：`~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info`
   - 结构 `{ account, auth: { accessToken, refreshToken, expiresAt, ... }, accounts }`，桌面端临近过期会自动刷新。
2. **accessToken 存储形态按版本分两种**（1.0.6 起均支持）：
   - **v5.3.8 ~ 5.5.x：明文字符串**，纯 Node 直接读取；
   - **v5.6.2+：`$wbEncrypted` 信封对象**（`{ $wbEncrypted: 1, envelope }`，AES-256-GCM）。解密所需的对称静态钥编译在 WorkBuddy 定制 Electron 里，脚本以 `ELECTRON_RUN_AS_NODE=1`（纯 Node 模式，不启动 GUI）调用其原生绑定 `workbuddyStorage.loggerGet()` 取得，再按官方 `AtRestCrypto` sym-v1 格式（sha256 派生密钥 + 域分离 AAD）在本进程完成解密。全程跟随官方密钥管理，不硬编码任何密钥。
3. **旧版 WorkBuddy/CodeBuddy** 仍把 auth session 用 Electron `safeStorage` 加密存于 `state.vscdb`；新版登录态文件缺失时回退到此路径，用 Electron 运行时执行 `safeStorage.decryptString()` 解密（macOS 命中钥匙串；Windows/Linux 走 DPAPI/keyring）。
4. 运行时策略：**Node 优先**（读新版登录态文件，无需 Electron），缺失时回退 Electron（解旧版 `state.vscdb`）。信封解密用的 WorkBuddy 二进制在已安装桌面端的机器上自动定位。
5. 调用腾讯官方签到 API：
   - 查状态：`POST https://copilot.tencent.com/v2/billing/meter/checkin-status`
   - 执行签到：`POST https://copilot.tencent.com/v2/billing/meter/daily-checkin`
   - 认证：`Authorization: Bearer <accessToken>`，并按桌面端 `buildHeaders` 附带 `X-User-Id: <account.uid>`；有 `auth.domain` 时加 `X-Domain`，企业账号另加 `X-Enterprise-Id` / `X-Tenant-Id`
   - 兼容说明：`checkin.ps1` 走上述 `/v2/` 全量签名（对齐桌面端）；`checkin.sh` 仍走不带 `/v2/` 前缀、仅 `Authorization` 的旧写法。**两种写法实测均返回 200**（见 CHANGELOG 1.0.3 的验证矩阵），网关当前未强制 `/v2/` 或 `X-User-Id`；对齐桌面端属前向兼容加固，不是修复 401 的必要条件
6. 脚本幂等：直接调用 `daily-checkin`（不再预查 `checkin-status`）。`daily-checkin` 返回 `code=10001`（今天已签到）视为成功；`today_checked_in` 字段不可靠，预查反而会在假阳性时漏签、中断连续签到。

> ⚠️ v5.3.8 实测 `checkin-status` 的 `today_checked_in` 字段不可靠（签到成功后仍可能为 `false`），原计划用于预查跳过的逻辑已移除；幂等性完全依赖 `daily-checkin` 的 `code=10001` 兜底。

兼容旧版应用名 `CodeBuddy`（仅旧版 `state.vscdb` 分支需要，macOS 需设环境变量 `WB_CHECKIN_APP_NAME=CodeBuddy`）。

## 文件结构

```
workbuddy-checkin/
├── .gitignore                  # 忽略 logs/、运行时产物与本地凭据文件
├── .env.example                # Telegram 推送配置模板（复制为 .env.local 后填写，可安全分发）
├── SKILL.md
├── references/
│   └── dependencies.md         # 依赖清单与平台差异
└── scripts/
    ├── decrypt-token.js        # 解密令牌（跨平台）
    ├── checkin.sh              # macOS / Linux / Git Bash
    ├── checkin.ps1             # Windows PowerShell
    ├── tg-config.js            # Telegram 推送配置助手（状态查询 / 写入 / 测试 / 拒绝）
    ├── setup.sh                # macOS / Linux 一键安装
    └── setup.ps1               # Windows 一键安装
```

`logs/` 目录运行后自动创建，存放签到日志（已在 `.gitignore` 中忽略）。

## 依赖

### 系统依赖

| 依赖 | 用途 | 安装方式 |
|------|------|----------|
| WorkBuddy 桌面端（已登录） | 提供本地登录态（v5.3.8+ 明文文件 / 旧版 `state.vscdb`） | 官网下载，必须登录过至少一次 |
| Node.js（推荐 20+，v5.3.8+ 主路径必需） | 读取新版明文登录态、解析 JSON | nodejs.org 下载，或系统包管理器 |
| curl（macOS/Linux 自带）/ curl.exe | 调用签到 API | Windows 10 1803+ 自带 |
| Electron 运行时（≥ 30，推荐 37） | **仅旧版** `state.vscdb` 分支解密令牌用 | 仅旧版账户需要，运行 `scripts/setup.sh` 或 `setup.ps1` |

> v5.3.8+ 用户：装好 Node.js 并登录桌面端即可直接签到，**无需安装 Electron**。Electron 仅用于尚未迁移到新版明文存储的旧版 WorkBuddy/CodeBuddy 账户。

### 开箱即用 vs 需安装

- **开箱即用（v5.3.8+）**：已装 WorkBuddy 桌面端并登录 + 系统已有 Node.js → 直接运行签到脚本。
- **需安装 Node.js**：提示「未找到 Node」时，到 nodejs.org 安装，或用 `WB_CHECKIN_NODE=<path>` 指定。
- **旧版账户需 Electron**：使用旧版 WorkBuddy/CodeBuddy（`state.vscdb`）且提示「未找到 Electron」时，执行：

  ```bash
  # macOS / Linux
  bash scripts/setup.sh
  # Windows（PowerShell）
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
  ```

### 可选 / 回退依赖

| 依赖 | 缺失时行为 |
|------|------------|
| Electron 运行时 | 仅旧版 `state.vscdb` 账户需要；v5.3.8+ 新版明文路径不需要 |
| Node.js 内置 `node:sqlite`（Electron 37 / Node 22+ 自带） | 旧版分支自动回退到 `python3` 读取 sqlite |
| `python3` | sh 版 JSON 解析降级为 `unknown`，签到请求仍会执行 |
| `npm`（仅旧版 setup 首次安装 Electron 用） | 手动放置 Electron 后用 `WB_CHECKIN_ELECTRON=<path>`（sh）/ `-ElectronPath <path>`（ps1）指定 |

完整依赖说明见 `references/dependencies.md`。

## 执行目录说明（先读）

**本文档内所有 `scripts/...` 命令，均须在 skill 根目录下执行**（即包含 `SKILL.md` 与 `scripts/` 的那个目录）。

- 用 agent 安装分发时，agent 的实际工作目录未必是 skill 根目录，直接照抄文档中的相对路径命令可能报 `Cannot find module .../scripts/xxx.js`。此时请先 `cd` 到 skill 根目录，或把命令中的相对路径换成绝对路径，例如：`node <skill根目录>/scripts/tg-config.js status --json`。
- Windows 同理：`powershell -ExecutionPolicy Bypass -File scripts\checkin.ps1` 需在 skill 根目录执行，或写成 `powershell -ExecutionPolicy Bypass -File <skill根目录>\scripts\checkin.ps1`。
- 定时任务（crontab / 任务计划程序 / launchd）中的脚本路径请一律使用**绝对路径**，不要依赖工作目录。

## 快速开始

macOS / Linux：
```bash
bash scripts/setup.sh     # 检测运行时并验证令牌链路（v5.3.8+ 用 Node，旧版才需 Electron）
bash scripts/checkin.sh   # 立即签到一次（验证）
```

Windows（PowerShell）：
```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
powershell -ExecutionPolicy Bypass -File scripts\checkin.ps1
```

前提：本机已安装并**登录** WorkBuddy 桌面端；系统已安装 Node.js（v5.3.8+ 主路径）。

## 首次使用引导（把 skill 分发给他人时必做）

> **执行位置**：本章所有 `node scripts/tg-config.js ...` 命令均须在 **skill 根目录**下执行；若工作目录不确定，请改用绝对路径 `node <skill根目录>/scripts/tg-config.js ...`。

首次在本机使用时，**agent 必须先查询推送配置状态，再决定是否询问用户**，已配置或已拒绝都不要再打扰：

1. **查询状态**（只读，先跑这个）：

   ```bash
   node scripts/tg-config.js status --json
   ```

2. **按返回的 `state` 字段分支**：

   | `state` | 含义 | agent 动作 |
   |---------|------|-----------|
   | `unset` | 未配置（无开关、无凭据） | 询问用户是否需要 Telegram 推送（话术见下）；需要则收集凭据并配置；不需要则记录拒绝 |
   | `enabled` | 已启用（含无显式开关但凭据齐全的旧配置） | **直接签到**，不询问、不改动既有配置 |
   | `declined` | 已拒绝 | **直接签到**，不再询问；除非用户主动要求开启 |

3. **询问话术模板**（仅 `unset` 时使用；凭据只能由用户提供，**严禁编造、猜测或用示例值代替**）：

   > 是否需要在每天签到后，把签到结果（是否成功、领取积分、连续天数）推送到你的 Telegram？
   > - **需要**：请提供 ① 在 Telegram 找 **@BotFather** 创建机器人后拿到的 **Bot Token**；② 接收消息的 **chat id / user id**（先给该机器人发一条消息或 `/start`；私聊用数字 user id，群组为负数）。若本机无法直连 Telegram，还需你的**代理地址**（例如 `http://127.0.0.1:7890`）。
   > - **不需要**：我直接签到，之后也不会再问。

4. **用户选择「需要」**：拿到 Token、chat id（必要时含代理）后执行配置（脚本会自动发测试消息，**成功才落盘**）：

   ```bash
   node scripts/tg-config.js set --token <Bot Token> --chat <chat id> [--proxy <代理地址>]
   ```

   - 返回 `ok: true` → 告知用户「配置成功，测试消息已发送，请到 Telegram 确认」。
   - 返回 `NETWORK` → 说明本机连不上 `api.telegram.org`，请用户提供代理后加 `--proxy` 重试；若用户没有代理或不想折腾，询问是否**放弃推送**，确认后执行 `decline`。
   - 返回 `BAD_TOKEN` / `BAD_CHAT` / `INVALID_TOKEN` / `INVALID_CHAT` → 请用户核对 Token 或 chat id 后重试，**不要**改写凭据；若用户坚持先写入，可用 `--no-test`（不推荐，需告知推送可能失败）。
   - 用户中途放弃 → 执行 `node scripts/tg-config.js decline`。

5. **用户选择「不需要」**：持久化拒绝状态（之后签到不再询问）：

   ```bash
   node scripts/tg-config.js decline
   ```

6. **引导完成后照常签到**：`bash scripts/checkin.sh`（Windows：`powershell -ExecutionPolicy Bypass -File scripts\checkin.ps1`），按原有规则汇报签到结果。

> 关键约束：`enabled` 与 `declined` 两种状态都必须「直接签到、不再询问」；绝不可因为"用户可能想要推送"而覆盖既有配置或重发测试消息。

## 设置定时任务

电脑非全天开机时，建议配置多个时间点补签（脚本幂等，重复运行无副作用）。推荐 `09:00 / 12:00 / 15:00 / 18:00 / 21:00` 各尝试一次，只要电脑在任一时间点开机就能签上。

### macOS / Linux（crontab）
```bash
crontab -e
0 9,12,15,18,21 * * * /path/to/scripts/checkin.sh >> /path/to/logs/checkin.log 2>&1
```

### Windows（任务计划程序）
```powershell
schtasks /Create /TN WorkBuddyDailyCheckin /TR "powershell -ExecutionPolicy Bypass -File C:\path\checkin.ps1" /SC DAILY /ST 09:00 /F
schtasks /Create /TN WorkBuddyDailyCheckin2 /TR "powershell -ExecutionPolicy Bypass -File C:\path\checkin.ps1" /SC DAILY /ST 12:00 /F
# （schtasks 单任务只支持一个 /ST，多时间点需建多个任务）
```

### macOS launchd（长期后台）

创建 `~/Library/LaunchAgents/com.user.workbuddy-checkin.plist`，`StartCalendarInterval` 用数组配置多时间点：
```xml
<key>StartCalendarInterval</key>
<array>
  <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>0</integer></dict>
  <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
</array>
```
然后 `launchctl load ~/Library/LaunchAgents/com.user.workbuddy-checkin.plist`。

### 在 WorkBuddy 内（Agent 自动化）

WorkBuddy 环境下可调用自动化任务工具（`automation_update`，recurring 类型），RRULE 多值 `BYHOUR` 实测生效：
```jsonc
{
  "name": "WorkBuddy 每日积分签到",
  "scheduleType": "recurring",
  "rrule": "FREQ=DAILY;BYHOUR=9,12,15,18,21;BYMINUTE=0;BYSECOND=0",
  "cwds": ["<用户工作目录>"],
  "status": "ACTIVE",
  "prompt": "运行 Bash 脚本 scripts/checkin.sh（Windows 用 checkin.ps1）。该脚本幂等：今日已签到会直接跳过。读取输出并汇报：签到成功领取多少积分 / 今日已签到 / 令牌失效需打开 WorkBuddy 刷新。"
}
```
> 注意：`update` 已有任务时必须显式传 `rrule`，否则可能被重置；`cwds` 不能用 Claw 工作区。

## 平台说明

新版登录态文件（v5.3.8+，主路径：明文 / v5.6.2+ 信封，Node 读取）与旧版 `state.vscdb`（回退路径，Electron 解密）均自动探测。

| 平台 | 脚本 | 新版登录态文件（v5.3.8+，主路径） | 旧版 state.vscdb（回退） |
|---|---|---|---|
| macOS | `checkin.sh` | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/Library/Application Support/WorkBuddy/User/globalStorage/state.vscdb` |
| Windows | `checkin.ps1`（或 Git Bash 跑 `checkin.sh`） | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info`（回退 `%APPDATA%`） | `%APPDATA%\WorkBuddy\User\globalStorage\state.vscdb` |
| Linux | `checkin.sh` | `~/.config/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/.config/WorkBuddy/User/globalStorage/state.vscdb` |

Windows PowerShell 执行策略用 `-ExecutionPolicy Bypass`；需 `curl.exe`（Win10 1803+ 自带）。
旧版 `state.vscdb` 分支在 Linux 需桌面会话 + 系统 keyring（GNOME Keyring / KWallet）；新版明文分支无此要求。

## 环境变量

| 变量 | 作用 |
|------|------|
| `WB_CHECKIN_NODE=<path>` | 指定 Node 二进制路径（v5.3.8+ 主路径用，sh/ps1 通用） |
| `WB_CHECKIN_WORKBUDDY_BIN=<path>` | 指定 WorkBuddy 桌面端主程序路径（v5.6.2+ 信封解密取静态钥用；自动探测失败时设置） |
| `WB_CHECKIN_ELECTRON=<path>` | 指定 Electron 二进制路径（仅旧版 state.vscdb 回退用，sh 版） |
| `-ElectronPath <path>` | 同上（ps1 版参数） |
| `WB_CHECKIN_APP_NAME=CodeBuddy` | 兼容旧版应用名（仅旧版 state.vscdb 分支的 macOS 钥匙串密钥） |
| `WB_CHECKIN_JITTER=<秒>` | 启动前随机等待 0~N 秒，避免整点风暴 |
| `WB_CHECKIN_SKIP_UPDATE=1` | 跳过签到前的自动更新检查（git 仓库时默认在签到前 fetch + pull 最新代码，pull 成功后重新执行脚本；非 git 仓库静默跳过；网络超时 15 秒，失败不阻塞签到） |
| `WB_CHECKIN_TELEGRAM=<0/1>` | Telegram 推送开关（**三态标记**）：未设置时按凭据判断（凭据齐全即视为已启用）；显式设为 `0` / `false` / `no` / `off` / `declined` 表示**已拒绝**（直接签到、不再询问）；设为 `1` / `true` / `yes` / `on` 表示已启用 |
| `TG_BOT_TOKEN=<token>` | Telegram 机器人 Token（**用户自备**，禁止编造或使用示例值；未配置时不会联网推送） |
| `TG_CHAT_ID=<id>` | 接收消息的对话 ID（**用户自备**，禁止编造或使用示例值；未配置时不会联网推送） |
| `TG_PROXY=<url>` | 访问 Telegram 的代理，如 `http://127.0.0.1:7890`；未设置时回退 `HTTPS_PROXY` / `ALL_PROXY` / `HTTP_PROXY`（含小写） |
| `WB_CHECKIN_TG_TIMEOUT=<秒>` | Telegram 推送请求超时，默认 `10` 秒 |

## Telegram 推送（可选）

签到流程结束（成功 / 今日已签 / 令牌过期或无权限 / 网络异常 / 其他失败 / 解析异常）后，可自动向你的 Telegram 机器人推送一条中文状态消息，内容含签到状态、`credit`、`streak_days`、HTTP 状态码与失败原因。**凭据由用户自备，经环境变量或本地配置文件注入，代码中不硬编码任何 Token。首次使用时的完整引导流程见上文「首次使用引导」章节。**

### 用辅助脚本配置（推荐）

`scripts/tg-config.js` 是跨平台的推送配置助手（Node，Windows / macOS / Linux 通用），供 agent 与用户直接调用：

```bash
node scripts/tg-config.js status --json   # 查看配置状态（三态）；--json 便于 agent 解析
node scripts/tg-config.js test            # 用当前（或临时指定）凭据发一条测试消息
node scripts/tg-config.js set --token <Bot Token> --chat <chat id> [--proxy <代理地址>]
node scripts/tg-config.js decline         # 记录「不需要推送」（持久化，之后签到不再询问）
```

- `set` **默认先发一条测试消息，成功才写入配置**（避免把错的 Token 或不可达的代理写进文件）；确需离线写入可加 `--no-test`（不建议）。
- 写入键：`TG_BOT_TOKEN`、`TG_CHAT_ID`、`WB_CHECKIN_TELEGRAM=1`；带 `--proxy` 时另写 `TG_PROXY`。
- `status` 只报告「已配置 / 缺失」，**绝不回显凭据值**；代理串含认证信息时会打码。
- `set` / `test` 非零退出码即表示失败，失败原因分类：`NETWORK`（连不上 `api.telegram.org`，需配代理）/ `BAD_TOKEN` / `BAD_CHAT` / `CURL_MISSING`。

### 手工配置（环境变量 / 本地配置文件）

凭据有两种来源，**环境变量优先**；环境变量取不到时才读本地配置文件。推送是否生效由下节的「配置状态三态」决定，两种来源完全等价。

**方式一：环境变量**

macOS / Linux / Git Bash：

```bash
export TG_BOT_TOKEN="<你的 Bot Token>"  # 由 @BotFather 分配，切勿写入脚本或提交仓库
export TG_CHAT_ID="<你的 chat id>"       # 与机器人对话的 ID（私聊为用户 id，群组为负数）
# export TG_PROXY="http://127.0.0.1:7890" # 直连 api.telegram.org 不通时填写（代理地址，非凭据）
```

Windows PowerShell：

```powershell
$env:TG_BOT_TOKEN = "<你的 Bot Token>"
$env:TG_CHAT_ID   = "<你的 chat id>"
# $env:TG_PROXY   = "http://127.0.0.1:7890"
```

**方式二：本地配置文件 `.env.local`**（推荐给定时任务：不必依赖会话环境变量）

在 skill 根目录创建 `.env.local`（该文件已被 `.gitignore` 忽略，**切勿提交或分享**）。**推荐直接复制随 skill 分发的模板**：`cp .env.example .env.local`（Windows PowerShell：`Copy-Item .env.example .env.local`），再按需填入自己的凭据：

```ini
# 每行 KEY=VALUE；空行与 # 开头为注释；仅识别下列 5 个键
# 填入自己的凭据后，去掉下面两行行首的 "# "（等号右侧一律不要加引号）
# TG_BOT_TOKEN=<你的 Bot Token>
# TG_CHAT_ID=<你的 chat id>
# 代理（可选）：本机无法直连 api.telegram.org 时填写（代理地址，非凭据）
# TG_PROXY=http://127.0.0.1:7890
# 推送开关（三态）：不写该行时按凭据判断；1 = 启用，0 = 已拒绝（不再询问）
# WB_CHECKIN_TELEGRAM=1
# 推送请求超时（秒，默认 10）
# WB_CHECKIN_TG_TIMEOUT=10
```

- 文件为**逐行解析**（不做 `source` / `Invoke-Expression`），只提取白名单键的字符串值，**文件中不会执行任何代码**；值两端的空白与成对引号会被去掉。
- 识别键：`TG_BOT_TOKEN`、`TG_CHAT_ID`、`TG_PROXY`、`WB_CHECKIN_TELEGRAM`、`WB_CHECKIN_TG_TIMEOUT`，其余键与注释一律忽略。
- **优先级**：同一键若环境变量与 `.env.local` 同时存在，以环境变量为准。

### 配置状态三态（`checkin.sh` / `checkin.ps1` / `tg-config.js` 判定一致）

| 状态 | 判定条件 | 签到脚本行为 |
|------|----------|--------------|
| **未配置 `unset`** | 未设 `WB_CHECKIN_TELEGRAM`，且 `TG_BOT_TOKEN` / `TG_CHAT_ID` 未配置完整 | 只签到，不推送、不询问（是否推送由 agent 在首次引导中询问） |
| **已启用 `enabled`** | `WB_CHECKIN_TELEGRAM` 为 `1` / `true` / `yes` / `on`；**或**未设该开关但 Token + chat id 齐全（兼容 1.1.0 起无显式开关的既有配置） | 签到后推送 |
| **已拒绝 `declined`** | `WB_CHECKIN_TELEGRAM` 为 `0` / `false` / `no` / `off` / `declined`（持久化在环境变量或 `.env.local`） | 只签到，不推送、也不再询问 |

### 开关与行为

| 变量 | 默认 | 说明 |
|------|------|------|
| `WB_CHECKIN_TELEGRAM` | 未设置 | 三态标记：未设时按凭据判断；`0` / `false` / `no` / `off` / `declined` 表示已拒绝 |
| `WB_CHECKIN_TG_TIMEOUT` | `10` | 推送请求超时（秒） |

- **未配置凭据（且未显式启用）→ 不联网、不推送**，签到主流程完全不受影响。
- **已启用但凭据缺失，或推送发送失败** → 签到脚本会在日志中写一行可见提示（说明缺口与补救方式），但**不改变退出码、不影响签到结果**；签到日志与退出码仍只反映签到本身。
- 推送为「尽力而为」：请求设超时（`WB_CHECKIN_TG_TIMEOUT`，默认 10 秒），失败不重试、不阻塞，也不写入任何凭据。
- 推送内容**仅包含签到状态与结果字段，绝不包含 `accessToken` 或任何凭据**。
- **代理**：优先 `TG_PROXY`，其次回退 `HTTPS_PROXY` / `ALL_PROXY` / `HTTP_PROXY`（含小写写法）；都未设置时，PowerShell 版沿用系统（IE 选项）代理，Git Bash 版交由 curl 自身处理。本机不能直连 `https://api.telegram.org` 时必须显式配置其一，否则推送会失败并在签到日志中留下一条提示（签到不受影响，但收不到消息）。

## 排错

- **升级 WorkBuddy 5.6.2+ 后签到失败，报「未找到新版明文认证文件」（< 1.0.6）**：桌面端已把 `accessToken` 改为 `$wbEncrypted` 信封加密（issue #191）。升级 skill 到 1.0.6+ 即可解密；1.0.6 起若再失败会报确切原因（见下一条）。
- **报「无法从 WorkBuddy 定制 Electron 获取静态钥」**：v5.6.2+ 信封解密需定位 WorkBuddy 桌面端主程序（以纯 Node 模式调用，不启动 GUI）。自动探测路径未覆盖自定义安装位置时，用 `WB_CHECKIN_WORKBUDDY_BIN=<主程序路径>` 显式指定（Windows 一般是 `WorkBuddy.exe`，macOS 是 `WorkBuddy.app/Contents/MacOS/` 下的主二进制）。报「静态钥与信封 keyId 不匹配」则说明官方已更换加密方案，请提 issue。
- **「获取令牌失败（未知原因）」/ 未找到本地登录态**：先确认 WorkBuddy 桌面端已登录并打开过至少一次。v5.3.8+ 用户检查 Node.js 是否安装（`node -v`），或用 `WB_CHECKIN_NODE` 指定。
- **v5.3.8 已登录但仍报令牌失败**：本机 skill 版本过旧（< 1.0.2），不识别新版明文存储；升级到 1.0.2+。
- **当日重跑提示「签到未成功 / code=10001」**：旧版本（< 1.0.2）未把 `code=10001` 识别为「已签到」；1.0.2+ 会正确报告「今日已签到」。
- **401 令牌过期**：打开 WorkBuddy 刷新登录态，脚本每次运行会重新读取最新 token，次日自动恢复。
- **偶发「令牌已过期（401）」但次日又正常（< 1.0.3）**：401 判定原为扫响应体子串，响应体里的随机 `requestId` 恰好含 `401` 时会误判（约 0.57%/次），当日签到被跳过且连续签到中断。1.0.3 起改用真实 HTTP 状态码判定。
- **Windows 已登录却持续 401（< 1.0.3）**：1.0.2 的 win32 候选只探 `%APPDATA%`，而桌面端实际把明文登录态写在 `%LOCALAPPDATA%`；读不到新文件时会回退旧版 `state.vscdb`，取到**过期的历史会话令牌**，表现为「能拿到 token 但接口 401」。1.0.3 起优先探 `%LOCALAPPDATA%`。**排查 401 请先确认令牌来源，而非怀疑请求路径或请求头**（实测网关不强制 `/v2/` 与 `X-User-Id`，见 CHANGELOG 1.0.3）。
- **macOS 解密报错但已登录（旧版账户）**：旧版迁移应用名仍是 `CodeBuddy`，设 `export WB_CHECKIN_APP_NAME=CodeBuddy` 后重试（仅走 state.vscdb 分支时生效）。
- **Electron 下载慢/失败（旧版账户）**：配置 npm 镜像（见 `references/dependencies.md`）后重跑 setup；或手动放置 Electron 后用环境变量/参数指定。v5.3.8+ 新版账户无需 Electron。
- **Windows 提示不是内部或外部命令**：用 `powershell -ExecutionPolicy Bypass -File …` 运行；确认 `curl.exe` 存在。
- **沙箱里 `require('electron')` 报错**：Agent 沙箱默认设 `ELECTRON_RUN_AS_NODE=1`，脚本已用 `env -u`（sh）/ `Remove-Item Env:`（ps1）处理；v5.3.8+ 主路径用纯 Node，不受此影响。
- **日志出现「Telegram 推送已启用但凭据缺失」**：推送处于「已启用」（设了 `WB_CHECKIN_TELEGRAM=1`，或未设开关但曾配置过凭据），但当前读不到 `TG_BOT_TOKEN` / `TG_CHAT_ID`。先 `node scripts/tg-config.js status` 确认，再执行 `set` 补齐凭据，或执行 `decline` 关闭推送。签到本身不受影响。
- **日志出现「Telegram 推送发送失败」**：多为网络层失败（本机无法直连 `api.telegram.org`，或代理未配置 / 已失效）。用 `node scripts/tg-config.js test --proxy <代理地址>` 验证，成功后用 `set --proxy <代理地址>` 写回配置。签到本身不受影响。

## Windows 兼容性修复（1.0.4）

1.0.3 及之前版本的验证全部在 macOS 完成（见 CHANGELOG「已知限制」）。1.0.4 修复 Windows（Git Bash / PS 5.1）实跑暴露的 3 处问题：

| # | 文件 | 症状 | 根因 | 修复 |
|---|---|---|---|---|
| 1 | `checkin.ps1` | `表达式或语句中包含意外的标记"}"`，脚本完全跑不起来 | 文件是**无 BOM 的 UTF-8**，PS 5.1 按 GBK 解析，中文注释变乱码破坏语法 | 补 UTF-8 BOM（零代码改动） |
| 2 | `checkin.ps1` | `签到未成功：PARSE_ERR` | `[Console]::OutputEncoding` 中文 Windows 默认 GB2312，把 UTF-8 JSON 解成乱码并**吃掉闭合引号**，`ConvertFrom-Json` 抛错 | `Invoke-CheckinApi` 内调用 curl.exe 期间临时切 UTF-8，结束后还原 |
| 3 | `checkin.sh` | `未找到 Node 或 Electron 运行时`（但 `node -v` 正常） | `SCRIPT_DIR` 是 MSYS 的 `/c/...`，传给原生 `node.exe` 被拼成 `C:\c\Users\...` → `Cannot find module` → 令牌为空 | 用 `cygpath -w` 归一化传给 Node 的路径；JSON 解析改为 **Node 优先、python3 回退**（Node 本就是必需依赖） |

> **排错提示**：第 3 条的报错文案极具误导性——它让你去装 Node.js，但 Node 是好的，真实原因被 `decrypt` 调用的 `2>/dev/null` 吞掉。遇到这条，**先直接跑 `node "<脚本绝对路径>/decrypt-token.js"` 看真实报错**。

### 已知行为（非 bug）

- 重复签到时 `daily-checkin` 返回 **HTTP 400**（首次签到才是 200），业务体为 `code=10001`。判定依据始终是业务体的 `code=10001`，两个脚本均已将其视为成功。

## 安全说明

> ⚠️ **凭据即账号密码**：本 skill 解密的 `accessToken` 等同你的 WorkBuddy 账号密码，具有高敏感性。请务必遵守以下红线：

- 令牌仅在内存中使用，通过管道立即被签到请求消费，**不写入任何日志文件、不落盘、不回显到终端、不提交到仓库**。
- `logs/` 仅记录签到结果（积分 / 连续天数 / 成功失败），**绝不含令牌原文**。切勿将日志或脚本输出粘贴分享。
- 网络访问默认仅发往腾讯官方接口 `copilot.tencent.com/billing/meter/*` 与 `copilot.tencent.com/v2/billing/meter/*`；**仅当推送处于「已启用」状态（显式设 `WB_CHECKIN_TELEGRAM=1`，或未设开关但 `TG_BOT_TOKEN` + `TG_CHAT_ID` 齐全）时**，才会额外向 `api.telegram.org` 发送一条签到状态消息（首次配置时发送一条测试消息）；状态为「未配置」或「已拒绝」（`WB_CHECKIN_TELEGRAM=0`）时完全不访问该域名。除此之外不向任何第三方上传数据。
- Telegram 凭据只从环境变量或 skill 根目录 `.env.local` 读取（前者优先）；该文件已被 `.gitignore` 忽略，**切勿提交仓库、切勿分享**。**把 skill 分发给他人前，请先物理删除 `.env.local` 与 `logs/`**——整目录拷贝 / 打压缩包分发时会连同它们一起带走（详见 `README.md` 的「分发前必读」）。读取为逐行字符串提取（不做 `source` / `Invoke-Expression`），**不会执行文件中任何代码**。
- `scripts/tg-config.js` 写入凭据时同样只动 `.env.local` 中上述白名单键（就地更新、保留其余内容与注释），**从不回显凭据值**（状态查询仅报「已配置 / 缺失」，代理串含认证信息时打码），也不把凭据写入日志或除该文件以外的任何位置。
- Telegram 推送内容**只含签到状态与结果字段（积分 / 连续天数 / HTTP 状态码 / 失败原因），绝不含 `accessToken` 或任何凭据**；推送请求设超时。推送失败（含凭据缺失）只在签到日志里留一行**不含凭据**的提示，**不改变退出码、不影响签到结果**。
- 解密成功时脚本会向 stderr 打印一行安全提示（不影响 stdout 的 token 管道），便于你确认凭据正在被使用。
- 请勿用于他人账户、批量注册刷分或任何违反 WorkBuddy 用户协议的用途；使用者自行承担使用风险。

### 为何需要这些能力（上下文说明）

本 skill 自述为"每日签到"，但完整链路需以下能力，均为本机运行、无后端，且对完成签到必不可少：

- **读取本地令牌**：WorkBuddy 桌面端登录后把登录态存于本地——v5.3.8+ 为明文 JSON 文件（`workbuddy-desktop.info`，纯 Node 可读），旧版为 Electron `safeStorage` 加密的 `state.vscdb`。必须读到 `accessToken` 才能调用官方签到接口，这是签到功能的核心，无法绕过。
- **Node.js 运行时**：v5.3.8+ 主路径用 Node 直接读取明文登录态并解析 JSON。推荐手动指定已校验的 Node（设 `WB_CHECKIN_NODE`）。
- **Electron 运行时（仅旧版账户）**：只有使用旧版 WorkBuddy/CodeBuddy（`state.vscdb`）时才需要，执行 `safeStorage.decryptString()` 解密令牌（macOS 命中钥匙串、Windows/Linux 走系统 DPAPI/keyring）。推荐手动指定已校验的 Electron（设 `WB_CHECKIN_ELECTRON`），不依赖自动下载。
- **python3 回退（默认关闭）**：仅当旧版分支的 `node:sqlite` 不可用时，设 `WB_CHECKIN_ALLOW_PY_FALLBACK=1` 才会调用外部 `python3` 读取会话库。默认关闭以缩小信任边界。
- **定时任务（crontab / launchd / 任务计划程序）**：用于多时间点幂等补签，脚本本身不写入系统定时，需你显式配置。
- **Telegram 推送（可选）**：仅当推送状态为「已启用」（`WB_CHECKIN_TELEGRAM=1`，或未设开关但凭据齐全）时，于签到结束后向 `api.telegram.org` 发送一条状态消息（不含任何凭据）；首次配置时发送一条测试消息以验证连通性。状态为「未配置」或「已拒绝」（`WB_CHECKIN_TELEGRAM=0`）时完全跳过、不联网。

### 供应链提示

安装 Electron 默认**不自动下载**（避免静默引入第三方大二进制）。如需自动安装，须显式设置环境变量 `WB_CHECKIN_AUTO_INSTALL_ELECTRON=1` 确认从官方 npm registry 下载 `electron@37`。

## 所需权限

本 skill 运行需以下本地权限，均限定在最小范围：

| 权限 | 范围 | 说明 |
|------|------|------|
| 本地代码执行 | 仅本 skill 的 `checkin.sh/.ps1`、`decrypt-token.js`、`tg-config.js`、`setup.sh/.ps1`，以及以纯 Node 模式（`ELECTRON_RUN_AS_NODE=1`）调用本机 WorkBuddy 主程序提取静态钥（v5.6.2+ 信封解密用，不启动 GUI、不修改 WorkBuddy 任何状态） | 用户手动或定时触发，非后台常驻 |
| 本地文件读取 | 用户目录下的 WorkBuddy 登录态（v5.3.8+ 登录态文件 `workbuddy-desktop.info` / 旧版 `state.vscdb`）；可选的 skill 根目录 `.env.local`（仅当环境变量未提供 Telegram 凭据时读取，已被 `.gitignore` 忽略） | 读取登录态以获取调用官方接口所需的 accessToken；读取本地 Telegram 推送配置 |
| 本地文件写入 | 仅 skill 根目录 `.env.local`（由 `tg-config.js set` / `decline` 写入，就地更新白名单键并保留其余内容；已被 `.gitignore` 忽略）与 `logs/` 下的签到日志 | 保存 Telegram 凭据与推送状态；记录签到日志。不修改 WorkBuddy 任何文件 |
| 网络访问 | 默认仅 `copilot.tencent.com` 官方签到接口；推送状态为「已启用」时额外访问 `api.telegram.org`（可经 `TG_PROXY` 等代理），首次配置时发送一条测试消息 | 不访问任何其他域名；未配置凭据或状态为「已拒绝」（`WB_CHECKIN_TELEGRAM=0`）时不发起该请求 |
| 环境变量读取 | `WB_CHECKIN_*`（Node/WorkBuddy/Electron 路径、应用名、错峰、回退开关、推送开关与超时）及 `TG_BOT_TOKEN` / `TG_CHAT_ID` / `TG_PROXY`（并回退读取 `HTTPS_PROXY` / `ALL_PROXY` / `HTTP_PROXY` 及其小写形式） | 均为本机用户显式配置 |
| 定时任务 | 由用户显式配置 crontab / launchd / 任务计划程序 | skill 不自动写入系统定时 |
*（内容由AI生成，仅供参考）*
*（内容由AI生成，仅供参考）*
*（内容由AI生成，仅供参考）*
