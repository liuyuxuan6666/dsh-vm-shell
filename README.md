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
| `vm_ps` | **主力**。在 guest 里跑一段 PowerShell，提权，返回输出。 |
| `vm_status` | agent 是否在线、控制的 VM、guest 账号、会话状态。 |
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

## 安全模型

- agent 只监听 `127.0.0.1`，每个请求都要 token。
- token 文件对 Users 可读 —— 也就是说，**你这台机器上任何以你身份运行的进程都能控制那台 VM**。这是"免提权"的代价，接受不了就改成只允许 Administrators 读，并让 DSH 也提权运行。
- guest 密码明文存在 `config.json`（ACL 仅 SYSTEM + Administrators）。它只是 VM 里的一个本地账号。
- 建议给这个账号配上 VM 内最小够用的权限，别复用你真实机器的密码。

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

一行一个 JSON，回一行 JSON。除 `ping` 外都要带 `"t": "<token>"`。

```jsonc
{"op":"ping"}
{"op":"info"}
{"op":"ps","script":"<base64 utf8>","timeout":120}
{"op":"key","vk":13}
{"op":"keydown","vk":18} / {"op":"keyup","vk":18}
{"op":"text","text":"notepad"}
{"op":"uac-yes"}
{"op":"screen","w":1024,"h":640,"fmt":"bgr565"}
{"op":"vms"}
```

手测：

```powershell
$t = Get-Content "$env:ProgramData\DshVmShell\token.txt" -Raw
$c = New-Object Net.Sockets.TcpClient
$c.Connect('127.0.0.1', 17801)
$w = New-Object IO.StreamWriter($c.GetStream()); $w.AutoFlush = $true
$r = New-Object IO.StreamReader($c.GetStream())
$w.WriteLine((@{ op = 'info'; t = $t } | ConvertTo-Json -Compress))
$r.ReadLine()
```

---

## License

MIT
