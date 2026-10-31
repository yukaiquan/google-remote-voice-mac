import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor final class GoogleCapture: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var ready = false
    @Published private(set) var status = "未开启谷歌按键接收"
    var onRecord: ((GoogleCaptureRecord) -> Void)?
    private var process: Process?
    private var reader: FileHandle?
    private var timer: Timer?
    private var directory: URL?
    private var buffer = Data()
    private var lastHeartbeat = Date()
    private var started = false
    private var stopping = false
    private var terminalRecord = false
    private var session = UUID()

    static var packetLogger: URL? {
        let fm = FileManager.default
        let paths = [UserDefaults.standard.string(forKey: "GooglePacketLoggerPath"),
                     "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
                     NSHomeDirectory() + "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
                     "/Volumes/Additional Tools/Hardware/PacketLogger.app/Contents/Resources/packetlogger"].compactMap { $0 }
        return paths.first(where: { fm.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func selectPacketLogger() {
        let panel = NSOpenPanel(); panel.title = "选择 Apple PacketLogger.app"
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url {
            let cli = url.appendingPathComponent("Contents/Resources/packetlogger")
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                UserDefaults.standard.set(cli.path, forKey: "GooglePacketLoggerPath")
                status = "已选择工具，开启时将验证 Apple 签名"
            } else { status = "所选应用没有 PacketLogger 命令行工具" }
        }
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func start(peripheralID: String) {
        guard !active else { return }
        guard UUID(uuidString: peripheralID) != nil else { status = "请先连接 Chromecast Remote"; return }
        guard let cli = Self.packetLogger else { status = "请先安装或选择 Apple PacketLogger"; return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "GoogleRemoteCapture") else { status = "缺少采集助手，请重新构建应用"; return }
        let id = UUID(); session = id; stopping = false; started = false; terminalRecord = false
        buffer.removeAll()
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GoogleRemoteVoice-" + id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let output = directory.appendingPathComponent("events.jsonl")
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            self.directory = directory; reader = try FileHandle(forReadingFrom: output)
            let command = [helper.path, cli.path, output.path, String(ProcessInfo.processInfo.processIdentifier), peripheralID, "46"].map(Self.quote).joined(separator: " ")
            let appleString = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"exec \(appleString)\" with administrator privileges"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let code = process.terminationStatus
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    self.poll()
                    self.ready = false; self.active = false
                    self.onRecord?(GoogleCaptureRecord(kind: "disconnected"))
                    if !self.terminalRecord {
                        // Keep the stop marker if a privileged child might still be winding down.
                        self.markStop()
                        self.status = self.stopping ? "接收已停止" : "启动未完成或授权已取消（代码 \(code)）"
                    }
                    self.timer?.invalidate(); self.timer = nil
                    try? self.reader?.close(); self.reader = nil; self.process = nil
                    if self.terminalRecord { try? FileManager.default.removeItem(at: directory) }
                }
            }
            self.process = process
            active = true; ready = false; status = "等待管理员授权…"
            try process.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch {
            active = false; ready = false; process = nil
            try? reader?.close(); reader = nil
            status = "启动失败：\(error.localizedDescription)"
        }
    }

    private func markStop() {
        if let directory { FileManager.default.createFile(atPath: directory.appendingPathComponent("stop").path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    }
    func stop() {
        guard active else { return }
        stopping = true; ready = false; markStop()
        status = "正在停止并恢复原设置…"
        onRecord?(GoogleCaptureRecord(kind: "disconnected"))
        if !started { process?.terminate() }
    }

    private func poll() {
        guard let reader else { return }
        do {
            if let data = try reader.readToEnd(), !data.isEmpty { buffer.append(data) }
            if buffer.count > 1_048_576 { stop(); status = "事件缓冲超过安全上限"; return }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard let record = try? JSONDecoder().decode(GoogleCaptureRecord.self, from: line) else { continue }
                lastHeartbeat = Date(); started = true
                switch record.kind {
                case "ready": ready = !stopping; status = stopping ? "正在恢复设置…" : record.message
                case "starting": status = "正在连接实时按键接收…"
                case "buttons": if !stopping { status = "正在接收谷歌遥控器按键" }
                case "stopped": ready = false; terminalRecord = true; status = record.message
                case "error": ready = false; terminalRecord = true; status = record.message
                default: break
                }
                if !stopping || record.kind != "buttons" { onRecord?(record) }
            }
            if started && !terminalRecord && Date().timeIntervalSince(lastHeartbeat) > 5 {
                stop(); status = "接收器失去响应，已释放按键并请求恢复设置"
            }
        } catch { stop(); status = "事件读取失败：\(error.localizedDescription)" }
    }
}
