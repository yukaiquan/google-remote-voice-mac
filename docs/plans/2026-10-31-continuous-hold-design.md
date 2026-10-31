# 连续长按语音设计（2026-10-31）

## 用户选择

一直按住语音键，连续说几分钟；松开后一次转写。不改为点按切换。Handy继续使用push-to-talk，BlackHole输入与右Command绑定保持一致。

## 方案

仅放宽输入法时长无法维持遥控器的协议会话。采用ATVV v1.0 MIC_EXTEND保活：从AUDIO_START完整控制包取得实际stream ID，录音中每5秒发送[0x0E, streamID]。重复AUDIO_START不得重新触发输入法或推迟保活；松开、断线、退出清空会话，不再发送。保持现有低延迟连接、可调固定增益、按键配置。

普通键的8秒缺失松开保护只处理普通键，不用于语音；不删除安全保护。若遥控器主动停止，记录原因并结束输入，不能伪装仍在录音或无限重开。

## 验收

纯测试覆盖真实会话ID、重复通知、定时边界、持续多分钟、松开/断线/退出取消与无效控制数据。硬件至少连续长按3分钟，检查约50包/秒、保活次数、无中途停止；松开后确认Handy只生成一次记录/输出。只记录计数/时序，不保存在仓库中的原始音频或私人转写。

## Checklist

- [x] Explore project context
- [x] Clarify interaction: user selected continuous hold
- [x] Compare input-method-only change and protocol keepalive
- [x] Present continuous-hold design within the user's authorized request
- [x] Write design
- [x] Write implementation plan
- [ ] Test, implement, validate hardware and publish

## 用户追加要求：默认开启接收

应用启动且目标Google遥控器、语音握手、唯一HID、权限及Apple工具就绪后，默认自动尝试开启普通按键接收。每次应用运行只自动尝试一次；取消授权或失败不循环弹窗。手动停止后本次运行不自动重开。提供可保存的自动开启选项，旧配置默认开启。管理员授权仍由系统要求；不安装常驻root服务、不绕过授权。语音通道独立，不把按键开关与语音是否工作混为一谈。

低延迟在每次语音开始及保活时重新请求，避免长时间闲置后只保留启动时请求而连接退慢。安装脚本在替换后立即重新打开应用，减少更新期间没有进程而不出字的间隙。
