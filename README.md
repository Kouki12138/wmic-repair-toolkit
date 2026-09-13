# WMIC 修复工具（Windows 11 25H2 / 24H2 起 WMIC 被移除）

微软从 Windows 11 24H2 起把 **WMIC** 变成了“按需功能”，25H2 的系统里
`C:\Windows\System32\wbem\wmic.exe` 常常不存在。很多工业软件、加工/CAD/CAM、
授权类软件会调用 `wmic csproduct get uuid`、`wmic bios get serialnumber`
之类命令来读取机器信息，WMIC 缺失就会报错、无法使用。

本工具的作用：把被删掉的 WMIC 相关文件还原回去，**不需要重装系统、不需要联网**。

## 一键使用

1. 把整个文件夹复制到出问题的电脑
2. 双击 `run-repair.cmd`
3. UAC 弹窗点“是”
4. 等 1~3 分钟，看到 “WMIC 已可正常使用” 即完成
5. 重新打开之前报错的软件，不需要重启

日志会写到桌面：`wmic-repair-log.txt`

## 脚本做了什么

- 优先使用目标电脑**自己的组件库**（`C:\Windows\WinSxS`）里的同版本文件还原，
  按版本号自动挑选最新的 WMIC 组件，不怕各台电脑补丁版本不同
- 组件库里也没有时，自动改用本仓库 `payload\` 目录里的离线文件
- 自动提权、自动绕过脚本执行策略、自动解除“来自网络”的阻止标记
- 最后自动运行 `wmic os get caption` 和 `wmic csproduct get uuid` 验证

还原的文件：

| 位置 | 文件 |
|---|---|
| `System32\wbem`、`SysWOW64\wbem` | `wmic.exe`（64 位 / 32 位） |
| 语言目录 `zh-CN`、`en-US` | `wmic.exe.mui` |
| 输出模板 | `texttable.xsl`、`textvaluelist.xsl`、`rawxml.xsl`、`xsl-mappings.xml`、`csv.xsl`、`hform.xsl`、`htable.xsl`、`mof.xsl`、`xml.xsl` |
| WMI 别名定义 | `cli.mof`、`cliegaliases.mof` |

## 只检查不修改

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\repair-wmic.ps1 -DryRun
```

其他参数：`-ForceBundle`（强制用离线包）、`-NoPause`（结束后不等待按键）。

## 适用环境

- Windows 10 / Windows 11，64 位（`payload` 内的文件取自 Windows 11 25H2 x64）
- ARM64 架构的电脑请勿使用 `payload`，脚本会检测并提示

## 注意

`payload` 目录中的文件是 Windows 系统组件，仅用于修复本机被删除的系统文件。
如果电脑上装了“系统优化 / 安全加固”类工具，它可能再次删除 `wmic.exe`，
建议把 WMIC 加入白名单。
