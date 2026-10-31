# 诊断与回归工具

日常使用请运行主应用。这些独立诊断工具不合成输入；原始捕获应保存在仓库外。

## 纯逻辑测试

```sh
sh scripts/run-tests.sh
```

覆盖 Swift 按键状态、接收策略、设置恢复和模型，以及 Python 协议解析。无需管理员权限。

## HID 观察器

```sh
swiftc scripts/diagnose-chromecast-hid.swift -o /tmp/chromecast-hid-observer
/tmp/chromecast-hid-observer 120
```

按 VID/PID 匹配，观察报告、元素和设备连接，需要输入监控权限。它不能替代完整接收器。

## PacketLogger 离线解析器

将 Apple PacketLogger `convert -f ipnhdsr` 文本作为标准输入：

```sh
python3 scripts/chromecast_packet_events.py --attribute 0x46 < /path/to/decoded-capture.txt
```

`0x46` 仅在已测试样机中验证，不是所有遥控器的通用常量。此诊断解析器按设备名、方向和 attribute 过滤；生产接收器还绑定选定连接的设备标识，处理释放、超时和退出恢复。不要为了运行离线解析器开启全机蓝牙日志。

提交问题请使用合成或脱敏的按键序列，不要上传原始捕获、音频或设备标识。
