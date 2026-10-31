import Foundation
import CoreBluetooth
import AVFoundation
import CoreAudio
import CoreGraphics
import ApplicationServices
import IOKit.hid
import Combine
import AppKit
import ServiceManagement

// magic marker so our own synthetic CGEvents are ignored by our tap
let kSyntheticMarker: Int64 = 0x4D49_5245  // "MIRE"

@MainActor
final class Engine: ObservableObject {
    // status published to UI
    @Published var btOn = false
    @Published var remoteConnected = false
    @Published var remoteName = ""
    @Published var handshakeReady = false
    @Published var blackholeFound = false
    @Published var axTrusted = false
    @Published var inputMonitoringOK = false
    @Published var micStreaming = false
    @Published var lastButton = ""            // last raw button seen (for Learn)
    @Published var lastButtonUsage: Int = 0
    @Published var capturingUsage: Int? = nil // which button is currently recording a key (-1 = voice)
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Published var log: [String] = []

    var config = ConfigStore.load()

    private let ring = Ring(16000 * 4)
    private var codec = ADPCM()
    private var dsp = VoiceDSP()
    // ATVV 音频：连续字节流，无帧头；按 frameSize 切帧，CTL 0x0A 同步在帧边界生效
    private var audioBuf = Data()
    private var frameSize = 160
    private var pendingSync: (pred: Int32, idx: Int32)?
    private var syncWait = 0
    private var voiceSession = VoiceSession()
    private var captureStartup = CaptureStartup()
    private var voiceStartedAt = 0.0
    private var voiceRXCount = 0
    private var voiceRXBegan = 0.0
    private var voiceRXEnded = 0.0
    @Published private(set) var isGoogleRemote = false
    let googleCapture = GoogleCapture()
    @Published var googleTestMode = false
    @Published var googleButtonCounts: [Int: Int] = [:]
    @Published private(set) var googleInputIssue = ""
    private var googleHIDDevices: [Int: IOHIDDevice] = [:]
    private var googleSeized: Set<Int> = []
    private var capturePeripheralID: String?
    private var googleState = GoogleButtonState()
    private var googleTargets: [Int: ButtonMapping] = [:]
    private var googleRepeatAt: [Int: TimeInterval] = [:]
    private var lastGooglePacketAt = 0.0
    private var googleCaptureChanges: AnyCancellable?
    private var googleWatchdog: Timer?
    private var voiceTarget: ButtonMapping?
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!

    // BLE
    private var cm: CBCentralManager!
    private var dev: CBPeripheral?
    private var tx: CBCharacteristic?
    private var capsSent = false
    private var streaming = false

    // HID
    private var hidMgr: IOHIDManager?
    private var hidBufs: [UnsafeMutablePointer<UInt8>] = []
    private var lastHidKeycodeAt: [CGKeyCode: TimeInterval] = [:]
    private var voiceHidDown = false   // 语音键的 HID F5 正被按住（需持续吞掉）
    private var downButtonUsage: Int = 0
    private var downTarget: ButtonMapping?
    private var legacyFilter = LegacyPressFilter()
    private var keyMonitor: Any?

    // event tap
    private var tap: CFMachPort?
    private var proxy: BTProxy!

    private let ATVV = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private let TX = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private let RX = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private let CTL = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    // 只按 ATVV 语音服务检索；CoreBluetooth 不暴露系统 HID 服务。
    // 而 180F 电池服务会把蓝牙键盘/鼠标一起误抓进来导致连错设备
    private let seed = [CBUUID(string:"AB5E0001-5A21-4F05-BC7D-AF01F617B664")]

    static let logFile: FileHandle? = {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/GoogleRemoteVoice")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p = folder.appendingPathComponent("engine.log").path
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    func L(_ s: String) {
        NSLog("[GoogleRemoteVoice] %@", s)
        Engine.logFile?.write((s + "\n").data(using: .utf8)!)
        log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // ---------- lifecycle ----------
    func start() {
        L("启动: 1/8 初始化")
        proxy = BTProxy(self)
        ConfigStore.save(config)   // persist merged button list (power/menu/TV/volume)
        L("启动: 2/8 配置已存")
        setupAudio()
        L("启动: 3/8 音频就绪")
        checkPermissions()
        L("启动: 4/8 权限检查完成 (AX=\(axTrusted) IM=\(inputMonitoringOK) BH=\(blackholeFound))")
        cm = CBCentralManager(delegate: proxy, queue: nil)
        L("启动: 5/8 蓝牙管理器已建")
        installTap()
        L("启动: 6/8 拦截器 tap=\(tap != nil)")
        setupHID()
        setupGoogleCapture()
        L("启动: 7/8 HID 已设置")
        installKeyCapture()
        L("启动: 8/8 完成")
        // 守护定时器：① 授权后自动补装事件拦截；② 输出设备脱离 BlackHole 时自动重挂
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.audioWatchdog()
                self.maybeAutoStartGoogleCapture()
                if self.tap == nil, AXIsProcessTrusted() {
                    self.installTap()
                    if self.tap != nil { self.L("辅助功能已授权，事件拦截已启用") }
                }
            }
        }
    }

    // ---------- keyboard capture (record a target key) ----------
    func beginCapture(usage: Int) { releaseGoogleButtons(); capturingUsage = usage; L("请在键盘上按下要映射的键…") }
    func cancelCapture() { capturingUsage = nil }
    func clearMapping(usage: Int) {
        if usage == -1 { config.voice.keycode = KeyNames.kNone; config.voice.cmd = false; config.voice.shift = false; config.voice.opt = false; config.voice.ctrl = false }
        else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].openTarget = nil; config.buttons[i].keycode = KeyNames.kNone; config.buttons[i].cmd = false
            config.buttons[i].shift = false; config.buttons[i].opt = false; config.buttons[i].ctrl = false
        }
        saveConfig()
    }
    private var pendingCaptureMod: UInt16? = nil   // 录制中按住的修饰键（等松开或组合普通键）
    private func installKeyCapture() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self = self, self.capturingUsage != nil else { return ev }
            let loneMods: Set<UInt16> = [0x36,0x37,0x38,0x3C,0x3A,0x3D,0x3B,0x3E,0x39,0x3F]
            let f = ev.modifierFlags
            if ev.type == .keyDown {
                // 普通键落下：连同当前按住的修饰键一起录成组合
                self.pendingCaptureMod = nil
                self.applyCapture(keycode: Int(ev.keyCode),
                                  cmd: f.contains(.command), shift: f.contains(.shift),
                                  opt: f.contains(.option), ctrl: f.contains(.control))
                return nil // swallow this key so it doesn't act while recording
            }
            // flagsChanged：修饰键按下先挂起，等松开时才录成"单独修饰键"，给组合留机会
            guard loneMods.contains(ev.keyCode) else { return nil }
            let active: Bool
            switch ev.keyCode {
            case 0x36,0x37: active = f.contains(.command)
            case 0x38,0x3C: active = f.contains(.shift)
            case 0x3A,0x3D: active = f.contains(.option)
            case 0x3B,0x3E: active = f.contains(.control)
            case 0x39:      active = f.contains(.capsLock)
            case 0x3F:      active = f.contains(.function)
            default:        active = false
            }
            if active { self.pendingCaptureMod = ev.keyCode; return nil }
            // 松开：只有它是最后按下的挂起修饰键才录制（含其余仍按住的修饰键 → 支持纯修饰键组合）
            guard self.pendingCaptureMod == ev.keyCode else { self.pendingCaptureMod = nil; return nil }
            self.pendingCaptureMod = nil
            var cmd = f.contains(.command), shift = f.contains(.shift), opt = f.contains(.option), ctrl = f.contains(.control)
            switch ev.keyCode {   // 自身类别也算按下（目标 App 靠 flag 识别修饰键）
            case 0x36,0x37: cmd = true
            case 0x38,0x3C: shift = true
            case 0x3A,0x3D: opt = true
            case 0x3B,0x3E: ctrl = true
            default: break
            }
            self.applyCapture(keycode: Int(ev.keyCode), cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
            return nil
        }
    }
    private func applyCapture(keycode: Int, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) {
        guard let usage = capturingUsage else { return }
        if usage == -1 {
            config.voice.keycode = keycode; config.voice.cmd = cmd; config.voice.shift = shift; config.voice.opt = opt; config.voice.ctrl = ctrl
        } else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].openTarget = nil; config.buttons[i].keycode = keycode; config.buttons[i].cmd = cmd
            config.buttons[i].shift = shift; config.buttons[i].opt = opt; config.buttons[i].ctrl = ctrl
        }
        let label = KeyNames.label(keycode: keycode, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
        L("已录制映射 → \(label)")
        capturingUsage = nil
        saveConfig()
    }

    func setLaunchTarget(usage: Int, url: URL) {
        guard [14, 15].contains(usage), let i = config.buttons.firstIndex(where: { $0.usage == usage }) else { return }
        var mapping = ButtonMapping(usage: usage, name: config.buttons[i].name, keycode: KeyNames.kOpenTarget)
        mapping.openTarget = url.absoluteString
        guard mapping.launchURL != nil else { L("仅支持 http/https 网址或 .app 应用"); return }
        releaseGoogleButtons()
        config.buttons[i] = mapping
        saveConfig()
    }
    func testMapping(usage: Int) {
        guard let mapping = config.buttons.first(where: { $0.usage == usage }) else { return }
        guard mapping.keycode == KeyNames.kOpenTarget || axTrusted else { L("测试快捷键需要辅助功能权限"); return }
        sendMapping(mapping, down: true)
        sendMapping(mapping, down: false)
    }

    func setVoiceGainDB(_ value: Double) {
        objectWillChange.send()
        config.voiceGainDB = value
        config.voiceGainDB = config.effectiveVoiceGainDB
        applyVoiceGain()
        ConfigStore.save(config)
    }
    private func applyVoiceGain() {
        dsp.gain = Float(pow(10, config.effectiveVoiceGainDB / 20))
    }

    func saveConfig() { ConfigStore.save(config); L("配置已保存") }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            L(on ? "已开启开机自启" : "已关闭开机自启")
        } catch {
            L("开机自启设置失败: \(error.localizedDescription)（App 需位于 /Applications）")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func checkPermissions() {
        let ax = AXIsProcessTrusted()
        let bh = Self.deviceID(named: "BlackHole") != nil
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if axTrusted != ax { axTrusted = ax }
        if blackholeFound != bh { blackholeFound = bh }
        if inputMonitoringOK != im { inputMonitoringOK = im }
    }
    func requestAX() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func requestInputMonitoring() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // ---------- audio ----------
    private func setupAudio() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        srcNode = AVAudioSourceNode(format: fmt) { [ring] _, _, frames, abl in
            let l = UnsafeMutableAudioBufferListPointer(abl)
            if let m = l[0].mData { ring.pop(m.assumingMemoryBound(to: Float.self), Int(frames)) }
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
        // 输出设备必须在节点接线完成之后再切到 BlackHole：
        // 访问 mainMixerNode 会重建输出单元并把设备重置回系统默认，之前设置的会被覆盖
        setOutputDevice()
        engine.prepare()
        do { try engine.start() } catch { L("音频引擎启动失败: \(error)") }
        verifyOutputDevice()
        // 设备配置变化（显示器休眠/重连、采样率切换等）会让引擎重建并重置回默认输出，必须重新挂载
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioWatchdog(reason: "配置变化通知") }
        }
    }
    func audioWatchdog(reason: String = "定时检查") {
        guard let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit else { return }
        var cur: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        guard cur != bh || !engine.isRunning else { return }
        L("⚠️ 音频输出脱离 BlackHole（\(reason)，当前设备 \(cur)），自动重新挂载…")
        engine.stop()
        setOutputDevice()
        engine.prepare()
        do { try engine.start() } catch { L("音频引擎重启失败: \(error)") }
        verifyOutputDevice()
    }
    private func setOutputDevice() {
        guard let bh = Self.deviceID(named: "BlackHole") else { L("⚠️ 未找到 BlackHole 声卡，语音无法当麦克风"); return }
        guard let u = engine.outputNode.audioUnit else { L("⚠️ 输出单元不可用"); return }
        var d = bh
        let st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { L("⚠️ 切换输出到 BlackHole 失败 (OSStatus \(st))") }
    }
    private func verifyOutputDevice() {
        guard let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit else { return }
        var cur: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        if cur == bh {
            L("音频输出已挂到 BlackHole (设备 \(bh))")
        } else {
            // 启动过程又被重置了：停机重设再启动
            L("⚠️ 输出设备被重置 (当前 \(cur))，重试切换 BlackHole…")
            engine.stop()
            setOutputDevice()
            engine.prepare()
            do { try engine.start() } catch { L("音频引擎重启失败: \(error)") }
            AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
            L(cur == bh ? "音频输出已挂到 BlackHole (设备 \(bh))" : "❌ 仍未能切到 BlackHole，语音无法当麦克风")
        }
    }
    static func deviceID(named target: String) -> AudioDeviceID? {
        var size = UInt32(0)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        let n = Int(size)/MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: n)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        for id in ids {
            var ns = UInt32(MemoryLayout<CFString?>.size); var name: CFString? = nil
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            withUnsafeMutablePointer(to: &name) { _ = AudioObjectGetPropertyData(id, &na, 0, nil, &ns, $0) }
            if let nm = name as String?, nm.contains(target) { return id }
        }
        return nil
    }

    // ---------- BLE (ATVV voice + mic) ----------
    fileprivate func btStateChanged(_ c: CBCentralManager) {
        btOn = (c.state == .poweredOn)
        if btOn { connectRemote() }
        else { L("⚠️ 蓝牙不可用 (state \(c.state.rawValue)：3=未授权 4=未开启)，请检查蓝牙权限/开关") }
    }
    func connectRemote() {
        guard let c = cm, c.state == .poweredOn else { return }
        if let d = c.retrieveConnectedPeripherals(withServices: seed).first(where: { peripheral in
            let name = (peripheral.name ?? "").lowercased()
            return name.contains("chromecast") || name.contains("g9n9n")
        }) {
            L("发现遥控器 \(d.name ?? "?")，连接语音通道…")
            dev = d; d.delegate = proxy; capsSent = false; c.connect(d, options: nil)
        } else {
            L("未发现带 ATVV 语音服务的已连接遥控器（检查遥控器是否已在系统蓝牙连接/本 App 蓝牙权限），3 秒后重试…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connectRemote() }
        }
    }
    fileprivate func didFailConnect(_ p: CBPeripheral, _ err: Error?) {
        L("⚠️ 遥控器连接失败: \(err?.localizedDescription ?? "未知")，3 秒后重试")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connectRemote() }
    }
    fileprivate func didConnect(_ p: CBPeripheral) {
        remoteConnected = true; remoteName = p.name ?? "语音遥控器"
        let n = (p.name ?? "").lowercased()
        isGoogleRemote = n.contains("chromecast") || n.contains("g9n9n")
        if isGoogleRemote { UserDefaults.standard.set(p.identifier.uuidString, forKey: "GooglePeripheralID") }
        if googleCapture.active, let capturePeripheralID, capturePeripheralID != p.identifier.uuidString.uppercased() {
            stopGoogleCapture(); googleInputIssue = "连接的遥控器已变化，已停止原会话；请重新开启接收"
        }
        syncGoogleHIDAccess()
        codec.highFirst = isGoogleRemote   // Google 固件高 nibble 在前
        if isGoogleRemote, let cm {
            if GoogleVoiceLink.request(central: cm, peripheral: p, lowLatency: true) {
                L("已请求谷歌遥控器低延迟语音连接；松开语音键后可查看实际包速率")
            } else {
                L("⚠️ 当前系统不支持低延迟语音请求，音频可能缺帧")
            }
        }
        p.discoverServices([ATVV])
    }
    fileprivate func didDisconnect() {
        voiceSession.stop()
        releaseGoogleButtons()
        if streaming { voiceButton(down: false) }
        hidReport(usage: 0)
        remoteConnected = false; handshakeReady = false; streaming = false; micStreaming = false; tx = nil
        syncGoogleHIDAccess()
        connectRemote()
    }
    fileprivate func didServices(_ p: CBPeripheral) {
        if let s = p.services?.first(where: { $0.uuid == ATVV }) { p.discoverCharacteristics([TX,RX,CTL], for: s) }
        else { L("⚠️ \(p.name ?? "遥控器") 没有 ATVV 语音服务") }
    }
    fileprivate func didChars(_ p: CBPeripheral, _ s: CBService) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == TX { tx = ch }
            else if ch.uuid == RX || ch.uuid == CTL { p.setNotifyValue(true, for: ch) }
        }
    }
    fileprivate func didNotify(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        if ch.uuid == CTL && ch.isNotifying && !capsSent, let tx = tx {
            capsSent = true
            // ATVV caps 请求；TX 特征只支持无响应写（props=4），用 withResponse 会被静默拒绝
            let wt: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
            p.writeValue(Data([0x0A,0x01,0x00,0x00,0x03,0x03]), for: tx, type: wt)
            L("已发语音能力请求，等待遥控器应答…")
        }
    }
    fileprivate func didValue(_ p: CBPeripheral, uuid: CBUUID, data d: Data) {
        if uuid == RX {
            guard streaming else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if voiceRXCount == 0 { voiceRXBegan = now }
            voiceRXCount += 1; voiceRXEnded = now
            // 连续 ADPCM 字节流：攒到 frameSize 切帧；CTL 0x0A 同步在帧边界生效
            audioBuf.append(d)
            while audioBuf.count >= frameSize {
                let frame = audioBuf.prefix(frameSize)
                audioBuf.removeFirst(frameSize)
                if let s = pendingSync {
                    if syncWait == 0 { codec.pred = s.pred; codec.idx = s.idx; pendingSync = nil }
                    else { syncWait -= 1 }
                }
                ring.push(dsp.process(codec.decode(frame)))
            }
        } else if uuid == CTL, let f = d.first {
            switch f {
            case 0x0B:   // 能力应答：真握手完成的标志；帧长 d[5]d[6] 大端
                if d.count >= 7 {
                    let fs = (Int(d[5]) << 8) | Int(d[6])
                    if fs > 0 { frameSize = min(fs, 512) }
                }
                if !handshakeReady { handshakeReady = true; L("语音握手完成（帧长 \(frameSize)），随时可用") }
            case 0x08:   // 请求开麦：必须回 0C 00，否则没有音频流
                if isGoogleRemote, let cm { _ = GoogleVoiceLink.request(central: cm, peripheral: p, lowLatency: true) }
                if let tx = tx {
                    let wt: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
                    p.writeValue(Data([0x0C,0x00]), for: tx, type: wt)
                }
            case 0x0A:   // 解码器状态同步：预测器 d[4]d[5] 大端 int16，步长索引 d[6]
                if d.count >= 7 {
                    pendingSync = (Int32(Int16(bitPattern: (UInt16(d[4]) << 8) | UInt16(d[5]))), min(88, Int32(d[6])))
                    syncWait = audioBuf.isEmpty ? 0 : 1
                }
            case 0x04:
                if isGoogleRemote {
                    if let cm { _ = GoogleVoiceLink.request(central: cm, peripheral: p, lowLatency: true) }
                    _ = voiceSession.begin(d, at: ProcessInfo.processInfo.systemUptime)
                    if voiceSession.streamID == nil { L("⚠️ 缺少有效语音会话信息，无法启用长录音保活") }
                }
                voiceButton(down: true)
            case 0x00:
                if d.count >= 2 { L(String(format: "遥控器结束语音（原因 0x%02X）", d[1])) }
                voiceButton(down: false)
            case 0x0C:
                if d.count >= 3 {
                    L(String(format: "⚠️ 遥控器语音命令被拒绝（0x%02X%02X）", d[1], d[2]))
                }
            default: break
            }
        }
    }
    private func voiceButton(down: Bool) {
        guard down != streaming else { return }
        if down { voiceTarget = config.voice }
        let v = voiceTarget ?? config.voice
        // BLE 通道也标记语音键状态：与 HID 报告双保险，谁先到谁立标记，确保原生 F5 被吞
        voiceHidDown = down
        lastHidKeycodeAt[HIDMap.voiceKeycode] = ProcessInfo.processInfo.systemUptime
        if down {
            voiceStartedAt = ProcessInfo.processInfo.systemUptime
            voiceRXCount = 0; voiceRXBegan = 0; voiceRXEnded = 0
            codec.reset(); dsp.reset(); applyVoiceGain(); audioBuf.removeAll(); pendingSync = nil; syncWait = 0
            streaming = true; micStreaming = config.voiceStartsMic
            if v.keycode >= KeyNames.kSpecialBase { startSpecial(v.keycode) }
            else if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: true, cmd: v.cmd, shift: v.shift, opt: v.opt, ctrl: v.ctrl) }
            L("🎤 语音键按下 → \(v.display)\(config.voiceStartsMic ? " + 麦克风开" : "")")
        } else {
            voiceSession.stop()
            streaming = false; micStreaming = false
            if v.keycode >= KeyNames.kSpecialBase { stopSpecial(v.keycode) }
            else if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: false, cmd: false) }
            L("语音键松开")
            let elapsed = max(0, voiceRXEnded - voiceRXBegan)
            L(String(format: "语音接收统计：%d 包 / %.2f 秒（%.1f 包/秒），长录音保活 %d 次", voiceRXCount, elapsed, elapsed > 0 ? Double(max(0, voiceRXCount - 1)) / elapsed : 0, voiceSession.sentCount))
            voiceTarget = nil
        }
    }

    // ---------- Google raw notification input (single-byte reports bypass IOHID) ----------
    private func setupGoogleCapture() {
        if let saved = UserDefaults.standard.dictionary(forKey: "GoogleButtonCounts") {
            for (key, value) in saved { if let key = Int(key), let number = value as? Int { googleButtonCounts[key] = number } }
        }
        googleCaptureChanges = googleCapture.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor in self?.syncGoogleHIDAccess() }
        }
        googleCapture.onRecord = { [weak self] record in self?.googleRecord(record) }
        googleWatchdog = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.googleTick() }
        }
    }
    private func maybeAutoStartGoogleCapture() {
        guard config.effectiveAutoStartGoogleCapture, !googleCapture.active,
              !streaming, capturingUsage == nil else { return }
        checkPermissions()
        let ready = remoteConnected && isGoogleRemote && handshakeReady
            && inputMonitoringOK && axTrusted && googleHIDDevices.count == 1
            && GoogleCapture.packetLogger != nil
        if captureStartup.shouldStart(enabled: config.effectiveAutoStartGoogleCapture, ready: ready, active: googleCapture.active) {
            L("应用启动后自动开启谷歌按键接收")
            startGoogleCapture(testOnly: googleTestMode)
        }
    }
    func setAutoStartGoogleCapture(_ enabled: Bool) {
        config.autoStartGoogleCapture = enabled
        if enabled { captureStartup.reset() } else { captureStartup.suppress() }
        saveConfig()
        if enabled { maybeAutoStartGoogleCapture() }
    }
    func startGoogleCapture(testOnly: Bool = false) {
        releaseGoogleButtons(); googleTestMode = testOnly
        checkPermissions()
        guard inputMonitoringOK else { googleInputIssue = "请先授予输入监控权限，用于阻止遥控器原生动作重复触发"; return }
        guard googleHIDDevices.count == 1 else { googleInputIssue = "请唤醒遥控器，并只连接一支 Chromecast Remote 后再开启"; return }
        let identifier = isGoogleRemote ? dev?.identifier.uuidString : UserDefaults.standard.string(forKey: "GooglePeripheralID")
        guard let identifier else { L("请先连接 Chromecast Remote，让应用识别该设备"); return }
        capturePeripheralID = identifier.uppercased()
        captureStartup.markAttempted()
        googleCapture.start(peripheralID: identifier)
        syncGoogleHIDAccess()
    }
    func stopGoogleCapture() { captureStartup.suppress(); releaseGoogleButtons(); googleCapture.stop() }
    func setGoogleTestMode(_ enabled: Bool) { releaseGoogleButtons(); googleTestMode = enabled }
    func useGoogleDefaults() {
        releaseGoogleButtons(); config.installGoogleDefaults(overwrite: true); saveConfig()
    }
    func resetGoogleValidation() {
        googleButtonCounts.removeAll(); UserDefaults.standard.removeObject(forKey: "GoogleButtonCounts")
    }
    private func googleRecord(_ record: GoogleCaptureRecord) {
        switch record.kind {
        case "buttons":
            lastGooglePacketAt = ProcessInfo.processInfo.systemUptime
            for edge in googleState.update(record.buttons) { googleEdge(edge) }
        case "connected", "disconnected", "stopped", "error":
            releaseGoogleButtons()
            if !record.message.isEmpty { L(record.message) }
        case "ready": L(record.message)
        default: break
        }
    }
    private func googleEdge(_ edge: GoogleKeyEdge) {
        let now = ProcessInfo.processInfo.systemUptime
        if let native = GVRMap.usageToKeycode[UInt8(edge.button)] { lastHidKeycodeAt[native] = now }
        if edge.down {
            googleButtonCounts[edge.button, default: 0] += 1
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: googleButtonCounts.map { (String($0.key), $0.value) }), forKey: "GoogleButtonCounts")
            lastButtonUsage = edge.button
            let mapping = config.buttons.first(where: { $0.usage == edge.button })
            lastButton = mapping?.name ?? "Google \(edge.button)"
            L("Google [\(lastButton)] 按下\(googleTestMode ? "（检测）" : " → \(mapping?.display ?? "未配置")")")
            guard !googleTestMode, capturingUsage == nil, axTrusted, !googleSeized.isEmpty,
                  let mapping, mapping.keycode != KeyNames.kNone else { return }
            let alreadyDown = googleTargets.values.contains(where: { $0.actionID == mapping.actionID })
            googleTargets[edge.button] = mapping
            googleRepeatAt[edge.button] = now + 0.5
            if !alreadyDown { sendMapping(mapping, down: true) }
        } else {
            googleRepeatAt.removeValue(forKey: edge.button)
            guard let mapping = googleTargets.removeValue(forKey: edge.button) else { return }
            if !googleTargets.values.contains(where: { $0.actionID == mapping.actionID }) { sendMapping(mapping, down: false) }
        }
    }
    private func sendMapping(_ mapping: ButtonMapping, down: Bool, repeatKey: Bool = false) {
        if mapping.keycode == KeyNames.kOpenTarget {
            if down && !repeatKey {
                guard let url = mapping.launchURL else { L("打开失败：目标无效，请重新设置应用或网址"); return }
                if !NSWorkspace.shared.open(url) { L("打开失败：系统无法打开所选应用或网址") }
            }
        } else if mapping.keycode >= KeyNames.kSpecialBase {
            if down { startSpecial(mapping.keycode) } else { stopSpecial(mapping.keycode) }
        } else if mapping.keycode != KeyNames.kNone {
            postKey(CGKeyCode(mapping.keycode), down: down, cmd: mapping.cmd, shift: mapping.shift, opt: mapping.opt, ctrl: mapping.ctrl, autorepeat: repeatKey)
        }
    }
    private func releaseGoogleButtons() {
        _ = googleState.releaseAll()
        let unique = Dictionary(googleTargets.values.map { ($0.actionID, $0) }, uniquingKeysWith: { a, _ in a })
        googleTargets.removeAll(); googleRepeatAt.removeAll()
        for mapping in unique.values { sendMapping(mapping, down: false) }
    }
    private func googleTick() {
        let now = ProcessInfo.processInfo.systemUptime
        if streaming, isGoogleRemote,
           VoiceSession.audioStalled(at: now, startedAt: voiceStartedAt, lastAudioAt: voiceRXCount > 0 ? voiceRXEnded : nil) {
            if let id = voiceSession.streamID, let dev, dev.state == .connected, let tx, dev.canSendWriteWithoutResponse {
                dev.writeValue(Data([0x0D, id]), for: tx, type: tx.properties.contains(.write) ? .withResponse : .withoutResponse)
            }
            voiceButton(down: false)
            L("⚠️ 连续3秒未收到音频数据，已结束本次输入；请重新按住语音键")
        }
        if streaming, isGoogleRemote, let dev, dev.state == .connected, let tx {
            let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
            if type == .withResponse || dev.canSendWriteWithoutResponse,
               let command = voiceSession.poll(at: now) {
                if let cm { _ = GoogleVoiceLink.request(central: cm, peripheral: dev, lowLatency: true) }
                dev.writeValue(command, for: tx, type: type)
                if voiceSession.sentCount % 6 == 0 {
                    let elapsed = max(0.001, now - voiceRXBegan)
                    L(String(format: "语音持续录音中：保活 %d 次，已接收 %d 包（%.1f 包/秒）", voiceSession.sentCount, voiceRXCount, Double(max(0, voiceRXCount - 1)) / elapsed))
                }
            }
        }
        if !googleState.held.isEmpty && now - lastGooglePacketAt > 8 {
            releaseGoogleButtons(); L("Google 缺失松开保护：已释放所有按键（单次按住上限 8 秒）")
        }
        var repeated: Set<String> = []
        for (button, mapping) in googleTargets where mapping.keycode < KeyNames.kSpecialBase {
            guard now >= (googleRepeatAt[button] ?? .infinity), !repeated.contains(mapping.actionID) else { continue }
            // Modifier-only actions should remain held, never generate fake repeat edges.
            guard ![0x36,0x37,0x38,0x3C,0x3A,0x3D,0x3B,0x3E,0x39,0x3F].contains(mapping.keycode) else { continue }
            sendMapping(mapping, down: true, repeatKey: true); repeated.insert(mapping.actionID)
            googleRepeatAt[button] = now + 0.08
        }
    }
    func shutdown() {
        voiceSession.stop()
        if isGoogleRemote, let cm, let dev {
            _ = GoogleVoiceLink.request(central: cm, peripheral: dev, lowLatency: false)
        }
        stopGoogleCapture()
        if streaming { voiceButton(down: false) }
        hidReport(usage: 0)
        googleWatchdog?.invalidate(); googleWatchdog = nil
    }

    // ---------- HID reading ----------
    // 此分支只匹配 Google（Chromecast Remote）厂商
    private static let remoteVendors: Set<Int> = [0x18D1]
    private var openedHIDs: Set<Int> = []   // 已注册报告回调的设备 UniqueID（可达 UInt32 上限以上，用 Int）

    private func syncGoogleHIDAccess() {
        let exclusive = GoogleCapturePolicy.shouldSeize(active: googleCapture.active,
            deviceCount: googleHIDDevices.count, connected: remoteConnected && isGoogleRemote,
            currentID: dev?.identifier.uuidString, sessionID: capturePeripheralID)
        if !exclusive { releaseGoogleButtons() }
        for (id, device) in googleHIDDevices {
            if exclusive && !googleSeized.contains(id) {
                IOHIDDeviceClose(device, 0)
                let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                if result == kIOReturnSuccess {
                    googleSeized.insert(id); googleInputIssue = ""
                    L("Google 原生按键已独占接收，避免系统动作与映射双发")
                } else {
                    _ = IOHIDDeviceOpen(device, 0)
                    googleInputIssue = "无法取得独占输入（\(result)），映射已暂停；请检查输入监控权限或其他遥控器软件"
                    releaseGoogleButtons()
                }
            } else if !exclusive && googleSeized.contains(id) {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                _ = IOHIDDeviceOpen(device, 0); googleSeized.remove(id)
                L("Google 原生按键接收已释放")
            }
        }
        if googleCapture.active && googleHIDDevices.count != 1 {
            googleInputIssue = "遥控器未就绪或连接了多支同款设备，映射已暂停"
        }
    }

    private func setupHID() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        // 匹配字典内多键是 AND、单值无法表达多厂商 OR，故按 Consumer(0x0C) usage page 匹配后逐设备过滤厂商
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDDeviceUsagePageKey as String: 0x0C] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(mgr, 0)
        // BLE 遥控器休眠唤醒/重连后设备会以新实例出现，必须监听设备到达再补注册回调
        let mctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, dvc in
            guard let context else { return }
            let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.openHIDDevice(dvc) }
        }, mctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
            let id = (IOHIDDeviceGetProperty(device, kIOHIDUniqueIDKey as CFString) as? NSNumber)?.intValue ?? -1
            MainActor.assumeIsolated {
                if me.googleHIDDevices.removeValue(forKey: id) != nil {
                    me.googleSeized.remove(id); me.releaseGoogleButtons()
                    me.googleInputIssue = "遥控器已断开，等待唤醒重连"
                }
                me.openedHIDs.remove(id)
                me.syncGoogleHIDAccess()
            }
        }, mctx)
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            for dvc in set { openHIDDevice(dvc) }
        }
        hidMgr = mgr
    }

    private func openHIDDevice(_ dvc: IOHIDDevice) {
        let vid = (IOHIDDeviceGetProperty(dvc, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
        guard Self.remoteVendors.contains(vid) else { return }
        if vid == 0x18D1 {
            let pid = (IOHIDDeviceGetProperty(dvc, kIOHIDProductIDKey as CFString) as? Int) ?? -1
            guard pid == 0x9450 else { return }
        }
        let uid = (IOHIDDeviceGetProperty(dvc, kIOHIDUniqueIDKey as CFString) as? NSNumber)?.intValue ?? -1
        guard uid >= 0, !openedHIDs.contains(uid) else { return }
        openedHIDs.insert(uid)
        L("HID 遥控器: \((IOHIDDeviceGetProperty(dvc, kIOHIDProductKey as CFString) as? String) ?? "未知") (vid 0x\(String(vid, radix: 16)))")
        let rsize = (IOHIDDeviceGetProperty(dvc, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        _ = IOHIDDeviceOpen(dvc, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        if vid == 0x18D1 { googleHIDDevices[uid] = dvc }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(rsize,8)); hidBufs.append(buf)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dvc, buf, max(rsize,8), { context, _, _, _, _, report, len in
            guard let context = context, len >= 2 else { return }
            let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
            // 回调本就在主运行循环上，必须同步处理：
            // 若 async 延后一拍，系统生成的原生键事件会抢先到达拦截器，抑制标记来不及生效
            if len == 3 && report[0] == 0x01 {
                // Never inject from this partial IOHID path: short single-key/releases are absent.
                // Only mark native-key suppression early for valid full chord reports.
                let slots = [report[1], report[2]]
                MainActor.assumeIsolated {
                    if me.googleCapture.active {
                        for index in slots {
                            if let key = GVRMap.usageToKeycode[index] { me.lastHidKeycodeAt[key] = ProcessInfo.processInfo.systemUptime }
                        }
                    }
                }
            } else if len >= 4 {
                // 小米遥控器：usage 在第 4 字节
                MainActor.assumeIsolated { me.hidReport(usage: report[3]) }
            }
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dvc, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        if vid == 0x18D1 { syncGoogleHIDAccess() }
    }

    private func hidReport(usage: UInt8) {
        let now = ProcessInfo.processInfo.systemUptime
        if usage == 0x00 {
            _ = legacyFilter.accept(0)
            // release: send keyUp for the held mapped target, if any
            if voiceHidDown { voiceHidDown = false; lastHidKeycodeAt[HIDMap.voiceKeycode] = now }
            if let t = downTarget {
                if t.keycode >= KeyNames.kSpecialBase { stopSpecial(t.keycode) }
                else if t.keycode != KeyNames.kNone { postKey(CGKeyCode(t.keycode), down: false, cmd: false) }
            }
            downButtonUsage = 0; downTarget = nil
            return
        }
        if usage == HIDMap.voiceUsage {
            // 语音键的原生报告：吞掉（BLE 通道已负责发所录制的键），避免触发系统听写
            voiceHidDown = true
            lastHidKeycodeAt[HIDMap.voiceKeycode] = now
            return
        }
        guard legacyFilter.accept(usage) else { return }
        if let old = downTarget {
            sendMapping(old, down: false)
            downTarget = nil; downButtonUsage = 0
        }
        // a button is pressed
        lastButtonUsage = Int(usage)
        lastButton = String(format: "0x%02x", usage)
        // mark for suppression if macOS will also generate a keycode
        if let kc = GVRMap.usageToKeycode[usage] ?? HIDMap.usageToKeycode[usage] { lastHidKeycodeAt[kc] = now }
        // find mapping
        guard let m = config.buttons.first(where: { $0.usage == Int(usage) }) else {
            L(String(format: "按键 0x%02x 未在映射表中（保持原样）", usage))
            return
        }
        L(String(format: "按键 0x%02x [%@] → %@", usage, m.name, m.display))
        if m.keycode == KeyNames.kNone { downButtonUsage = Int(usage); downTarget = nil; return } // keep original
        if m.keycode >= KeyNames.kSpecialBase {   // 鼠标/滚轮：按住持续，松开停止
            sendMapping(m, down: true); downButtonUsage = Int(usage); downTarget = m; return
        }
        // emit mapped key (down); keyUp on release
        postKey(CGKeyCode(m.keycode), down: true, cmd: m.cmd, shift: m.shift, opt: m.opt, ctrl: m.ctrl)
        downButtonUsage = Int(usage); downTarget = m
    }

    // ---------- CGEvent tap: suppress originals of mapped buttons ----------
    private func installTap() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, ud in
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        return Unmanaged.passUnretained(event)
                    }
                    guard let ud = ud else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<Engine>.fromOpaque(ud).takeUnretainedValue()
                    // ignore our own synthetic events
                    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker {
                        return Unmanaged.passUnretained(event)
                    }
                    let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    if me.shouldSuppress(kc) {
                        return nil // swallow the remote's original key
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: ctx) else { L("⚠️ 无法创建事件拦截（需辅助功能授权）"); return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }
    // called from tap thread — keep it cheap & thread-safe-ish (dictionary read)
    nonisolated func shouldSuppress(_ kc: CGKeyCode) -> Bool {
        // suppress if the remote produced this keycode within the last 120ms AND that button is mapped to something other than "keep original"
        var suppress = false
        MainActor.assumeIsolated {
            // Google native events are blocked at the target device by IOHID seize.
            // Never time-window suppress unrelated physical keyboard events for Google.
            if isGoogleRemote { return }
            let now = ProcessInfo.processInfo.systemUptime
            // 语音键的 F5：按住期间全部吞掉（含自动重复），松开后 120ms 内吞掉 keyUp
            if kc == HIDMap.voiceKeycode {
                suppress = voiceHidDown || (lastHidKeycodeAt[kc].map { now - $0 < 0.12 } ?? false)
                if !suppress { L("⚠️ F5 事件到达时语音键标记未立，漏过一次（请反馈）") }
                return
            }
            if let ts = lastHidKeycodeAt[kc], now - ts < 0.12 {
                // find which usage produced this keycode
                let table = isGoogleRemote ? GVRMap.usageToKeycode : HIDMap.usageToKeycode
                if let usage = table.first(where: { $0.value == kc })?.key,
                   let m = config.buttons.first(where: { $0.usage == Int(usage) }),
                   m.keycode != KeyNames.kNone {
                    suppress = true
                }
            }
        }
        return suppress
    }

    // ---------- 特殊动作：鼠标移动/点击/滚轮 ----------
    private var specialTimer: Timer?
    private var mouseSpeed: CGFloat = 0
    private var activeSpecials: [Int: Int] = [:]
    private var mediaRepeatAt: [Int: TimeInterval] = [:]

    func setSpecial(usage: Int, keycode: Int) {
        if usage == -1 {
            config.voice.keycode = keycode; config.voice.cmd = false; config.voice.shift = false; config.voice.opt = false; config.voice.ctrl = false
        } else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].openTarget = nil; config.buttons[i].keycode = keycode; config.buttons[i].cmd = false
            config.buttons[i].shift = false; config.buttons[i].opt = false; config.buttons[i].ctrl = false
        }
        L("已设置映射 → \(KeyNames.label(keycode: keycode, cmd: false, shift: false, opt: false, ctrl: false))")
        saveConfig()
    }

    private func startSpecial(_ code: Int) {
        activeSpecials[code, default: 0] += 1
        guard activeSpecials[code] == 1 else { return }
        switch code {
        case KeyNames.kMouseClick:  postMouse(.leftMouseDown, .left)
        case KeyNames.kMouseRClick: postMouse(.rightMouseDown, .right)
        case KeyNames.kVolumeUp, KeyNames.kVolumeDown, KeyNames.kMute, KeyNames.kPlayPause:
            postMedia(code)
            mediaRepeatAt[code] = ProcessInfo.processInfo.systemUptime + 0.5
        default:
            mouseSpeed = 4
        }
        if specialTimer == nil {
            specialTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.specialTick() }
            }
        }
    }
    private func stopSpecial(_ code: Int) {
        guard let count = activeSpecials[code] else { return }
        if count > 1 { activeSpecials[code] = count - 1; return }
        activeSpecials.removeValue(forKey: code); mediaRepeatAt.removeValue(forKey: code)
        switch code {
        case KeyNames.kMouseClick:  postMouse(.leftMouseUp, .left)
        case KeyNames.kMouseRClick: postMouse(.rightMouseUp, .right)
        default: break
        }
        if activeSpecials.isEmpty { specialTimer?.invalidate(); specialTimer = nil }
    }
    private func specialTick() {
        let dx: CGFloat = (activeSpecials[KeyNames.kMouseRight] != nil ? 1 : 0) - (activeSpecials[KeyNames.kMouseLeft] != nil ? 1 : 0)
        let dy: CGFloat = (activeSpecials[KeyNames.kMouseDown] != nil ? 1 : 0) - (activeSpecials[KeyNames.kMouseUp] != nil ? 1 : 0)
        if dx != 0 || dy != 0 { moveMouse(dx, dy) }
        if activeSpecials[KeyNames.kScrollUp] != nil { postScroll(2) }
        if activeSpecials[KeyNames.kScrollDown] != nil { postScroll(-2) }
        let now = ProcessInfo.processInfo.systemUptime
        for code in [KeyNames.kVolumeUp, KeyNames.kVolumeDown] where activeSpecials[code] != nil {
            if now >= (mediaRepeatAt[code] ?? .infinity) { postMedia(code); mediaRepeatAt[code] = now + 0.12 }
        }
    }
    private func postMedia(_ code: Int) {
        let key: Int
        switch code {
        case KeyNames.kVolumeUp: key = 0
        case KeyNames.kVolumeDown: key = 1
        case KeyNames.kMute: key = 7
        case KeyNames.kPlayPause: key = 16
        default: return
        }
        for state in [0xA, 0xB] {
            if let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)), timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8,
                data1: (key << 16) | (state << 8), data2: -1)?.cgEvent {
                event.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }
    private func moveMouse(_ dx: CGFloat, _ dy: CGFloat) {
        let p = CGEvent(source: nil)?.location ?? .zero
        var np = CGPoint(x: p.x + dx * mouseSpeed, y: p.y + dy * mouseSpeed)
        mouseSpeed = min(28, mouseSpeed * 1.05)   // 按住越久移动越快
        // 不越出屏幕：目标点不在任何屏幕上时，钳制回当前屏幕
        var cnt: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &cnt)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(cnt))
        CGGetActiveDisplayList(cnt, &ids, &cnt)
        let ds = ids.map { CGDisplayBounds($0) }
        if !ds.contains(where: { $0.contains(np) }), let d = ds.first(where: { $0.contains(p) }) {
            np.x = min(max(np.x, d.minX), d.maxX - 1)
            np.y = min(max(np.y, d.minY), d.maxY - 1)
        }
        let draggingLeft = activeSpecials[KeyNames.kMouseClick] != nil
        let draggingRight = activeSpecials[KeyNames.kMouseRClick] != nil
        let type: CGEventType = draggingLeft ? .leftMouseDragged : (draggingRight ? .rightMouseDragged : .mouseMoved)
        if let e = CGEvent(mouseEventSource: evSrc, mouseType: type, mouseCursorPosition: np, mouseButton: draggingRight && !draggingLeft ? .right : .left) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    private func postMouse(_ type: CGEventType, _ btn: CGMouseButton) {
        let p = CGEvent(source: nil)?.location ?? .zero
        if let e = CGEvent(mouseEventSource: evSrc, mouseType: type, mouseCursorPosition: p, mouseButton: btn) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    private func postScroll(_ lines: Int32) {
        if let e = CGEvent(scrollWheelEvent2Source: evSrc, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    // ---------- synthesize keys ----------
    private let evSrc = CGEventSource(stateID: .hidSystemState)
    func postKey(_ code: CGKeyCode, down: Bool, cmd: Bool, shift: Bool = false, opt: Bool = false, ctrl: Bool = false, autorepeat: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: evSrc, virtualKey: code, keyDown: down) else { return }
        var flags: CGEventFlags = []
        if down {
            if cmd { flags.insert(.maskCommand) }
            if shift { flags.insert(.maskShift) }
            if opt { flags.insert(.maskAlternate) }
            if ctrl { flags.insert(.maskControl) }
        }
        e.flags = flags
        if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
        e.post(tap: .cghidEventTap)
    }
}

// CBCentralManager/CBPeripheral delegate proxy (Engine is @MainActor)
final class BTProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var e: Engine?
    init(_ e: Engine) { self.e = e }
    func centralManagerDidUpdateState(_ c: CBCentralManager) { Task { @MainActor in e?.btStateChanged(c) } }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { Task { @MainActor in e?.didConnect(p) } }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { Task { @MainActor in e?.didDisconnect() } }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { Task { @MainActor in e?.didFailConnect(p, error) } }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { Task { @MainActor in e?.didServices(p) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) { Task { @MainActor in e?.didChars(p, s) } }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didNotify(p, ch) } }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let value = ch.value else { return }
        // CBCentralManager uses queue:nil (main). Consume the value in this callback,
        // before a later notification mutates CBCharacteristic.value.
        MainActor.assumeIsolated { e?.didValue(p, uuid: ch.uuid, data: value) }
    }
}
