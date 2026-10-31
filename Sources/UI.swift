import SwiftUI
import UniformTypeIdentifiers

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 10, height: 10)
    }
}

// Compact popover shown from the menu-bar icon: connection status + 设置 / 退出
struct StatusView: View {
    @ObservedObject var e: Engine
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google Remote Voice").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                row("蓝牙", e.btOn)
                row("遥控器连接", e.remoteConnected)
                row("语音通道就绪", e.handshakeReady)
                row("BlackHole 声卡", e.blackholeFound)
                row("谷歌按键接收", e.googleCapture.ready)
                if e.micStreaming {
                    HStack(spacing: 8) { StatusDot(ok: true); Text("🎤 正在采集语音").foregroundColor(.green) }
                }
            }
            Divider()
            HStack {
                Button(action: onSettings) {
                    Label("设置…", systemImage: "slider.horizontal.3")
                }.keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("退出", action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in e.checkPermissions() }
    }
    func row(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) { StatusDot(ok: ok); Text(name); Spacer()
            Text(ok ? "正常" : "未就绪").font(.caption).foregroundColor(ok ? .green : .orange) }
    }
}

struct ContentView: View {
    @ObservedObject var e: Engine
    @State private var learning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Google Remote Voice · 语音输入与按键映射")
                    .font(.title2).bold()

                permissions
                Divider()
                connection
                Divider()
                googleReceiver
                Divider()
                voiceRow
                Divider()
                buttonsSection
                Divider()
                logSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 840, minHeight: 640)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            e.checkPermissions()
        }
    }

    var googleReceiver: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Google 遥控器按键接收").font(.headline)
            HStack {
                StatusDot(ok: e.googleCapture.ready)
                Text(e.googleCapture.status).font(.callout)
                Spacer()
                if e.googleCapture.active {
                    Button("停止并恢复设置") { e.stopGoogleCapture() }
                } else {
                    Button("开启按键接收") { e.startGoogleCapture(testOnly: e.googleTestMode) }
                    Button("选择工具…") { e.googleCapture.selectPacketLogger() }
                }
            }
            if !e.googleInputIssue.isEmpty { Text(e.googleInputIssue).font(.caption).foregroundColor(.orange) }
            Toggle("按键检测模式（只登记按键，不执行映射）", isOn: Binding(
                get: { e.googleTestMode }, set: { e.setGoogleTestMode($0) }))
            HStack {
                Text("实体按键已收到：\(GVRMap.physicalUsages.filter { (e.googleButtonCounts[$0] ?? 0) > 0 }.count)/\(GVRMap.physicalUsages.count)")
                    .font(.caption).foregroundColor(.secondary)
                Button("重置检测记录") { e.resetGoogleValidation() }.font(.caption)
            }
            Text("开启时需要管理员授权；只保留遥控器按键事件，停止或退出会恢复原蓝牙日志设置。语音仍走独立通道。")
                .font(.caption).foregroundColor(.secondary)
            Text("首次使用建议打开检测模式，依次按完所有键；然后关闭检测模式即可使用映射。")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("权限与依赖").font(.headline)
            permRow("蓝牙", e.btOn, action: nil, hint: "系统设置里打开蓝牙")
            permRow("辅助功能（合成/拦截按键必需）", e.axTrusted, action: { e.requestAX(); e.openAXSettings() }, hint: "点右侧授权")
            permRow("输入监控（读取遥控器按键必需）", e.inputMonitoringOK, action: { e.requestInputMonitoring(); e.openInputMonitoringSettings() }, hint: "点右侧授权")
            permRow("BlackHole 虚拟声卡（当麦克风用）", e.blackholeFound, action: nil, hint: "需安装 BlackHole")
            Toggle("开机自动启动", isOn: Binding(
                get: { e.launchAtLogin },
                set: { e.setLaunchAtLogin($0) }))
                .padding(.top, 4)
        }
    }
    func permRow(_ name: String, _ ok: Bool, action: (() -> Void)?, hint: String) -> some View {
        HStack {
            StatusDot(ok: ok)
            Text(name)
            Spacer()
            if !ok, let a = action {
                Button("去授权", action: a)
            } else if !ok {
                Text(hint).foregroundColor(.secondary).font(.caption)
            } else {
                Text("正常").foregroundColor(.green).font(.caption)
            }
        }
    }

    var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("遥控器连接").font(.headline)
            HStack { StatusDot(ok: e.remoteConnected); Text(e.remoteConnected ? "已连接：\(e.remoteName.isEmpty ? "语音遥控器" : e.remoteName)" : "未连接（请在系统蓝牙里配对连接遥控器）") }
            HStack { StatusDot(ok: e.handshakeReady); Text(e.handshakeReady ? "语音通道就绪" : "语音通道未就绪") }
            if e.micStreaming { HStack { StatusDot(ok: true); Text("🎤 正在采集语音 → BlackHole").foregroundColor(.green) } }
        }
    }

    // one row: physical button -> recorded target key, with 录制 / 清除 buttons
    func mappingRow(usage: Int, name: String, display: String) -> some View {
        let capturing = (e.capturingUsage == usage)
        return HStack(spacing: 10) {
            Text(name).frame(width: 110, alignment: .leading)
            if usage >= 1 && usage <= 17 {
                Text((e.googleButtonCounts[usage] ?? 0) > 0 ? "✓ \(e.googleButtonCounts[usage] ?? 0)" : "未收到")
                    .font(.caption).foregroundColor((e.googleButtonCounts[usage] ?? 0) > 0 ? .green : .secondary).frame(width: 48)
            } else if usage >= 0 {
                Text("原键").font(.caption).foregroundColor(.secondary).frame(width: 48)
            } else {
                Text("语音").font(.caption).foregroundColor(.secondary).frame(width: 44)
            }
            Image(systemName: "arrow.right").foregroundColor(.secondary)
            // current mapping / capture state
            Text(capturing ? "⌨️ 请按键盘上的键…" : display)
                .foregroundColor(capturing ? .blue : .primary)
                .frame(width: 170, alignment: .leading)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(capturing ? 0.18 : 0.08)))
            if capturing {
                Button("取消") { e.cancelCapture() }
            } else {
                Button("录制") { e.beginCapture(usage: usage) }
                Menu("动作") {
                    if [14, 15].contains(usage) {
                        Button("打开应用…") { chooseApplication(usage: usage) }
                        Button("打开网址…") { chooseWebsite(usage: usage) }
                        Button(usage == 14 ? "设为打开 YouTube" : "设为打开 Netflix") {
                            e.setLaunchTarget(usage: usage, url: URL(string: usage == 14 ? "https://www.youtube.com/" : "https://www.netflix.com/")!)
                        }
                        Divider()
                    }
                    ForEach(KeyNames.specials, id: \.code) { sp in
                        Button(sp.name) { e.setSpecial(usage: usage, keycode: sp.code) }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 92)
                if [14, 15].contains(usage) {
                    Button("测试") { e.testMapping(usage: usage) }
                }
                Button("清除") { e.clearMapping(usage: usage) }.foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    func chooseApplication(usage: Int) {
        let panel = NSOpenPanel()
        panel.title = "选择这个遥控器按键要打开的应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { e.setLaunchTarget(usage: usage, url: url) }
    }
    func chooseWebsite(usage: Int) {
        let alert = NSAlert()
        alert.messageText = "设置按键打开的网址"
        alert.informativeText = "请输入完整的 http:// 或 https:// 网址，保存后立即生效。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = e.config.buttons.first(where: { $0.usage == usage })?.launchURL.flatMap { $0.isFileURL ? nil : $0.absoluteString } ?? "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false {
                e.setLaunchTarget(usage: usage, url: url)
                return
            }
            alert.informativeText = "网址无效，请输入带域名的 http:// 或 https:// 网址。"
        }
    }

    var voiceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语音键").font(.headline)
            mappingRow(usage: -1, name: "语音键", display: e.config.voice.display)
            Toggle("同时开启麦克风（灌入 BlackHole）", isOn: Binding(
                get: { e.config.voiceStartsMic },
                set: { e.config.voiceStartsMic = $0; e.saveConfig() }))
            Text("按住语音键 = 按住所录制的键 + （可选）麦克风。").font(.caption).foregroundColor(.secondary)
        }
    }

    var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按键映射").font(.headline)
            Text("点「录制」后在 Mac 键盘上按目标键（支持组合键/修饰键）。").font(.caption).foregroundColor(.secondary)
            Group {
                HStack {
                    Text("YouTube / Netflix：点“动作”选择应用或网址，也可“录制”快捷键。修改自动保存，可点“测试”。")
                        .font(.caption).foregroundColor(.secondary)
                    Button("恢复谷歌默认映射") { e.useGoogleDefaults() }
                }
            }
            ForEach(e.config.buttons.filter { GVRMap.physicalUsages.contains($0.usage) }) { b in
                mappingRow(usage: b.usage, name: b.name, display: b.display)
            }
            Group {
                DisclosureGroup("扩展按键（仅部分型号有）") {
                    ForEach(e.config.buttons.filter { (1...17).contains($0.usage) && !GVRMap.physicalUsages.contains($0.usage) }) { b in
                        mappingRow(usage: b.usage, name: b.name, display: b.display)
                    }
                }
            }
        }
    }

    var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("日志").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(e.log.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 140).background(Color.gray.opacity(0.08)).cornerRadius(6)
        }
    }
}
