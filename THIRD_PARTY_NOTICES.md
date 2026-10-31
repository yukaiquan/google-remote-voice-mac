# 来源、第三方与许可证

## 代码基础

**mi-remote-mapper — 零度汉化**
https://github.com/81199000/mi-remote-mapper
MIT。保留原仓库提交历史、原始版权以及 LICENSE。菜单栏应用、音频输出、设置与映射基础来自该项目；本扩展聚焦 Google 遥控器。

## 协议与诊断参考

- https://github.com/zfdang/voice-input-buddy — G9N9N 描述符与公开抓包证据边界。
- https://github.com/b0o/ATVVoice — ATVV 协议/会话研究参考；不将其其他样机结果当作本项目验收。
- https://github.com/Tilkmilk/vibe-mote — Google 遥控器 Windows 旁路输入实现参考，平台代码未移植为 macOS 驱动。
- https://github.com/HOLODATA-COM/SiriRemoteForge — 按需 PacketLogger 接收的研究参考，Siri Remote 的验收不等于 G9N9N 验收。
- https://github.com/apple-oss-distributions/IOHIDFamily — HID 处理与报告长度检查参考。

这些项目是研究来源，不表示它们为本项目背书，也不改变各自许可证。协议 UUID、按键 usage 和线格式属于互操作事实；不捆绑这些项目的应用、驱动或二进制。

## 单独安装的依赖

- **BlackHole**：https://github.com/ExistentialAudio/BlackHole ，GPL-3.0。作为用户单独安装的系统音频驱动使用；本仓库不打包其驱动或源代码。
- **Apple PacketLogger**：https://developer.apple.com/bluetooth/ ，Apple 工具，遵守其下载与使用条款。本仓库/源码发行不打包、转售或重新发布 PacketLogger、Additional Tools、Apple 诊断描述文件。
- **Handy**：https://github.com/cjpais/Handy ，可选外部语音识别工具，独立安装并遵守其许可证。本应用没有捆绑它或任何语音模型。

Google、Chromecast、Apple 等商标属于相应权利人；本项目是独立社区项目。
