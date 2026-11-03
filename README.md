# Thinkbook-ICC

ThinkBook G8+ AHP（Lenovo 21VR、LEN8AD7 屏幕）的预装杜比视界配置和校色文件备份。

主分支 `color/` 的 386 份预装原件保持不变，以它们作为恢复基准。本机现状另外保存在本地分支 `codex/local-color-2026-11-03`（快照提交 `01623f4`，387 个文件，包括后来新增的 HDR 校准）。核对结果见 [核对报告](docs/verification-2026-11-03.md)。

```text
color/       预装原件（保持不变）
scripts/     一键入口、恢复脚本和测试
manifests/   SHA-256 校验清单
docs/        核对报告
README.md    使用说明
```

## 一键恢复

下载并解压整个仓库，双击 **`scripts\Restore-Color.cmd`**，接受 Windows 管理员权限提示即可。完整仓库使用随附的本地备份，不需要联网，不需要安装 Git 或其他依赖。

只下载单个 `Restore-Color.ps1` 时，脚本会自动从 GitHub 下载主分支 ZIP、解压并校验，然后恢复。也可以在 PowerShell 中粘贴以下命令：

```powershell
$p = Join-Path $env:TEMP ('Restore-Color-' + [guid]::NewGuid().ToString('N') + '.ps1'); Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/Leovikii/thinkbook-icc/main/scripts/Restore-Color.ps1' -OutFile $p; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

**在线入口需要先将本次新增脚本和清单发布到 GitHub 的 `main` 分支。** 本地未提交的脚本不会出现在 GitHub 下载包中。下载包内的 SHA-256 清单用于完整性检查，来源信任依赖 GitHub HTTPS 和仓库维护者。

脚本会：

1. 在修改 Windows 文件之前验证全部备份文件；检查本机型号为 `21VR` 且注册过 `LEN8AD7` 屏幕。换过屏幕的机器应先自行核实实际面板，注册表可能保留旧设备记录。
2. 比较 `%WINDIR%\System32\spool\drivers\color`，跳过一致的文件，将受影响的原文件完整备份到 `%ProgramData%\Thinkbook-ICC\Backups\日期时间-唯一编号`。
3. 复制缺失或不同的文件并再次验证 SHA-256；保留目录中其他文件，包括本机另加的 HDR 配置。
4. 写入失败时尝试恢复原文件并删除本次新增文件；如果回滚也失败，输出警告及原文件备份位置。

备份目录中的 `restore-log.json` 分别列出原文件 `originals` 和本次新增文件 `created`。如需手动撤销，可将备份原文件复制回 Windows 色彩目录，并按该日志删除本次新增文件。

## 仅检查或预演

在仓库目录打开 PowerShell：

```powershell
# 核对清单与本机，不修改 Windows 文件，也不请求管理员权限
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restore-Color.ps1 -CheckOnly

# 验证备份与硬件，显示恢复目标，不执行恢复
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restore-Color.ps1 -WhatIf

# 显式指定另一份已解压的完整仓库作为来源
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restore-Color.ps1 -SourcePath 'D:\Backups\thinkbook-icc'
```

`manifests/color-sha256.json` 对 ICC/ICM/DV 记录严格字节校验值。对 XML 和质量报告，分别记录现有内容的 LF、CRLF 校验值，以兼容 Git 的原有换行规则；不会为生成清单而改写 `color/` 原件。

## 恢复范围

这是**文件恢复**。脚本不导入注册表，不重新指定每块屏幕的默认配置，不备份或安装显示驱动、杜比组件及许可证。恢复后用 `colorcpl.exe` 检查对应屏幕的配置关联；必要时添加并选定合适的 `TPLCD_8AD7_*.icm`，再重启相关应用。仅复制 `.dv` 文件不能保证杜比视界功能可用。

## 验证脚本

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Restore-Color.ps1
```

测试在仓库内创建临时目录，验证清单、篡改拒绝、路径检查、原文件备份、重复运行、保留额外文件及失败回滚，不写入 Windows 目录。兼容 Windows PowerShell 5.1 和 PowerShell 7。
