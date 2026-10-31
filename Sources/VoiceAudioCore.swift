import Foundation

// ============ ADPCM (IMA, low-nibble-first, 16 kHz mono) ============
struct ADPCM {
    static let step: [Int32] = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    static let idxT: [Int32] = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]
    var pred: Int32 = 0, idx: Int32 = 0
    var highFirst = false   // Google 遥控器固件高 nibble 在前；小米低 nibble 在前
    mutating func reset() { pred = 0; idx = 0 }
    mutating func nib(_ n: UInt8) -> Float {
        let s = ADPCM.step[Int(idx)]; var d = s >> 3
        if n & 4 != 0 { d += s }; if n & 2 != 0 { d += s >> 1 }; if n & 1 != 0 { d += s >> 2 }
        pred += (n & 8 != 0) ? -d : d; pred = max(-32768, min(32767, pred))
        idx += ADPCM.idxT[Int(n & 15)]; idx = max(0, min(88, idx))
        return Float(pred) / 32768.0
    }
    mutating func decode(_ data: Data) -> [Float] {
        var o = [Float](); o.reserveCapacity(data.count * 2)
        for b in data {
            if highFirst { o.append(nib((b >> 4) & 15)); o.append(nib(b & 15)) }
            else { o.append(nib(b & 15)); o.append(nib((b >> 4) & 15)) }
        }
        return o
    }
}

// ============ 16 kHz voice filters and conservative level processing ============
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    mutating func reset() { z1 = 0; z2 = 0 }
    mutating func run(_ x: Float) -> Float {
        let y = b0*x + z1
        z1 = b1*x - a1*y + z2
        z2 = b2*x - a2*y
        return y
    }
    static func highpass(f0: Float, fs: Float, q: Float) -> Biquad {
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1+al
        var b = Biquad()
        b.b0 = (1+cw)/2/a0; b.b1 = -(1+cw)/a0; b.b2 = (1+cw)/2/a0
        b.a1 = -2*cw/a0; b.a2 = (1-al)/a0
        return b
    }
    static func peaking(f0: Float, fs: Float, q: Float, dbGain: Float) -> Biquad {
        let A = pow(10, dbGain/40)
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1 + al/A
        var b = Biquad()
        b.b0 = (1 + al*A)/a0; b.b1 = -2*cw/a0; b.b2 = (1 - al*A)/a0
        b.a1 = -2*cw/a0; b.a2 = (1 - al/A)/a0
        return b
    }
}

struct VoiceDSP {
    var hp = Biquad.highpass(f0: 80, fs: 16000, q: 0.707)
    var gain: Float = 4
    private var peak: Float = 0
    mutating func reset() { hp.reset(); gain = 4; peak = 0 }
    mutating func process(_ xs: [Float]) -> [Float] {
        var out = [Float](); out.reserveCapacity(xs.count)
        for input in xs {
            let x = hp.run(input.isFinite ? input : 0) * gain
            // Fixed gain preserves pauses and quiet speech. The limiter only attenuates;
            // it never learns a high gain from background noise or applies a hard gate.
            peak = max(abs(x), peak * 0.9995)
            let attenuation = min(1, 0.95 / max(peak, 0.000001))
            out.append(x * attenuation)
        }
        return out
    }
}

// ============ ring buffer feeding BlackHole ============
final class Ring {
    private var buf: [Float]; private var r = 0, w = 0, cnt = 0
    private let lock = NSLock(); let cap: Int
    init(_ c: Int) { cap = c; buf = [Float](repeating: 0, count: c) }
    func push(_ s: [Float]) { lock.lock(); defer { lock.unlock() }
        for v in s { buf[w] = v; w = (w+1)%cap; if cnt < cap { cnt += 1 } else { r = (r+1)%cap } } }
    func pop(_ p: UnsafeMutablePointer<Float>, _ n: Int) { lock.lock(); defer { lock.unlock() }
        var i = 0; while i < n && cnt > 0 { p[i] = buf[r]; r = (r+1)%cap; cnt -= 1; i += 1 }
        while i < n { p[i] = 0; i += 1 } }
}

