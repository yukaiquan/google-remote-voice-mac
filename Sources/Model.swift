import Foundation
import CoreGraphics

enum KeyNames {
    // macOS virtual keycode -> label (for display of recorded keys)
    static let map: [Int: String] = [
        0x24:"Return", 0x30:"Tab", 0x31:"Space", 0x33:"Delete", 0x35:"Esc",
        0x7E:"↑", 0x7D:"↓", 0x7B:"←", 0x7C:"→",
        0x36:"右⌘", 0x37:"左⌘", 0x38:"⇧", 0x3C:"右⇧", 0x3A:"⌥", 0x3D:"右⌥",
        0x3B:"⌃", 0x3E:"右⌃", 0x39:"Caps", 0x3F:"Fn",
        0x7A:"F1",0x78:"F2",0x63:"F3",0x76:"F4",0x60:"F5",0x61:"F6",0x62:"F7",
        0x64:"F8",0x65:"F9",0x6D:"F10",0x67:"F11",0x6F:"F12",
        0x73:"Home",0x77:"End",0x74:"PgUp",0x79:"PgDn",0x75:"⌦",
        0x00:"A",0x0B:"B",0x08:"C",0x02:"D",0x0E:"E",0x03:"F",0x05:"G",0x04:"H",
        0x22:"I",0x26:"J",0x28:"K",0x25:"L",0x2E:"M",0x2D:"N",0x1F:"O",0x23:"P",
        0x0C:"Q",0x0F:"R",0x01:"S",0x11:"T",0x20:"U",0x09:"V",0x0D:"W",0x07:"X",
        0x10:"Y",0x06:"Z",
        0x12:"1",0x13:"2",0x14:"3",0x15:"4",0x17:"5",0x16:"6",0x1A:"7",0x1C:"8",
        0x19:"9",0x1D:"0",0x1B:"-",0x18:"=",0x21:"[",0x1E:"]",0x2A:"\\",
        0x29:";",0x27:"'",0x2B:",",0x2F:".",0x2C:"/",0x32:"`",
    ]
    // 特殊动作（鼠标/滚轮）：占用 0x10000 以上的伪键码
    static let kSpecialBase = 0x10000
    static let kMouseUp = 0x10001, kMouseDown = 0x10002, kMouseLeft = 0x10003, kMouseRight = 0x10004
    static let kMouseClick = 0x10005, kMouseRClick = 0x10006
    static let kScrollUp = 0x10007, kScrollDown = 0x10008
    static let kVolumeUp = 0x10010, kVolumeDown = 0x10011, kMute = 0x10012, kPlayPause = 0x10013
    static let specials: [(name: String, code: Int)] = [
        ("鼠标 ↑", kMouseUp), ("鼠标 ↓", kMouseDown), ("鼠标 ←", kMouseLeft), ("鼠标 →", kMouseRight),
        ("鼠标左键", kMouseClick), ("鼠标右键", kMouseRClick),
        ("滚轮 ↑", kScrollUp), ("滚轮 ↓", kScrollDown),
        ("系统音量 +", kVolumeUp), ("系统音量 −", kVolumeDown), ("系统静音", kMute), ("播放/暂停", kPlayPause),
    ]
    static func label(keycode: Int, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) -> String {
        if keycode == kNone { return "（不映射 / 保持原键）" }
        if keycode >= kSpecialBase {
            return specials.first(where: { $0.code == keycode })?.name ?? String(format:"特殊0x%x", keycode)
        }
        let base = map[keycode] ?? String(format:"键码0x%02x", keycode)
        var c = cmd, s = shift, o = opt, t = ctrl
        switch keycode {   // 修饰键自身的 flag 不重复显示
        case 0x36,0x37: c = false
        case 0x38,0x3C: s = false
        case 0x3A,0x3D: o = false
        case 0x3B,0x3E: t = false
        default: break
        }
        var p = ""
        if t { p += "⌃" }; if o { p += "⌥" }; if s { p += "⇧" }; if c { p += "⌘" }
        return p + base
    }
    static let kNone = 0xFFFF
}

enum HIDMap {
    // remote HID usage (report byte3) -> macOS keycode macOS also generates (for suppression)
    static let usageToKeycode: [UInt8: CGKeyCode] = [
        0x52:0x7E, 0x51:0x7D, 0x50:0x7B, 0x4F:0x7C, 0x28:0x24, 0x4A:0x73, 0x35:0x32,
    ]
    // 语音键除 BLE 语音流外还会发一个 HID F5（usage 0x3E）；macOS 把 F5 当系统听写🎤键，必须吞掉
    static let voiceUsage: UInt8 = 0x3E
    static let voiceKeycode: CGKeyCode = 0x60   // F5
}

enum GVRMap {
    static let physicalUsages: Set<Int> = [1,3,4,5,6,7,8,10,11,12,13,14,15,17]
    // Google 遥控器（VID 0x18D1, G9N9N）：HID 数组报告 [reportID=1, slot0, slot1]，值为按键索引（1-17），0=松开
    // 索引→usage（实测，参考 voice-input-buddy 抓包）：1=0x19E电源, 2=0xCD播放/暂停, 3-6=0x42-0x45方向,
    // 7=0x41确认, 8=0xE2静音, 9=0x221(未定), 10=0x223主页, 11=0x224返回, 12/13=0xE9/0xEA音量,
    // 14=0x77 YouTube, 15=0x78 Netflix, 16=0x79播放, 17=0x89输入源
    // 语音键不走 HID（无可靠边沿），由 ATVV 控制流驱动
    static let known: [(usage: Int, name: String)] = [
        (1, "电源"), (2, "播放/暂停"), (3, "方向 上"), (4, "方向 下"), (5, "方向 左"), (6, "方向 右"),
        (7, "确认 OK"), (8, "静音"), (9, "星标/自定义"), (10, "主页"), (11, "返回"),
        (12, "音量 +"), (13, "音量 −"), (14, "YouTube"), (15, "Netflix"), (16, "播放"), (17, "输入源"),
    ]
    // macOS 会为这些索引的原生 usage 生成键码（用于拦截原键）：索引 → macOS keycode
    static let usageToKeycode: [UInt8: CGKeyCode] = [
        3:0x7E, 4:0x7D, 5:0x7B, 6:0x7C, 7:0x24,
    ]
}

struct ButtonMapping: Identifiable, Codable {
    var usage: Int          // HID usage byte; -1 = voice button
    var name: String        // physical button name
    var keycode: Int        // target macOS keycode; 0xFFFF = keep original
    var cmd: Bool
    var shift: Bool
    var opt: Bool
    var ctrl: Bool
    var id: Int { usage }

    init(usage: Int, name: String, keycode: Int = 0xFFFF, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) {
        self.usage = usage; self.name = name; self.keycode = keycode
        self.cmd = cmd; self.shift = shift; self.opt = opt; self.ctrl = ctrl
    }
    var display: String { KeyNames.label(keycode: keycode, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl) }
    var actionID: String { "\(keycode):\(cmd):\(shift):\(opt):\(ctrl)" }
}

struct Config: Codable {
    var buttons: [ButtonMapping]
    var voice: ButtonMapping       // usage = -1
    var voiceStartsMic: Bool
    var googleDefaultsVersion: Int? = nil

    static let known = GVRMap.known
    // sensible defaults (keycodes)
    static let defaultTarget: [Int: (Int,Bool,Bool,Bool,Bool)] = [
        0x52:(0x7E,false,false,false,false), 0x51:(0x7D,false,false,false,false),
        0x50:(0x7B,false,false,false,false), 0x4F:(0x7C,false,false,false,false),
        0x28:(0x24,false,false,false,false), 0xF1:(0x35,false,false,false,false),
        3:(0x7E,false,false,false,false), 4:(0x7D,false,false,false,false),
        5:(0x7B,false,false,false,false), 6:(0x7C,false,false,false,false),
        7:(0x24,false,false,false,false), 11:(0x33,false,false,false,false),
        1:(0x6F,false,false,false,false), 2:(KeyNames.kPlayPause,false,false,false,false),
        8:(KeyNames.kMute,false,false,false,false), 9:(0x64,false,false,false,false),
        10:(0x73,false,false,false,false),
        12:(KeyNames.kVolumeUp,false,false,false,false), 13:(KeyNames.kVolumeDown,false,false,false,false),
        14:(0x65,false,false,false,false), 15:(0x6D,false,false,false,false),
        16:(KeyNames.kPlayPause,false,false,false,false), 17:(0x30,false,false,false,false),
    ]
    static var defaultConfig: Config {
        let btns = known.map { k -> ButtonMapping in
            if let t = defaultTarget[k.usage] {
                return ButtonMapping(usage: k.usage, name: k.name, keycode: t.0, cmd: t.1, shift: t.2, opt: t.3, ctrl: t.4)
            }
            return ButtonMapping(usage: k.usage, name: k.name)
        }
        return Config(buttons: btns,
                      voice: ButtonMapping(usage: -1, name: "语音键", keycode: 0x36, cmd: true),
                      voiceStartsMic: true, googleDefaultsVersion: 1)
    }
    mutating func mergeKnown() {
        for k in Config.known {
            if let i = buttons.firstIndex(where: { $0.usage == k.usage }) {
                buttons[i].name = k.name
            } else {
                // 新增按键沿用默认映射（与全新安装的 defaultConfig 一致），而不是一律"不映射"
                let t = Config.defaultTarget[k.usage]
                buttons.append(ButtonMapping(usage: k.usage, name: k.name,
                    keycode: t?.0 ?? KeyNames.kNone, cmd: t?.1 ?? false,
                    shift: t?.2 ?? false, opt: t?.3 ?? false, ctrl: t?.4 ?? false))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: Config.known.enumerated().map { ($1.usage, $0) })
        buttons.sort { (order[$0.usage] ?? 999) < (order[$1.usage] ?? 999) }
    }
    mutating func installGoogleDefaults(overwrite: Bool) {
        for i in buttons.indices where (1...17).contains(buttons[i].usage) {
            guard overwrite || buttons[i].keycode == KeyNames.kNone,
                  let value = Self.defaultTarget[buttons[i].usage] else { continue }
            buttons[i] = ButtonMapping(usage: buttons[i].usage, name: buttons[i].name,
                                      keycode: value.0, cmd: value.1, shift: value.2, opt: value.3, ctrl: value.4)
        }
        googleDefaultsVersion = 1
    }
}

final class ConfigStore {
    static let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/GoogleRemoteVoice")
    static let path = (dir as NSString).appendingPathComponent("config.json")
    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config.defaultConfig
        }
        cfg.mergeKnown()
        if cfg.googleDefaultsVersion == nil {
            // One-time upgrade: fill only unmapped Google keys; preserve all existing custom targets.
            let backup = path + ".before-google-defaults.json"
            if !FileManager.default.fileExists(atPath: backup) { try? data.write(to: URL(fileURLWithPath: backup), options: .atomic) }
            cfg.installGoogleDefaults(overwrite: false)
        }
        return cfg
    }
    static func save(_ cfg: Config) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
