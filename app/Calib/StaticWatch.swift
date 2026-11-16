// StaticWatch.swift: a source whose picture never changes (the OBS Virtual Camera's placeholder logo, a frozen feed) and in
// which no person was ever seen is not a camera picture. Pure maths on small luminance signatures, unit-tested in CI.
import Foundation

struct StaticWatch {
    var window = 2.0                     // seconds without change
    var threshold = 0.4                  // mean absolute difference (of 255) on the signature grid that still counts as "no change"
    private(set) var personSeen = false
    private(set) var isStatic = false
    private var frames: [(t: Double, sig: [UInt8])] = []

    mutating func reset() { personSeen = false; isStatic = false; frames = [] }

    static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var s = 0
        for i in 0..<n { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(n)
    }

    /// One analysed frame: its time, its luminance signature and whether a person was found. Returns true while the source is static.
    @discardableResult
    mutating func add(t: Double, sig: [UInt8], person: Bool) -> Bool {
        if person { personSeen = true }
        if personSeen { frames = []; isStatic = false; return false }
        guard !sig.isEmpty else { return isStatic }
        if let last = frames.last, t < last.t { frames = [] }              // the clock went back: start again
        frames.append((t, sig))
        while let f = frames.first, t - f.t > window + 0.5 { frames.removeFirst() }
        guard let first = frames.first, t - first.t >= window else { return isStatic }
        var worst = 0.0
        for f in frames { worst = max(worst, StaticWatch.meanAbsDiff(f.sig, sig)) }
        isStatic = worst < threshold
        return isStatic
    }
}
