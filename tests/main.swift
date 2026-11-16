// Unit tests of the calibration maths on synthetic data. Run by GitHub Actions before the build (never on the Mac).
import Foundation
import CoreGraphics
import simd

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    if ok { print("ok   " + msg) } else { print("FAIL " + msg); failures += 1 }
}

struct LCG { var s: UInt64 = 12345
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 33) & 0xFFFFFF) / Double(0xFFFFFF) }
    mutating func gauss() -> Double { let a = max(1e-9, next()), b = next(); return (-2 * log(a)).squareRoot() * cos(2 * .pi * b) }
}
var rng = LCG()

let W = 1920, H = 1080
let Ktrue = Intrinsics(fx: 640, fy: 640, cx: 970, cy: 530, k: [-0.04, 0.012, -0.002, 0.0003], width: W, height: H)
let board = boardPoints(cols: 8, rows: 6, spacing: 0.04)

// 1. project / unproject round trip, also far from the centre
do {
    var worst = 0.0
    for (x, y) in [(0.0, 0.0), (0.3, -0.2), (1.0, 0.7), (-1.5, 0.4)] {
        let p = Ktrue.project(V3(x, y, 1))!
        let q = Ktrue.unproject(p)
        worst = max(worst, hypot(q.x - x, q.y - y))
    }
    check(worst < 1e-6, "project/unproject round trip (\(worst))")
}

// random board poses in front of the camera
func randomPose() -> Pose6 {
    let r = V3(rng.next() * 0.9 - 0.45, rng.next() * 0.9 - 0.45, rng.next() * 0.6 - 0.3)
    let t = V3(rng.next() * 0.3 - 0.35, rng.next() * 0.2 - 0.15, 0.5 + rng.next() * 0.6)
    return Pose6(r: r, t: t)
}
func view(_ K: Intrinsics, _ pose: Pose6, noise: Double) -> [V2]? {
    var out: [V2] = []
    for X in board {
        guard let p = K.project(pose.apply(X)) else { return nil }
        if p.x < 0 || p.y < 0 || p.x > Double(K.width) || p.y > Double(K.height) { return nil }
        out.append(V2(p.x + rng.gauss() * noise, p.y + rng.gauss() * noise))
    }
    return out
}

// 2. intrinsics from 16 noisy views
var views: [[V2]] = []
while views.count < 16 { if let v = view(Ktrue, randomPose(), noise: 0.3) { views.append(v) } }
if let res = calibrateCamera(views: views, board: board, width: W, height: H) {
    let K = res.K
    check(abs(K.fx - Ktrue.fx) / Ktrue.fx < 0.03, "focal length fx \(K.fx) vs \(Ktrue.fx)")
    check(abs(K.cx - Ktrue.cx) < 12 && abs(K.cy - Ktrue.cy) < 12, "principal point \(K.cx), \(K.cy)")
    check(res.rms < 0.6, "intrinsics reprojection error \(res.rms) px")
} else { check(false, "calibrateCamera returned nil") }

// 3. stereo: camera B stands 0.3 m to the right and turned 12 degrees
let Rab = rodrigues(V3(0, -0.21, 0)), tab = V3(-0.3, 0.02, 0.05)
let Kb = Intrinsics(fx: 900, fy: 900, cx: 960, cy: 540, k: [0.01, 0, 0, 0], width: W, height: H)
var pairs: [([V2], [V2])] = []
var tries = 0
while pairs.count < 12 && tries < 500 {
    tries += 1
    let p = randomPose()
    let pb = Pose6(r: rodriguesInv(Rab * p.R), t: Rab * p.t + tab)
    if let a = view(Ktrue, p, noise: 0.3), let b = view(Kb, pb, noise: 0.3) { pairs.append((a, b)) }
}
if let e = calibrateStereo(pairs: pairs, board: board, A: Ktrue, B: Kb) {
    let dr = length(rodriguesInv(e.R * Rab.transpose)) * 180 / .pi
    let dt = length(e.T - tab)
    check(dr < 0.5, "stereo rotation error \(dr) deg")
    check(dt < 0.01, "stereo translation error \(dt) m")
    check(e.rms < 1.0, "stereo reprojection error \(e.rms) px")
} else { check(false, "calibrateStereo returned nil") }

// 4. triangulation, noiseless and with half a pixel of noise
do {
    var worst = 0.0, worstN = 0.0
    for _ in 0..<50 {
        let X = V3(rng.next() - 0.5, rng.next() - 0.5, 1.5 + rng.next())
        let pa = Ktrue.project(X)!, pb = Kb.project(Rab * X + tab)!
        let r0 = [Ray(xy: Ktrue.unproject(pa), R: matrix_identity_double3x3, t: V3(0, 0, 0), w: 1),
                  Ray(xy: Kb.unproject(pb), R: Rab, t: tab, w: 1)]
        if let T = triangulate(r0) { worst = max(worst, length(T - X)) } else { worst = 1 }
        let pa2 = pa + V2(rng.gauss() * 0.5, rng.gauss() * 0.5), pb2 = pb + V2(rng.gauss() * 0.5, rng.gauss() * 0.5)
        let r1 = [Ray(xy: Ktrue.unproject(pa2), R: matrix_identity_double3x3, t: V3(0, 0, 0), w: 1),
                  Ray(xy: Kb.unproject(pb2), R: Rab, t: tab, w: 1)]
        if let T = triangulate(r1) { worstN = max(worstN, length(T - X)) } else { worstN = 1 }
    }
    check(worst < 1e-4, "triangulation noiseless worst error \(worst) m")
    check(worstN < 0.03, "triangulation with 0.5 px noise worst error \(worstN) m")
}

// 5. sync offset: B shows the same moment 0.18 s later
do {
    var a: [(Double, Double)] = [], b: [(Double, Double)] = []
    let spikes = [1.0, 2.6, 3.1, 4.4]
    func sig(_ t: Double) -> Double { spikes.reduce(0.0) { $0 + exp(-pow((t - $1) / 0.05, 2)) } }
    var t = 0.0
    while t < 6 { a.append((t, sig(t))); t += 1.0 / 30 }
    t = 0.0
    while t < 6 { b.append((t + 0.013, sig(t - 0.18))); t += 1.0 / 25 }       // different frame rate and phase
    if let r = estimateOffset(a: a, b: b) { check(abs(r.offset - 0.18) < 0.02, "sync offset \(r.offset) s (true 0.18)") }
    else { check(false, "estimateOffset returned nil") }
}

// 6. the circle-grid detector on a rendered board, turned 25 and 110 degrees
func renderBoard(angleDeg: Double, w: Int = 1280, h: Int = 720) -> [UInt8] {
    var buf = [UInt8](repeating: 255, count: w * h)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: Double(w) / 2, y: Double(h) / 2)
        ctx.rotate(by: angleDeg * .pi / 180)
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        let s = 62.0
        for y in 0..<6 { for x in 0..<8 {
            let d = (x == 0 && y == 0) ? 0.85 * s : 0.5 * s
            let cx = (Double(x) - 3.5) * s, cy = (Double(y) - 2.5) * s
            ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
        } }
    }
    return buf
}
for ang in [25.0, 110.0, 200.0, 300.0] {
    let g = renderBoard(angleDeg: ang)
    if let pts = detectBoard(gray: g, width: 1280, height: 720) {
        check(pts.count == 48, "board detected at \(ang) deg")
        // row neighbours are about one spacing apart, and the first point is the marker (the big circle)
        let d = length(pts[1] - pts[0])
        check(abs(d - 62) < 3, "spacing between point 0 and 1 is \(d) at \(ang) deg")
        // the order must be right-handed: x direction cross y direction positive
        let xd = pts[1] - pts[0], yd = pts[8] - pts[0]
        check(xd.x * yd.y - xd.y * yd.x > 0, "right-handed order at \(ang) deg")
    } else { check(false, "board not detected at \(ang) deg") }
}

// 7. the PDF writes
do {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("skeleton-board-test.pdf")
    check(BoardSpec.writePDF(to: u, a3: false) && (try? Data(contentsOf: u).count) ?? 0 > 1000, "A4 board PDF written")
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
