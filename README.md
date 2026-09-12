# AHU-Network-AutoConnect

安徽大学校园网自动连接工具（Windows）。开机、插网线、Wi-Fi 重连时在后台静默完成 Dr.COM eportal 认证，无需打开认证网页。

纯 PowerShell 实现，无第三方依赖、无常驻进程、完全可审计。

- 平台：Windows 10/11，Windows PowerShell 5.1 与 PowerShell 7 双宿主兼容
- 认证入口：`http://172.16.253.3:801/eportal/`（Dr.COM JSONP 接口）
- 权限：全程当前用户，无需管理员

## 特性

- **事件驱动触发**：用户登录 + `NetworkProfile` 事件（Event ID 10000）+ 每小时保活，三层兜底，平时零占用
- **正确的出口 IP 选择**：优先按"通往 Portal 的路由"反查源 IP；检测到 TUN/代理虚拟网卡抢占默认路由时自动跳过路由探测，改用物理接口兜底；虚拟网卡（Mihomo/Clash/VMware/Hyper-V/WSL/TAP 等）一律拒绝
- **代理共存**：登录请求显式绕过系统代理（校园内网主机不应经过代理），与 Clash/Mihomo 等 TUN 代理互不干扰
- **响应严谨解析**：先剥离 JSONP 外壳再按 JSON 解析，`ret_code` 枚举映射；`ret_code=2`（IP 已在线）视为成功，`ret_code=1`（账号或密码错误）立即停止重试并退出，保护账号不被反复提交
- **电池友好**：计划任务允许电池供电时触发（笔记本用电池断网也能自动重连）
- **并发保护**：本地互斥锁，每小时任务与网络事件任务同时触发时不会重复认证
- **可观测**：按日滚动的脱敏日志（绝不写入密码）、日志自动保留 30 天、只读状态检查脚本、`-InspectOnly` 无请求诊断模式
- **可配置**：Portal 地址、校园网段（支持 `172.21.` 前缀与 `172.21.0.0/16` CIDR 两种写法）、首选网卡、重试次数全部在 `config.json` 中，改配置无需改代码

## 快速开始

1. 下载仓库并解压（或 `git clone`）。
2. 双击 `install.bat`（内部调用 `install.ps1`）。
3. 按提示输入校园网账号和密码（也可以跳过，稍后手动编辑 `%APPDATA%\ahu-network\config.json`）。
4. 看到 `Install complete` 即完成。插入网线或重连网络后，认证会在几秒内后台完成。

安装脚本做了什么：

| 动作 | 说明 |
|---|---|
| 部署引擎 | 复制 `ahu-connect.ps1`、`run-hidden.vbs` 到 `%APPDATA%\ahu-network\`（已有文件先备份到 `backup\时间戳\`） |
| 登录启动项 | 注册 `HKCU\...\Run\AHU-Network-AutoConnect` → `wscript.exe run-hidden.vbs`（登录即认证，无闪窗） |
| 每小时任务 | 计划任务 `AHU-Network-AutoConnect`，幂等保活 |
| 网络事件任务 | 计划任务 `AHU-Network-AutoConnect-OnNetwork`，绑定 `NetworkProfile` Event ID 10000 |
| 安全校验 | 安装结束自动跑一次 `-InspectOnly`（只选网卡，不发登录请求） |

## 配置说明

配置文件：`%APPDATA%\ahu-network\config.json`（参考 [config.example.json](config.example.json)）。

| 字段 | 说明 |
|---|---|
| `campus_user` / `campus_pass` | 校园网账号密码（与 `broadband_*` 至少填一组） |
| `broadband_user` / `broadband_pass` | 宽带账号密码（运营商账号，如 `xxx@telecom`），优先于校园账号尝试 |
| `portal_base` | Portal 认证入口，安大默认 `http://172.16.253.3:801/eportal/` |
| `portal_check_hosts` | 校园侧探测主机列表 |
| `campus_ip_prefixes` | 校园网段白名单，支持 `"172.21."` 与 `"172.21.0.0/16"` 两种写法，默认含 `10.` / `172.16.` / `172.21.` / `172.29.` |
| `preferred_interfaces` | 首选网卡名（模糊匹配），默认 `Ethernet` / `以太网` |
| `max_retries` / `retry_interval_sec` | 重试次数与间隔，默认 10 次 × 10 秒 |
| `log_retention_days` | 日志保留天数，默认 30，`0` 表示永久保留 |

> 旧版配置文件（只有账号密码等基础字段）无需迁移，缺失字段使用内置默认值。

## 手动使用

```powershell
# 前台诊断运行（会发送真实认证请求）
powershell -ExecutionPolicy Bypass -File "$env:APPDATA\ahu-network\ahu-connect.ps1" -Visible

# 只读诊断：选择网卡但绝不发送登录请求
powershell -ExecutionPolicy Bypass -File "$env:APPDATA\ahu-network\ahu-connect.ps1" -InspectOnly -Visible

# 状态检查（JSON 输出，不读配置内容、不访问 Portal）
powershell -ExecutionPolicy Bypass -File .\inspect-status.ps1
```

退出码：`0` 成功或已在线；`1` 配置错误；`2` 未检测到校园网；`3` 重试全部失败；`4` 账号或密码被 Portal 拒绝（请修改 `config.json` 后重试）。

## 工作原理

```
触发（登录 / NetworkProfile 事件 10000 / 每小时）
  └─ wscript.exe run-hidden.vbs        ← 无闪窗，优先 PowerShell 7
      └─ ahu-connect.ps1
          ├─ 1. 选择出口 IP
          │     ├─ 默认路由被虚拟网卡（TUN）持有时：直接走物理接口兜底
          │     └─ 否则 Find-NetRoute 反查 Portal 路由源 IP
          │        └─ 校验：校园网段白名单 + 拒绝虚拟网卡
          ├─ 2. 校园环境探测（ping 探测主机 + GET Portal，仅作诊断证据）
          └─ 3. 登录（宽带账号 → 校园账号）
                GET /eportal/?c=Portal&a=login&...&wlan_user_ip=<选出的IP>
                ├─ 剥离 JSONP 外壳 → JSON 解析 → ret_code 分类
                ├─ ret_code 0 / 2 → 成功（已在线也算成功）
                ├─ ret_code 1 → 该账号本运行内禁用；全部账号被拒 → 退出码 4
                └─ 其他 → 按配置重试（每轮重新选 IP）
```

为什么不能随便取"第一个本机 IP"：开代理软件的电脑上，`socket.gethostbyname` 一类取法几乎必然拿到 TUN 虚拟网卡的 `198.18.x.x`，Portal 会认证一个不存在的客户端。本工具的三级选择策略专门解决这个问题。

## 常见问题

**提示账号或密码错误（退出码 4）**
编辑 `%APPDATA%\ahu-network\config.json` 核对账号密码。注意区分校园网账号和运营商宽带账号（`@telecom` / `@unicom` 后缀）。

**开着 Clash / Mihomo 等代理能用吗？**
能。脚本按物理网卡选 IP、登录请求绕过系统代理；TUN 抢占默认路由时自动跳过路由探测。脚本不会读写任何代理设置。

**笔记本用电池时不自动重连？**
本仓库安装的任务已设置"电池供电时允许启动"。如果是旧版安装的任务，请重新运行 `install.bat` 升级任务设置。

**有线和 Wi-Fi 同时连校园网？**
Portal 按 IP 绑定认证会话，双上行时只有被认证的出口可用。建议只保留一个上行（或在系统中调高另一条路由的 metric）。脚本本身只认证选中的主出口。

**安全边界（必读）**
AHU Portal 使用明文 HTTP，账号密码会出现在 URL 中，这是校园网计费系统的既有设计，任何客户端都无法改变。`config.json` 中的密码同样是明文存储——请勿将配置文件提交到 Git 或分享给他人。日志已脱敏（只含状态与 IP，绝无密码）。

**认证接口 / 网段将来变了怎么办？**
改 `config.json` 即可：`portal_base` 换新认证入口，`campus_ip_prefixes` 添加新网段，无需改代码重新部署。

## 卸载

```bat
uninstall.bat
```

删除两个计划任务和登录启动项。加 `-Purge` 参数（或手动删除 `%APPDATA%\ahu-network`）可同时清除配置与日志（注意配置内含凭据）。

## 开发与测试

```powershell
# 离线单元测试（不发任何网络请求），5.1 与 7 均可运行
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

测试覆盖：网段判定（前缀 + CIDR）、虚拟网卡识别、Portal 响应分类（JSONP/JSON/HTML）、配置读取、ping 探测双宿主回归、`-InspectOnly` 零网络请求。

## 致谢与参考

- [C01in/AHU_AutoLogin](https://github.com/C01in-0/AHU_AutoLogin) 与其[开发随记](https://c01in.com/posts/7e4bd3cb)——抓包分析、事件驱动思路、v1.1.0 对网段变化/接口路径/代理残留的适配经验
- [GaoYuCan/AHU_Campus_Network_Connector](https://github.com/GaoYuCan/AHU_Campus_Network_Connector)——最早公开的安大直连 Portal 实现
- [Natural-selection1/AHU_auto_login](https://github.com/Natural-selection1/AHU_auto_login)——同类参考实现

本工具仅面向安徽大学校园网环境，供学习与个人便利使用，请遵守学校网络管理规定。

## License

[MIT](LICENSE)
