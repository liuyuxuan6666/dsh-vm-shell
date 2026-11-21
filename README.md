# dsh-vm-shell

在 DeepSeek Harness（DSH）里，**拿到一台 Hyper-V 虚拟机内部的提权 PowerShell**，不跟 UAC 搏斗。

> Give DeepSeek Harness an elevated PowerShell inside a Hyper-V guest, without fighting UAC.

**实测环境**：宿主 Windows 11 + Hyper-V，guest Windows 11 专业工作站版；VMConnect 使用基本会话；guest 管理员为本地账号（PowerShell Direct 下 `elevated=true`，无需 `LocalAccountTokenFilterPolicy`）。

---

## 它解决什么问题

DSH 的 computer-use 插件跑在你自己的用户会话里。Windows 有两道墙它过不去：

| 墙 | 机制 | 结果 |
|---|---|---|
| UIPI | 中完整性进程不能给高完整性窗口发输入 | 管理员窗口点不动 |
| Secure Desktop | UAC 同意框在 `WinSta0\Winlogon` 独立桌面 | 弹出来就卡死，必须人来点 |

在**虚拟机**里有第三条路：从宿主层注入键鼠。guest 收到的是"虚拟硬件"输入，不经过 guest 的 UIPI，也就看得见、点得动 UAC。

但真正好用的不是点鼠标，而是**脚本**。所以这个项目做两件事：

1. **一次引导**：宿主注入进 guest，拿到一个提权终端，建好本地管理员账号。
2. **长期通路**：用 **PowerShell Direct**（VMBus，不需要网络、不需要 WinRM 监听、不需要 RDP）直接在 guest 里跑结构化 PowerShell。

视觉只是引导用的辅助，不是主路径。

---

## 架构

```
DSH (普通用户进程)
  │  TCP 127.0.0.1:17801  (JSON, 带 token)
  ▼
VmAgent  (计划任务, 以 SYSTEM 运行)
  ├── PowerShell Direct ──► guest 里的提权 PowerShell   ← 日常都走这条
  ├── Msvm_Keyboard / Msvm_SyntheticMouse ──► guest 虚拟键鼠  ← 引导 / UAC
  └── Msvm_VirtualSystemManagementService ──► guest 缩略图     ← 粗略看画面
```

- 插件侧（`plugin/`）你是普通权限，**不需要提权 DSH**。
- agent 侧（`agent/`）需要 Administrator/SYSTEM，因为它要访问 `root\virtualization\v2`。

---

## 安装

### 1. 准备 guest

- Windows 10 / 11 或 Server 2016+
- 有一个**本地管理员账号**（下面用 `dsh` 举例）
- VMConnect 使用**基本会话**，不要用增强会话（见下面的"坑"）

如果 guest 里还没有管理员账号，用宿主注入引导一次：

1. `Win+X` → `终端(管理员)(A)`
2. UAC 弹出后按 `Alt+Y`
3. 在提权终端里执行：

```powershell
net user dsh DshVm2026Alpha /add
net localgroup administrators dsh /add
```

### 2. 安装 agent（需要一次管理员权限）

以**管理员** PowerShell 运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\agent\Install-VmAgent.ps1 `
    -VmName win11 -GuestUser dsh -GuestPassword 'DshVm2026Alpha'
```

它会：

- 校验 VM 存在
- 写 `%ProgramData%\DshVmShell\config.json`（含 guest 密码，ACL 仅 SYSTEM + Administrators）
- 写 `%ProgramData%\DshVmShell\token.txt`（回环 API 的 token，Users 可读）
- 注册计划任务 `DshVmShell`（SYSTEM，开机自启）并立即启动

之后**不再需要任何窗口**，重启也在。

### 3. 安装 DSH 插件

把 `plugin/` 作为本地 bundle 装进 profile（或用 `plugin_manager` 的 `install_bundle`）：

```yaml
# ~/.dsh/profiles/<profile>/cordis.patch.yml
- id: dsh-vm-shell
  name: 'file:///C:/path/to/dsh-vm-shell/plugin/index.js'
  config:
    port: 17801
```

插件默认读 `%ProgramData%\DshVmShell\token.txt`，一般不用配。

---

## 工具

| 工具 | 作用 |
|---|---|
| `vm_ps` | **主力**。在 guest 里跑一段 PowerShell，提权，返回输出。VM 关着会自动开机。 |
| `vm_status` | agent 是否在线、控制的 VM、电源状态、guest 账号、会话状态。 |
| `vm_power` | `state` / `start` / `stop` / `reset`。开关机。 |
| `vm_uac_yes` | 用 `Alt+Y` 答应 guest 的 UAC 同意框。 |
| `vm_key` | 注入单个虚拟键（`down`/`up` 可拼组合键）。 |
| `vm_type` | 注入 ASCII 文本（引导用；无 IME）。 |
| `vm_screenshot` | 存一张 guest 缩略图到本地并返回路径（粗看用）。 |

示例：

```
vm_ps: Get-Service | Where-Object Status -eq 'Running' | Select-Object -First 5 Name
vm_ps: Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version
```

---

## 开机自启与 VM 电源

### agent 会自启

`Install-VmAgent.ps1` 注册的是 **SYSTEM + `AtStartup`** 的计划任务：

- 宿主开机即启动，**不需要登录桌面**、不弹 UAC、没有窗口
- 只监听 `127.0.0.1`，不依赖网络和 Hyper-V 服务就绪（它启动时不做 Hyper-V 调用）
- 失败会按计划任务设置重启 3 次（间隔 1 分钟）

查状态：

```powershell
Get-ScheduledTask -TaskName DshVmShell | Select-Object TaskName, State
```

### VM 不一定自启：两处都配上最稳

Hyper-V 自己的自动启动默认**取决于创建方式**，很多 VM 是"关机后不会自动开"。两条互补的路：

**a) 让 Hyper-V 开机就拉起 VM**（推荐，省一次往返）：

```powershell
Set-VM -Name win11 -AutomaticStartAction Start -AutomaticStartDelay 0
Set-VM -Name win11 -AutomaticStopAction ShutDown
```

**b) 让 agent 按需开机**（默认已开启，`autoStart: true`）：

`vm_ps` 在发脚本前会检查 `EnabledState`；不是 Running 就 `RequestStateChange(2)`，然后每 3 秒轮询，直到 guest 能应答 PowerShell Direct（默认最多 180 秒，`bootWaitSec` 可调）。也可以显式调用：

```
vm_power action=start
```

冷启动的正常时间线：`RequestStateChange` → 3–10 秒进入 Running → 再等 20–60 秒 guest 才响应 PS Direct（这个阶段 `ps` 会自动重试，不会报错）。

### 宿主重启之后

| 时刻 | 状态 |
|---|---|
| T+0 | 宿主重启 |
| T+5s | `DshVmShell` 任务启动，17801 开始监听 |
| T+10s | VM 被 Hyper-V 或 agent 拉起（看上面 a/b） |
| T+30~60s | guest 起来，`vm_ps` 恢复正常 |

唯一需要人做的事：等你登录 DSH 并发一句话。

---

## 安全模型

- agent 只监听 `127.0.0.1`，**不监听任何网卡**，局域网里的其他设备连不上。
- 每个请求都用 **HMAC-SHA256** 签名，带时间戳和一次性 nonce：
  - 签名错误 → 拒绝
  - 时间戳偏离超过 300 秒 → 拒绝
  - 同一 nonce 重复出现 → 拒绝（防重放）
  - 比较用常量时间，避免逐字节爆破
- 密钥 32 字节随机，只在 `%ProgramData%\DshVmShell\secret.txt`，ACL 只给**运行 DSH 的账号** + SYSTEM + Administrators，不再给 Users 组。
- guest 密码明文存在 `config.json`（ACL 仅 SYSTEM + Administrators）。它只是 VM 里的一个本地账号。
- 建议给这个账号配上 VM 内最小够用的权限，别复用你真实机器的密码。

### 威胁模型说清楚

密钥对你的账号可读，所以**任何以你身份运行的进程**都能签名并控制那台 VM。这是"插件不需要提权"的代价：插件跑在你的用户会话里，它必须能读到密钥才能签名。

真正的边界是**账号边界**（别的 Windows 账号读不到密钥），而不是"本机所有进程"。要更严格，可以让 DSH 也以管理员运行，再把密钥 ACL 收窄到 Administrators。

---

## 已知限制（都是实测踩出来的）

| 现象 | 原因 | 处理 |
|---|---|---|
| 注入全部返回成功但 guest 没反应；缩略图全白 | VMConnect 处于**增强会话**（VMBus 上的 RDP），注入打到 console 会话 | 切回基本会话（`查看 → 增强会话` 取消） |
| `TypeText` 只认 ASCII | 虚拟键盘没有 IME | 中文用 `vm_ps` 传脚本，别用键盘注入 |
| 缩略图尺寸超过 ~1024 报 `returnvalue=32775` | Hyper-V 缩略图有上限 | 用 1024×640，只当"看一眼" |
| 缩略图颜色发紫发绿 | 实际是 **BGR565**，按 RGB565 解就错 | 已内置 `bgr565` 默认 |
| `GetVirtualSystemThumbnailImage` 报参数不存在 | 参数按字母序（`HeightPixels, TargetSystem, WidthPixels`） | agent 按名字绑定，不按位置 |
| 计划任务起来了但端口没监听 | 手动的 agent 还占着 17801 | 先结束手动那个进程 |
| **脚本被安全软件直接删掉 / 计划任务消失** | agent 同时具备"隐藏窗口 + SYSTEM + 本地套接字 + 远程执行 PowerShell"这些特征，被杀软按后门启发式命中（实测火绒会隔离 `VmAgent.ps1` 并移除任务） | 把 `%ProgramData%\DshVmShell` 和项目目录加进杀软信任区，再重跑安装器。见下方 |
| `Invoke-Command -VMName` 权限报错 | 调用方不是管理员 | agent 必须以 SYSTEM/Administrator 运行 |

---

## 目录

```
agent/
  VmAgent.ps1            回环 agent：ps / 键鼠 / 缩略图
  Install-VmAgent.ps1    安装为 SYSTEM 计划任务
  Uninstall-VmAgent.ps1  卸载
plugin/
  package.json           DSH bundle 清单
  cordis.patch.yml       插入插件
  index.js               vm_* 工具实现
```

---

## 协议

一行一个 JSON 信封，回一行 JSON。**每个请求都要签名**，`ping` 也不例外。

```jsonc
// 信封
{"v":1,"ts":1763700000,"nonce":"<32 hex>","b":"<base64(body)>","sig":"<hex>"}
// sig = HMAC_SHA256(key, "<ts>.<nonce>.<b>")

// body 里的 op
{"op":"ping"}
{"op":"info"}
{"op":"ps","script":"<base64 utf8>","timeout":120}
{"op":"power","action":"start"}
{"op":"key","vk":13}
{"op":"keydown","vk":18} / {"op":"keyup","vk":18}
{"op":"text","text":"notepad"}
{"op":"uac-yes"}
{"op":"screen","w":1024,"h":640,"fmt":"bgr565"}
{"op":"vms"}
```

手测（自带签名逻辑）：

```powershell
powershell -ExecutionPolicy Bypass -File .\test\Test-Agent.ps1 -Body '{"op":"info"}'
```

未签名、签名错、时间戳过期、nonce 重放，都会得到 `{"ok":false,"error":"...","auth":false}`。

---

## 开发注意（踩过的坑）

**PowerShell 函数名不要和内置 cmdlet 只差大小写或连字符位置。** 命令解析不区分大小写，`New-PsSession` 与 `New-PSSession` 是同一个名字：自定义函数会**覆盖** cmdlet，函数内部再调 `New-PSSession` 就是调自己，报错为

```
由于调用深度溢出，脚本失败。
```

（本项目的 `New-GuestSession` / `Get-GuestSession` / `Reset-GuestSession` 就是为此改的名。）

其他几条：

- agent 是**单线程**的：一条请求处理完就关连接，一次只服务一个客户端。
- 任何可能长时间阻塞的调用（建会话、开 VM）都必须带超时，否则会把整个循环卡住。
- `info` 这类状态查询**不能创建会话**，否则 guest 正在启动时它会阻塞几十秒。

---

## guest 重装系统之后

重装/还原会让 guest 里的 `dsh` 账号消失，`config.json` 里的凭据随之失效。按下面顺序恢复：

1. 等 guest 装完、进到桌面（**VMConnect 用基本会话**）。
2. 重新建账号——用注入路径（此时还没有 PowerShell Direct）：

   ```
   vm_key   vk=91            # Win
   vm_type  "cmd"            # 或直接点开始菜单
   vm_key   vk=13            # Enter
   vm_type  "net user dsh DshVm2026Alpha /add"
   vm_key   vk=13
   vm_type  "net localgroup administrators dsh /add"
   vm_key   vk=13
   ```

   需要提权时先 `Win+X` → `A` → `vm_uac_yes`。

3. 删掉可能的旧会话缓存再试 `vm_ps`：

   ```
   vm_ps        # 会自动重试建会话
   ```

4. 如果换过密码，重跑一次 `Install-VmAgent.ps1` 更新 `config.json`（顺便轮换签名密钥）。

---

## 杀软误报

这个 agent 天生"长得像后门"：隐藏窗口、SYSTEM 计划任务、本地套接字、在远端执行 PowerShell。启发式引擎命中它很正常，不代表真的有问题，但你必须**主动加白**，否则：

- `agent.ps1` 会被直接隔离（文件消失）
- `DshVmShell` 计划任务会被移除

需要加白的两处：

1. 目录 `%ProgramData%\DshVmShell\`
2. 你放这个仓库的目录

以火绒为例：`安全设置 → 信任区 → 添加目录`，然后重跑 `Install-VmAgent.ps1`。

不想加白的话，就得每次开机手动起一次 agent（`powershell -File agent\VmAgent.ps1`），那样就失去"重启后自愈"的意义了。

---

## License

MIT
