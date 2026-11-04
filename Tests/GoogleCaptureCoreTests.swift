import Foundation

@main struct Tests {
    static func main() {
        var failures = 0
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !value() { failures += 1; print("FAIL: \(name)") }
        }
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let connected = "2026-10-31T17:00:00  Config           Chromecast Remote  0x0041  RECV  Connected: ADDRESS - Handle: 0x41 - Chromecast Remote - \(uuid)  00"
        func notify(_ payload: String, name: String = "Chromecast Remote", handle: String = "0x0041", attribute: String = "0x0046") -> String {
            "2026-10-31T17:00:01  ATT Receive      \(name)  \(handle)  RECV  Handle Value Notification - Handle:\(attribute) - Value: \(payload)  41 20 08 00 04 00 04 00 1B 46 00 03"
        }
        var decoder = GooglePacketDecoder(peripheralID: uuid, attribute: 0x46)
        check(decoder.feed(notify("03")) == nil, "ignore notifications before identity binding")
        check(decoder.feed(connected)?.kind == "connected", "bind selected peripheral")
        for button in 1...17 {
            check(decoder.feed(notify(String(format: "%02X", button)))?.buttons == [button], "decode button \(button)")
        }
        check(decoder.feed(notify("00"))?.buttons == [], "decode single-byte release")
        check(decoder.feed(notify("030B"))?.buttons == [3,11], "decode concatenated chord")
        check(decoder.feed(notify("03 0B"))?.buttons == [3,11], "decode spaced chord")
        for value in ["FF", "03FF", "030B00", "0", "GG"] {
            check(decoder.feed(notify(value)) == nil, "reject malformed \(value)")
        }
        check(decoder.feed(notify("03", name:"Other keyboard")) == nil, "filter unrelated device")
        check(decoder.feed(notify("03", handle:"0x0042")) == nil, "filter other connection")
        check(decoder.feed(notify("03", attribute:"0x0028")) == nil, "filter battery/other characteristic")
        var other = GooglePacketDecoder(peripheralID: "FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE", attribute: 0x46)
        check(other.feed(connected) == nil, "filter same-name peripheral with wrong UUID")
        check(other.feed(notify("03")) == nil, "wrong peripheral cannot bind")
        check(decoder.feed("2026-10-31T17:00:02  HCI Event  Chromecast Remote  0x0041  RECV  Disconnection Complete")?.kind == "disconnected", "disconnect event")
        check(decoder.feed(notify("03")) == nil, "ignore after disconnect until identity rebound")
        check(decoder.feed(connected.replacingOccurrences(of:"0x0041",with:"0x0042"))?.kind == "connected", "bind new connection handle")
        check(decoder.feed(notify("03", handle:"0x0042"))?.buttons == [3], "receive on new connection")
        check(decoder.feed(notify("4200", handle:"0x0042", attribute:"0x002B"))?.buttons == [3], "decode 16-bit LE consumer usage on 0x002B (Up)")
        check(decoder.feed(notify("2402", handle:"0x0042", attribute:"0x002B"))?.buttons == [11], "decode 16-bit LE consumer usage on 0x002B (Back 0x0224)")
        check(decoder.feed(notify("8901", handle:"0x0042", attribute:"0x002B"))?.buttons == [17], "decode 16-bit LE consumer usage on 0x002B (Input 0x0189)")
        check(decoder.feed(notify("0000", handle:"0x0042", attribute:"0x002B"))?.buttons == [], "decode 16-bit LE release on 0x002B")

        var recovery = GoogleCaptureRecovery()
        check(!recovery.shouldRefresh(bound: false, now: 4), "wait before refreshing an unbound snapshot")
        check(recovery.shouldRefresh(bound: false, now: 5), "refresh when live reconnect has no identity snapshot")
        check(!recovery.shouldRefresh(bound: false, now: 6), "throttle snapshot refreshes")
        check(!recovery.shouldRefresh(bound: true, now: 10), "never interrupt a bound capture")
        check(recovery.shouldRefresh(bound: false, now: 11), "recover again after a later disconnect")
        check(!recovery.shouldRefresh(bound: false, now: 12), "second recovery is also throttled")

        var state = GoogleButtonState()
        check(state.update([3]) == [GoogleKeyEdge(button:3, down:true)], "single down")
        check(state.update([3]).isEmpty, "duplicate notification suppressed")
        check(state.update([3,11]) == [GoogleKeyEdge(button:11, down:true)], "second chord key")
        check(state.update([11]) == [GoogleKeyEdge(button:3, down:false)], "release one chord key")
        check(state.update([]) == [GoogleKeyEdge(button:11, down:false)], "release final key")
        _ = state.update([3,11])
        check(state.releaseAll() == [GoogleKeyEdge(button:3,down:false),GoogleKeyEdge(button:11,down:false)], "disconnect releases both")
        check(state.releaseAll().isEmpty, "cleanup is idempotent")
        _ = state.update([3])
        check(state.update([255]).isEmpty && state.held == [3], "malformed input cannot erase held state")
        let original: [String: Any] = ["Other": "keep", "HCITraces": ["Existing": 42, "HCIFileTraces": true]]
        let enabled = GoogleTraceSettings.enabled(original)
        let traces = enabled["HCITraces"] as? [String: Any] ?? [:]
        check(traces["HCILiveTraces"] as? Bool == true, "enable live traces")
        check(traces["HCISkipAuth"] as? Bool == true, "enable authorized diagnostic capture")
        check(traces["HCIFileTraces"] as? Bool == false, "disable raw file traces")
        check(traces["Existing"] as? Int == 42, "preserve existing trace keys")
        var during = enabled; during["ConcurrentPreference"] = "new"
        let restored = GoogleTraceSettings.restored(during, original: original)
        check(NSDictionary(dictionary: restored["HCITraces"] as? [String:Any] ?? [:]) == NSDictionary(dictionary: original["HCITraces"] as? [String:Any] ?? [:]), "restore previous trace values")
        check(restored["ConcurrentPreference"] as? String == "new", "retain unrelated concurrent preference")
        check(GoogleTraceSettings.restored(enabled, original: [:])["HCITraces"] == nil, "remove trace key when originally absent")
        var legacy = LegacyPressFilter()
        check(legacy.accept(0x52), "legacy first press accepted")
        check(!legacy.accept(0x52), "legacy repeated report must not increment action reference count")
        check(legacy.accept(0), "legacy release accepted")
        check(legacy.accept(0x52), "legacy press works again after release")
        check(GoogleCapturePolicy.shouldSeize(active:true, deviceCount:1, connected:true, currentID:uuid, sessionID:uuid), "seize selected connected remote")
        check(!GoogleCapturePolicy.shouldSeize(active:true, deviceCount:1, connected:true, currentID:"OTHER", sessionID:uuid), "never seize a different replacement remote")
        check(!GoogleCapturePolicy.shouldSeize(active:true, deviceCount:1, connected:false, currentID:uuid, sessionID:uuid), "release exclusivity when disconnected")
        check(!GoogleCapturePolicy.shouldSeize(active:true, deviceCount:2, connected:true, currentID:uuid, sessionID:uuid), "do not seize ambiguous HID devices")
        check(!GoogleCapturePolicy.shouldSeize(active:false, deviceCount:1, connected:true, currentID:uuid, sessionID:uuid), "inactive capture must share HID")
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
