import Foundation

/// ATVV v1.0 MIC_EXTEND scheduling for the active 16 kHz Google voice stream.
/// No software duration cap: the physical release/disconnect owns the end of a hold.
struct VoiceSession {
    private(set) var streamID: UInt8?
    private(set) var sentCount = 0
    private var nextExtension: TimeInterval?

    @discardableResult
    mutating func begin(_ control: Data, at now: TimeInterval) -> Bool {
        let bytes = Array(control)
        guard now.isFinite, bytes.count >= 4, bytes[0] == 0x04, bytes[2] == 0x02 else { return false }
        guard streamID != bytes[3] else { return false }
        streamID = bytes[3]
        sentCount = 0
        nextExtension = now + 5
        return true
    }
    mutating func poll(at now: TimeInterval) -> Data? {
        guard now.isFinite, let streamID, let due = nextExtension, now >= due else { return nil }
        nextExtension = now + 5
        sentCount += 1
        return Data([0x0E, streamID])
    }
    static func audioStalled(at now: TimeInterval, startedAt: TimeInterval, lastAudioAt: TimeInterval?) -> Bool {
        let reference = lastAudioAt ?? startedAt
        return !now.isFinite || !reference.isFinite || now - reference >= 3
    }
    mutating func stop() {
        streamID = nil
        nextExtension = nil
    }
}
