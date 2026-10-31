import Foundation

/// One automatic attempt per application run; never loop administrator dialogs.
struct CaptureStartup {
    private var attempted = false
    private var suppressed = false
    mutating func shouldStart(enabled: Bool, ready: Bool, active: Bool) -> Bool {
        guard enabled, ready, !active, !attempted, !suppressed else { return false }
        attempted = true
        return true
    }
    mutating func markAttempted() { attempted = true; suppressed = false }
    mutating func suppress() { suppressed = true }
    mutating func reset() { attempted = false; suppressed = false }
}
