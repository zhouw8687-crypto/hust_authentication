# 华科校园网备用连接

Windows 有线网络优先的 Wi-Fi 备用方案。有线网络掉线时，脚本连接已保存的 Wi-Fi。独立确认有线外网恢复后，脚本切回有线。校园网认证由学校网页或现有的认证客户端完成。

## 安装

需要 Windows 10 或 11、Windows PowerShell 5.1、可用的有线和无线网卡，以及安装开机任务所需的本机管理员权限。

1. 用 Windows 的 Wi-Fi 设置手动连接并保存备用网络。建议关闭这些备用网络的「自动连接」，由脚本管理连接时机。开机任务需要 Windows 中的所有用户 Wi-Fi 配置。
2. 将 `failover.example.json` 复制为 `failover.local.json`。把 `WifiProfiles` 改为 Windows 已保存的 Wi-Fi 配置名称，按优先顺序排列。可以只配置一个。常见的配置名称与 Wi-Fi 名称一致。
3. 在 PowerShell 运行 `Get-NetAdapter`，确认 `WiredAlias` 和 `WifiAlias` 对应这一台电脑的有线和无线网卡。按实际名称修改本地配置。
4. 右键 `Install-CampusNetworkWiFiFailover.cmd`，选择「以管理员身份运行」。安装程序将运行文件复制到 `%ProgramFiles%\CampusNetworkWiFiFailover`，注册 **华科校园网备用连接** 开机任务，并在当前安装用户的登录启动文件夹添加托盘快捷方式。
5. 登录后，可在任务栏右下角的 `^` 菜单里找到托盘图标。想立即打开图标，可以在 `Win + R` 中输入 `shell:startup`，再双击「华科校园网备用连接」快捷方式。

开机任务在 Windows 启动后延迟 30 秒运行，支持在登录前启动。安装后会安排一次短暂的 Wi-Fi 试连。右键以管理员身份运行 `Uninstall-CampusNetworkWiFiFailover.cmd` 可以注销任务、删除当前安装用户的托盘启动项，并尝试恢复脚本记录的临时网络优先级。已经显示的托盘图标可以通过右键菜单退出。

## 切换策略

| 情况 | 默认行为 |
| --- | --- |
| 有线连续两次无法上外网 | 按配置顺序尝试 Wi-Fi，验证无线上的外网 HTTPS 成功后，提高 Wi-Fi 的路由优先级 |
| 有线连续三次恢复外网 | 断开脚本接管的 Wi-Fi，恢复原来的无线优先级 |
| 有线持续正常 | 每 30 分钟试连 Wi-Fi 约一分钟，试连期间保持有线优先 |
| 试连期间有线断开 | 验证备用网络后进入接管，继续保留 Wi-Fi |

默认检测间隔为 15 秒。`IntervalSeconds` 支持 5–300 秒，`TrialIntervalMinutes` 支持 1–240 分钟，`TrialSeconds` 支持 15–180 秒。

外网探测的套接字绑定到指定网卡和 IPv4 地址，避免用另一块网卡的探测结果判断有线恢复。脚本连接已保存的 Wi-Fi 配置并临时调整无线优先级。学校认证系统的明确成功回执未接入，当前版本以指定网卡上的外网 HTTPS 可达性作为切换依据。活动中的远程会话可能需要重新连接。

## 日志与隐私

运行日志位于 `%ProgramFiles%\CampusNetworkWiFiFailover\CampusNetworkWiFiFailover.log`，也可以从托盘右键打开。日志包含时间、网卡状态、探测结果、切换记录及所用的备用 Wi-Fi 配置名称。向他人分享日志前，请先遮盖其中的真实 Wi-Fi 名称。

可以先做一次只读检查：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\CampusNetworkWiFiFailover.ps1 -Mode Check
~~~

脚本使用 Windows 保存的 Wi-Fi 凭据。本地配置只填写网卡和 Wi-Fi 配置名称，密码留在 Windows 中。本地配置、运行日志、旧认证配置和可执行文件都应留在本机。
