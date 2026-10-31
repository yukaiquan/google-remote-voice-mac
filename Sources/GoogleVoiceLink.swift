import Foundation
import CoreBluetooth
import ObjectiveC

// macOS currently hides this central-side latency request from its public SDK.
// Do not invoke an unknown/mismatched ABI. The app remains usable when unavailable,
// but must report degraded voice transport instead of claiming a successful request.
enum GoogleVoiceLink {
    static func supportsABI(_ encoding: String?) -> Bool {
        encoding == "v32@0:8q16@24"
    }

    @discardableResult
    static func request(central: CBCentralManager, peripheral: CBPeripheral, lowLatency: Bool) -> Bool {
        guard central.state == .poweredOn, peripheral.state == .connected else { return false }
        let selector = NSSelectorFromString("setDesiredConnectionLatency:forPeripheral:")
        guard let method = class_getInstanceMethod(object_getClass(central), selector),
              let encoding = method_getTypeEncoding(method),
              supportsABI(String(cString: encoding)) else { return false }
        typealias Request = @convention(c) (AnyObject, Selector, Int, AnyObject) -> Void
        let invoke = unsafeBitCast(method_getImplementation(method), to: Request.self)
        invoke(central, selector, lowLatency ? 0 : 1, peripheral)
        return true
    }
}
