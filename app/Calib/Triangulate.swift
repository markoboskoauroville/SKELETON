// Triangulate.swift: confidence-weighted DLT from undistorted rays, the sync offset, and the frontal view of a 3D body
// (so the matching does not depend on where the cameras stand).
import Foundation
import simd
import CoreGraphics

struct Ray { var xy: V2; var R: M3; var t: V3; var w: Double }

/// Point in camera A's frame seen by rays with projection [R|t] (A: identity).
func triangulate(_ rays: [Ray]) -> V3? {
    guard rays.count >= 2 else { return nil }
    var rows: [[Double]] = []
    for r in rays {
        func P(_ i: Int) -> [Double] { [r.R[0][i], r.R[1][i], r.R[2][i], r.t[i]] }
        let p1 = P(0), p2 = P(1), p3 = P(2)
        rows.append((0..<4).map { r.w * (r.xy.x * p3[$0] - p1[$0]) })
        rows.append((0..<4).map { r.w * (r.xy.y * p3[$0] - p2[$0]) })
    }
    let v = nullVector(rows: rows, n: 4)
    guard abs(v[3]) > 1e-12 else { return nil }
    let X = V3(v[0] / v[3], v[1] / v[3], v[2] / v[3])
    for r in rays { if (r.R * X + r.t).z <= 0 { return nil } }
    return X
}

/// How much later camera B shows the same moment than camera A (seconds): b(t + offset) = a(t).
/// Signals are (time, value) lists (a brightness change, or the speed of a joint); resampled at 100 Hz and cross-correlated.
func estimateOffset(a: [(Double, Double)], b: [(Double, Double)], maxLag: Double = 1.0) -> (offset: Double, peak: Double)? {
    func resample(_ s: [(Double, Double)], _ t0: Double, _ t1: Double) -> [Double] {
        let n = Int((t1 - t0) * 100)
        guard n > 20, s.count > 2 else { return [] }
        var out = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = t0 + Double(i) / 100
            while j + 1 < s.count - 1 && s[j + 1].0 < t { j += 1 }
            let (ta, va) = s[j], (tb, vb) = s[j + 1]
            let u = tb > ta ? min(1, max(0, (t - ta) / (tb - ta))) : 0
            out[i] = va + (vb - va) * u
        }
        let m = out.reduce(0, +) / Double(n)
        let sd = max(1e-9, (out.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(n)).squareRoot())
        return out.map { ($0 - m) / sd }
    }
    guard let a0 = a.first?.0, let a1 = a.last?.0, let b0 = b.first?.0, let b1 = b.last?.0 else { return nil }
    let t0 = max(a0, b0 - maxLag) , t1 = min(a1, b1 + maxLag)
    let lo = min(a0, b0) , hi = max(a1, b1)
    let A = resample(a, lo, hi), B = resample(b, lo, hi)
    _ = (t0, t1)
    guard A.count == B.count, A.count > 50 else { return nil }
    let lags = Int(maxLag * 100)
    var best = -Double.infinity, bestLag = 0
    var scores: [Int: Double] = [:]
    for lag in -lags...lags {
        var s = 0.0
        for i in 0..<A.count {
            let j = i + lag
            if j >= 0 && j < B.count { s += A[i] * B[j] }
        }
        scores[lag] = s
        if s > best { best = s; bestLag = lag }
    }
    var frac = 0.0
    if let l = scores[bestLag - 1], let r = scores[bestLag + 1] {
        let d = l - 2 * best + r
        if abs(d) > 1e-9 { frac = 0.5 * (l - r) / d }
    }
    return (offset: (Double(bestLag) + frac) / 100, peak: best / Double(A.count))
}

/// The body seen from the front: x along the shoulder line (subject's left = +x, like the target poses), y down along the spine.
func frontalPose(_ j: [Jt: V3], aspect: CGFloat) -> Pose? {
    guard let neck = j[.neck], let ls = j[.leftShoulder], let rs = j[.rightShoulder] else { return nil }
    var hip: V3
    if let l = j[.leftHip], let r = j[.rightHip] { hip = (l + r) / 2 } else if let r = j[.root] { hip = r } else { return nil }
    var up = neck - hip
    guard length(up) > 1e-6 else { return nil }
    up = normalize(up)
    var lr = ls - rs
    lr -= up * dot(lr, up)
    guard length(lr) > 1e-6 else { return nil }
    let right = normalize(lr)
    var p = Pose(aspect: aspect)
    // y in the camera frame points down, so "up" computed from the points is already consistent; the picture's y is down
    for (k, v) in j {
        let rel = v - hip
        p.j[k] = CGPoint(x: dot(rel, right), y: -dot(rel, up))
    }
    // shift so that the hip centre is at (0.5 * aspect, 0.6) like a picture, and scale to a person of torso ~0.25
    return p
}
