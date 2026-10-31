// Non-exclusive, read-only observer. No key injection or peripheral writes.
// swiftc scripts/diagnose-chromecast-hid.swift -o /tmp/chromecast-hid-observer
// /tmp/chromecast-hid-observer 120
import Foundation
import IOKit.hid

let started = ProcessInfo.processInfo.systemUptime
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func log(_ message: String) {
    print("\(formatter.string(from: Date())) +\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)) \(message)")
    fflush(stdout)
}
final class Observation {
    let device: IOHIDDevice
    let id: UInt64
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: Int
    var reports = 0
    var values = 0
    init(_ device: IOHIDDevice, _ id: UInt64) {
        self.device = device; self.id = id
        capacity = max(8, (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64)
        buffer = .allocate(capacity: capacity)
    }
    deinit { buffer.deallocate() }
}
var active: [UInt64: Observation] = [:]
// Keep callback contexts and buffers alive through device removals until exit.
var retained: [Observation] = []
func registryID(_ device: IOHIDDevice) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
    return id
}
func observe(_ device: IOHIDDevice) {
    let id = registryID(device)
    guard active[id] == nil else { return }
    let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    log("ARRIVAL id=\(id) open=\(String(format: "0x%08x", result))")
    guard result == kIOReturnSuccess else { return }
    let entry = Observation(device, id)
    retained.append(entry); active[id] = entry
    let context = Unmanaged.passUnretained(entry).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(device, entry.buffer, entry.capacity, { context, result, _, type, reportID, bytes, length in
        guard let context else { return }
        let entry = Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue()
        entry.reports += 1
        let raw = (0..<max(0, min(length, 64))).map { String(format: "%02x", bytes[$0]) }.joined(separator: " ")
        log("REPORT device=\(entry.id) status=\(result) type=\(type.rawValue) reportID=\(reportID) len=\(length) bytes=[\(raw)]")
    }, context)
    IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
        guard let context else { return }
        let entry = Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue()
        entry.values += 1
        let element = IOHIDValueGetElement(value)
        log("VALUE device=\(entry.id) status=\(result) reportID=\(IOHIDElementGetReportID(element)) page=\(IOHIDElementGetUsagePage(element)) usage=\(IOHIDElementGetUsage(element)) value=\(IOHIDValueGetIntegerValue(value))")
    }, context)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
}
let seconds = min(600, max(1, Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120))
log("START duration=\(seconds)s access=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0=granted, 1=denied, 2=unknown)")
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: 0x18D1, kIOHIDProductIDKey as String: 0x9450] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in observe(device) }, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
    let id = registryID(device)
    log("REMOVAL id=\(id)")
    active.removeValue(forKey: id)
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
log("MANAGER open=\(result)")
if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
    for device in devices { observe(device) }
}
log("READY active=\(active.count); press isolated UP x3, BACK x3, then UP+BACK, then hold VOICE")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
for entry in retained {
    IOHIDDeviceUnscheduleFromRunLoop(entry.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
    log("SUMMARY device=\(entry.id) reports=\(entry.reports) values=\(entry.values)")
}
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
log("DONE")
