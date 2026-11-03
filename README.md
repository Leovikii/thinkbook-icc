# 本机 Windows color 目录快照

此分支 `codex/local-color-2026-11-03` 保存 2026-11-03 从本机 `%WINDIR%\System32\spool\drivers\color` 读取的全部 387 个文件，已逐个通过 SHA-256 核对。

主分支保存预装系统原件，本分支只用于留存本机现状，不代表应当以本分支替换预装原件。

与预装原件的实质差异：`TPLCD_8AD7_DCIP3.icm`、`TPLCD_8AD7_DisplayP3.icm`；另外新增 `HDR 校准配置文件 2026-9-15 20635.icc`。报告和 XML 的 Git 换行差异不属于色彩参数变化。

`color-sha256.json` 记录此快照的精确字节校验值，`.gitattributes` 禁止 Git 改写 `color/` 中的换行。此快照未备份注册表配置关联、驱动或杜比授权。
