# Changelog

## 0.1.0 — 2026-10-31

- 从 MIT mi-remote-mapper 扩展为 Google Chromecast Voice Remote 专版，保留历史与归属。
- Google ATVV 写入属性、连续流、ADPCM nibble 顺序与控制同步适配。
- 按需 Apple PacketLogger 接收，支持 IOHID 不转交的单字节报告。
- 14 个普通实体键配置与检测计数，独立语音键，扩展索引折叠展示。
- 键盘、鼠标、滚轮与媒体动作；返回默认 Backspace。
- 多键差分、重复去重、缺失松开保护、原生输入独占和恢复。
- 管理员工具私有验签快照、设置备份恢复、父进程存活检测与异常恢复记录。
- 独立应用身份、配置及日志路径；公开仓库不含本机配置、抓包、录音、签名身份或 Apple 工具。
- 无特权测试与 macOS CI；管理员及硬件检查另行执行。
