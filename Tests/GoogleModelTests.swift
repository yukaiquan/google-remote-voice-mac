import Foundation

@main struct ModelTests {
    static func main() {
        var failed = 0
        var checked = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            checked += 1
            if !condition() { failed += 1; print("FAIL: \(name)") }
        }
        let oldMapping = #"{"usage":14,"name":"YouTube","keycode":101,"cmd":false,"shift":false,"opt":false,"ctrl":false}"#.data(using: .utf8)!
        check((try! JSONDecoder().decode(ButtonMapping.self, from: oldMapping)).openTarget == nil, "old shortcut config remains compatible")
        var launch = try! JSONDecoder().decode(ButtonMapping.self, from: oldMapping)
        let launchData = #"{"usage":14,"name":"YouTube","keycode":65568,"cmd":false,"shift":false,"opt":false,"ctrl":false,"openTarget":"https://www.youtube.com/"}"#.data(using: .utf8)!
        launch = try! JSONDecoder().decode(ButtonMapping.self, from: launchData)
        check(launch.display.contains("youtube.com"), "launch target shown instead of unknown special key")
        let roundtrip = try! JSONDecoder().decode(ButtonMapping.self, from: JSONEncoder().encode(launch))
        check(roundtrip.launchURL?.absoluteString == "https://www.youtube.com/", "website target survives config roundtrip")
        let websiteID = launch.actionID
        launch.openTarget = "https://www.netflix.com/"
        check(launch.actionID != websiteID, "different launch targets do not merge")
        launch.openTarget = "javascript:alert(1)"
        check(launch.launchURL == nil, "unsupported URL scheme rejected")
        launch.openTarget = "https://"
        check(launch.launchURL == nil, "missing website host rejected")
        launch.openTarget = URL(fileURLWithPath: "/Applications/Safari.app").absoluteString
        check(launch.launchURL?.isFileURL == true, "application target accepted")
        launch.openTarget = URL(fileURLWithPath: "/tmp/script.sh").absoluteString
        check(launch.launchURL == nil, "arbitrary local file rejected")
        launch.keycode = 0x65
        check(launch.launchURL == nil && launch.display == "F9", "switching back to shortcut disables launch")
        let physical: Set<Int> = [1,3,4,5,6,7,8,10,11,12,13,14,15,17]
        var config = Config.defaultConfig
        check(config.effectiveAutoStartGoogleCapture, "capture auto-start is enabled by default")
        check(config.effectiveVoiceGainDB == 18, "recommended volume adds 6 dB over previous 12 dB setting")
        config.voiceGainDB = -100
        check(config.effectiveVoiceGainDB == 0, "volume lower bound")
        config.voiceGainDB = 100
        check(config.effectiveVoiceGainDB == 24, "volume upper bound")
        config.voiceGainDB = .nan
        check(config.effectiveVoiceGainDB == 18, "non-finite volume uses safe recommendation")
        config.voiceGainDB = nil
        check(config.buttons.first(where: { $0.usage == 11 })?.keycode == 0x33, "Google back defaults to Backspace")
        check(config.googleDefaultsVersion == 1, "fresh config must not rerun legacy migration after user clears a key")
        check(Set(config.buttons.map(\.usage)).count == config.buttons.count, "no overlapping Xiaomi/Google IDs")
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
        let gainJSON = #"{"buttons":[],"voice":{"usage":-1,"name":"voice","keycode":54,"cmd":true,"shift":false,"opt":false,"ctrl":false},"voiceStartsMic":true,"voiceGainDB":18}"#.data(using:.utf8)!
        let gainConfig = try! JSONDecoder().decode(Config.self, from: gainJSON)
        let gainEncoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(gainConfig)) as! [String:Any]
        check(gainEncoded["voiceGainDB"] as? Double == 18, "microphone volume survives config roundtrip")
        let autoJSON = #"{"buttons":[],"voice":{"usage":-1,"name":"voice","keycode":54,"cmd":true,"shift":false,"opt":false,"ctrl":false},"voiceStartsMic":true,"autoStartGoogleCapture":false}"#.data(using:.utf8)!
        let autoConfig = try! JSONDecoder().decode(Config.self, from:autoJSON)
        let autoEncoded = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(autoConfig)) as! [String:Any]
        check(autoEncoded["autoStartGoogleCapture"] as? Bool == false, "auto-start preference survives config roundtrip")
        var old = try! JSONDecoder().decode(Config.self, from: legacy)
        check(old.effectiveVoiceGainDB == 18, "legacy config receives recommended volume without losing key mappings")
        check(old.effectiveAutoStartGoogleCapture, "legacy config enables automatic capture without changing mappings")
        old.mergeKnown()
        check(old.buttons.count == Config.known.count, "legacy config acquires all known keys")
        print("\(checked-failed)/\(checked) model checks passed")
        exit(failed == 0 ? 0 : 1)
    }
}
