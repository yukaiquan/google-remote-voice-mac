import Foundation

struct GoogleCaptureRecord: Codable, Equatable {
    var kind: String
    var buttons: [Int] = []
    var message: String = ""
}

struct GooglePacketDecoder {
    let peripheralID: String
    let attribute: UInt16
    private var connection: UInt16?
    var isBound: Bool { connection != nil }
    init(peripheralID: String, attribute: UInt16) {
        self.peripheralID = peripheralID.uppercased(); self.attribute = attribute
    }
    // Firmware variant (e.g. Report ID 2, Handle 0x002B) sends 16-bit LE Consumer usage directly
    // instead of 1-byte array indices (1..17) on Handle 0x0046.
    private static let consumerUsageToButton: [UInt16: Int] = [
        0x0030: 1, 0x019E: 1, // 电源
        0x00CD: 2,            // 播放/暂停
        0x0042: 3,            // 方向 上
        0x0043: 4,            // 方向 下
        0x0044: 5,            // 方向 左
        0x0045: 6,            // 方向 右
        0x0041: 7,            // 确认 OK
        0x00E2: 8,            // 静音
        0x0221: 9,            // 星标/自定义
        0x0223: 10,           // 主页
        0x0224: 11,           // 返回
        0x00E9: 12,           // 音量 +
        0x00EA: 13,           // 音量 −
        0x0077: 14,           // YouTube
        0x0078: 15,           // Netflix
        0x0079: 16,           // 播放
        0x0089: 17, 0x0189: 17, 0x01BB: 17 // 输入源
    ]
    private static let row = try! NSRegularExpression(pattern:
        #"^\S+\s{2,}(Config|ATT Receive|HCI Event)\s{2,}(.*?)\s{2,}(0x[0-9a-fA-F]+)\s{2,}RECV\s{2,}(.*)$"#)
    private static let notification = try! NSRegularExpression(pattern:
        #"^Handle Value Notification - Handle:(0x[0-9a-fA-F]+) - Value: ([0-9a-fA-F]+(?: [0-9a-fA-F]+)*)(?:\s{2,}|$)"#)
    mutating func feed(_ line: String) -> GoogleCaptureRecord? {
        let text = line.trimmingCharacters(in: .newlines)
        guard let row = Self.row.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        let kind = ns.substring(with: row.range(at: 1))
        let devName = ns.substring(with: row.range(at: 2)).lowercased()
        let handleText = ns.substring(with: row.range(at: 3))
        guard let handle = UInt16(handleText.dropFirst(2), radix: 16) else { return nil }
        let body = ns.substring(with: row.range(at: 4))
        if kind == "Config", body.hasPrefix("Connected:"), body.uppercased().contains(peripheralID) {
            connection = handle
            return GoogleCaptureRecord(kind: "connected")
        }
        guard connection == handle, devName.contains("chromecast") || devName.contains("g9n9n") else { return nil }
        if (kind == "HCI Event" && body.hasPrefix("Disconnection Complete")) || (kind == "Config" && body.hasPrefix("Disconnected:")) {
            connection = nil
            return GoogleCaptureRecord(kind: "disconnected")
        }
        guard kind == "ATT Receive",
              let match = Self.notification.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else { return nil }
        let description = body as NSString
        guard let attHandle = UInt16(description.substring(with: match.range(at: 1)).dropFirst(2), radix: 16) else { return nil }
        let hex = description.substring(with: match.range(at: 2)).replacingOccurrences(of: " ", with: "")
        if attHandle == 0x002B {
            guard hex.count == 4 || hex.count == 6,
                  let b0 = UInt16(hex.prefix(2), radix: 16),
                  let b1 = UInt16(hex.dropFirst(2).prefix(2), radix: 16) else { return nil }
            let usage = b0 | (b1 << 8)
            if usage == 0 { return GoogleCaptureRecord(kind: "buttons", buttons: []) }
            guard let btn = Self.consumerUsageToButton[usage] else {
                return GoogleCaptureRecord(kind: "ready", message: String(format: "未知按键 Usage 0x%04X（来自 0x002B）", usage))
            }
            return GoogleCaptureRecord(kind: "buttons", buttons: [btn])
        }
        guard attHandle == attribute else { return nil }
        guard hex.count == 2 || hex.count == 4 else { return nil }
        var payload: [Int] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let value = Int(hex[index..<next], radix: 16), value <= 17 else { return nil }
            payload.append(value); index = next
        }
        return GoogleCaptureRecord(kind: "buttons", buttons: Set(payload).subtracting([0]).sorted())
    }
}

struct GoogleKeyEdge: Equatable {
    var button: Int
    var down: Bool
}

struct GoogleButtonState {
    private(set) var held: Set<Int> = []
    mutating func update(_ buttons: [Int]) -> [GoogleKeyEdge] {
        guard buttons.count <= 2, buttons.allSatisfy({ (1...17).contains($0) }) else { return [] }
        let next = Set(buttons)
        let edges = held.subtracting(next).sorted().map { GoogleKeyEdge(button: $0, down: false) }
            + next.subtracting(held).sorted().map { GoogleKeyEdge(button: $0, down: true) }
        held = next
        return edges
    }
    mutating func releaseAll() -> [GoogleKeyEdge] {
        let edges = held.sorted().map { GoogleKeyEdge(button: $0, down: false) }
        held.removeAll()
        return edges
    }
}

enum GoogleTraceSettings {
    static func enabled(_ current: [String: Any]) -> [String: Any] {
        var result = current
        var traces = current["HCITraces"] as? [String: Any] ?? [:]
        for key in ["StackDebugEnabled", "HCILiveTraces", "HIDTrace", "HCISkipAuth"] { traces[key] = true }
        traces["HCIFileTraces"] = false
        traces["RawAudioTrace"] = false
        result["HCITraces"] = traces
        return result
    }
    static func restored(_ current: [String: Any], original: [String: Any]) -> [String: Any] {
        var result = current
        result["HCITraces"] = original["HCITraces"]
        return result
    }
}

struct LegacyPressFilter {
    private var held: UInt8 = 0
    mutating func accept(_ usage: UInt8) -> Bool {
        if usage != 0 && usage == held { return false }
        held = usage
        return true
    }
}

enum GoogleCapturePolicy {
    static func shouldSeize(active: Bool, deviceCount: Int, connected: Bool, currentID: String?, sessionID: String?) -> Bool {
        guard active, deviceCount == 1, connected, let currentID, let sessionID else { return false }
        return currentID.uppercased() == sessionID.uppercased()
    }
}

// PacketLogger emits its UUID/handle inventory at launch, not on every reconnect.
// Refresh only while unbound; never infer identity from a Bluetooth name/handle.
struct GoogleCaptureRecovery {
    private var lastRefresh: TimeInterval = 0
    mutating func shouldRefresh(bound: Bool, now: TimeInterval) -> Bool {
        guard !bound, now - lastRefresh >= 5 else { return false }
        lastRefresh = now
        return true
    }
}
