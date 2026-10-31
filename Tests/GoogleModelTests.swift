import Foundation

@main struct ModelTests {
    static func main() {
        var failed = 0
        var checked = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checked += 1
            if !condition() { failed += 1; print("FAIL: \(name)") }
        }
        let physical: Set<Int> = [1,3,4,5,6,7,8,10,11,12,13,14,15,17]
        var config = Config.defaultConfig
        check(config.buttons.first(where: { $0.usage == 11 })?.keycode == 0x33, "Google back defaults to Backspace")
        check(config.googleDefaultsVersion == 1, "fresh config must not rerun legacy migration after user clears a key")
        check(Set(config.buttons.map(\.usage)).count == config.buttons.count, "no duplicate Google IDs")
        for usage in physical {
            check(config.buttons.first(where: { $0.usage == usage })?.keycode != KeyNames.kNone, "physical key \(usage) has default action")
        }
        check(config.buttons.first(where: { $0.usage == 1 })?.keycode == 0x6F, "power defaults to safe F12")
        check(config.buttons.first(where: { $0.usage == 12 })?.keycode == 0x10010, "volume up uses system volume")
        check(config.buttons.first(where: { $0.usage == 13 })?.keycode == 0x10011, "volume down uses system volume")
        check(config.buttons.first(where: { $0.usage == 8 })?.keycode == 0x10012, "mute uses system mute")
        config.buttons[0].keycode = 0x00
        config.mergeKnown()
        check(config.buttons[0].keycode == 0x00, "merge preserves custom target")
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(Config.self, from: data)
        check(decoded.buttons.first?.keycode == 0x00, "config roundtrip preserves custom target")
        let legacy = #"{"buttons":[],"voice":{"usage":-1,"name":"voice","keycode":54,"cmd":true,"shift":false,"opt":false,"ctrl":false},"voiceStartsMic":true}"#.data(using:.utf8)!
        var old = try! JSONDecoder().decode(Config.self, from: legacy)
        old.mergeKnown()
        check(old.buttons.count == Config.known.count, "legacy config acquires all known keys")
        print("\(checked-failed)/\(checked) model checks passed")
        exit(failed == 0 ? 0 : 1)
    }
}
