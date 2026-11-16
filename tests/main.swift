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
    var worst = 0.0, errsN: [Double] = []
    for _ in 0..<50 {
        let X = V3(rng.next() - 0.5, rng.next() - 0.5, 1.5 + rng.next())
        let pa = Ktrue.project(X)!, pb = Kb.project(Rab * X + tab)!
        let r0 = [Ray(xy: Ktrue.unproject(pa), R: matrix_identity_double3x3, t: V3(0, 0, 0), w: 1),
                  Ray(xy: Kb.unproject(pb), R: Rab, t: tab, w: 1)]
        if let T = triangulate(r0) { worst = max(worst, length(T - X)) } else { worst = 1 }
        let pa2 = pa + V2(rng.gauss() * 0.5, rng.gauss() * 0.5), pb2 = pb + V2(rng.gauss() * 0.5, rng.gauss() * 0.5)
        let r1 = [Ray(xy: Ktrue.unproject(pa2), R: matrix_identity_double3x3, t: V3(0, 0, 0), w: 1),
                  Ray(xy: Kb.unproject(pb2), R: Rab, t: tab, w: 1)]
        errsN.append(triangulate(r1).map { length($0 - X) } ?? 1)
    }
    check(worst < 1e-4, "triangulation noiseless worst error \(worst) m")
    let med = errsN.sorted()[errsN.count / 2]
    check(med < 0.03, "triangulation with 0.5 px noise median error \(med) m")
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
        ctx.scaleBy(x: 1, y: -1)                          // memory row 0 is the top: draw with y down like a picture
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

// 8. bundle adjustment on synthetic rigs of 4 cameras with 0.8 px noise: pairs are chained (camera i from camera i-1, 12 pairs
// each, as the app does) and then every camera is refined together over all board views.
do {
    func lookAt(_ C: V3, _ target: V3) -> Pose6 {
        let f = normalize(target - C)
        let right = normalize(cross(V3(0, 1, 0), f))
        let down = cross(f, right)
        let R = rowsMatrix(right, down, f)
        return Pose6(r: rodriguesInv(R), t: -(R * C))
    }
    func compose(_ e: Extrinsics, _ prev: Pose6?) -> Pose6 {
        guard let p = prev else { return Pose6(r: rodriguesInv(e.R), t: e.T) }
        return Pose6(r: rodriguesInv(e.R * p.R), t: e.R * p.t + e.T)
    }
    func centre(_ p: Pose6) -> V3 { -(p.R.transpose * p.t) }
    let target = V3(0.15, 0, 0.8)
    let truth: [Pose6] = [Pose6(r: V3(0, 0, 0), t: V3(0, 0, 0)), lookAt(V3(0.35, 0, 0), target), lookAt(V3(0.7, 0.05, 0.1), target), lookAt(V3(-0.35, -0.05, 0.05), target)]
    let Ks: [Intrinsics] = [Ktrue, Kb,
                            Intrinsics(fx: 700, fy: 700, cx: 950, cy: 545, k: [0.02, 0, 0, 0], width: W, height: H),
                            Intrinsics(fx: 620, fy: 620, cx: 965, cy: 535, k: [-0.03, 0.005, 0, 0], width: W, height: H)]
    var chainedErr = 0.0, baErr = 0.0, chainedRot = 0.0, baRot = 0.0
    var lastResult: BAResult?, lastViews: [BAView] = [], lastChained: [Pose6] = []
    var reduced = 0, trials = 0
    for _ in 0..<5 {
        var views: [BAView] = []
        var guardCount = 0
        while views.count < 60 && guardCount < 2000 {
            guardCount += 1
            let Rb = rodrigues(V3(rng.next() * 0.7 - 0.35, rng.next() * 0.7 - 0.35, rng.next() * 0.7 - 0.35))
            let centre0 = target + V3(rng.next() * 0.2 - 0.1, rng.next() * 0.16 - 0.08, rng.next() * 0.2 - 0.1)
            let tb = centre0 - Rb * V3(0.14, 0.1, 0)
            var obs: [Int: [V2]] = [:]
            for c in 0..<4 {
                let w2c = truth[c]
                let pc = Pose6(r: rodriguesInv(w2c.R * Rb), t: w2c.R * tb + w2c.t)
                if let v = view(Ks[c], pc, noise: 0.8) { obs[c] = v }
            }
            if obs.count >= 2 { views.append(BAView(obs: obs)) }
        }
        // chained: 1 from 0, 2 from 1, 3 from 2
        var chained: [Pose6] = [truth[0]]
        var ok = true
        for i in 1..<4 {
            let j = i - 1
            let pairs = views.compactMap { v -> ([V2], [V2])? in
                if let a = v.obs[j], let b = v.obs[i] { return (a, b) } else { return nil }
            }.prefix(12)
            guard pairs.count >= 6, let e = calibrateStereo(pairs: Array(pairs), board: board, A: Ks[j], B: Ks[i]) else { ok = false; break }
            chained.append(compose(e, j == 0 ? nil : chained[j]))
        }
        guard ok else { continue }
        trials += 1
        guard let r = bundleAdjust(K: Ks, poses: chained, views: views, board: board) else { check(false, "bundleAdjust returned nil"); continue }
        if r.rmsAfter < r.rmsBefore { reduced += 1 }
        for i in 1..<4 {
            chainedErr += length(centre(chained[i]) - centre(truth[i])); baErr += length(centre(r.poses[i]) - centre(truth[i]))
            chainedRot += length(rodriguesInv(chained[i].R * truth[i].R.transpose)) * 180 / .pi
            baRot += length(rodriguesInv(r.poses[i].R * truth[i].R.transpose)) * 180 / .pi
        }
        lastResult = r; lastViews = views; lastChained = chained
    }
    check(trials >= 4, "bundle adjustment: \(trials) of 5 synthetic rigs calibrated")
    check(reduced == trials, "bundle adjustment lowers the reprojection error in every rig (\(reduced)/\(trials))")
    check(baErr < chainedErr, String(format: "camera positions: chained %.4f m total, bundle adjusted %.4f m total", chainedErr, baErr))
    check(baRot < chainedRot, String(format: "camera rotations: chained %.3f deg total, bundle adjusted %.3f deg total", chainedRot, baRot))
    if let r = lastResult {
        check(r.rmsAfter < 1.4, "bundle adjusted reprojection error \(r.rmsAfter) px (noise floor about 1.13)")
        check(r.rmsBefore > r.rmsAfter, "reprojection error \(r.rmsBefore) px with chained poses, \(r.rmsAfter) px after")
        // intrinsics too: camera 3's focal length starts 2 percent off
        var Kp = Ks
        Kp[3] = Intrinsics(fx: Ks[3].fx * 1.02, fy: Ks[3].fy * 1.02, cx: Ks[3].cx, cy: Ks[3].cy, k: Ks[3].k, width: W, height: H)
        if let r2 = bundleAdjust(K: Kp, poses: lastChained, views: lastViews, board: board, refineIntrinsics: true) {
            check(r2.rmsAfter < r2.rmsBefore, "with intrinsics: \(r2.rmsBefore) px -> \(r2.rmsAfter) px")
            check(abs(r2.K[3].fx - Ks[3].fx) < abs(Kp[3].fx - Ks[3].fx), "camera 3 focal length \(r2.K[3].fx) closer to \(Ks[3].fx) than the start \(Kp[3].fx)")
        } else { check(false, "bundleAdjust with intrinsics returned nil") }
    }
}

// 9. the static-picture check (the OBS placeholder logo): no change for 2 s and no person = static; noise, motion or a person = not
do {
    var w = StaticWatch()
    let logo = (0..<1296).map { UInt8(($0 * 37) % 200 + 20) }
    var verdict = false, t = 0.0
    while t < 1.9 { verdict = w.add(t: t, sig: logo, person: false); t += 1.0 / 30 }
    check(!verdict, "a still picture is not yet static before 2 s")
    while t < 2.4 { verdict = w.add(t: t, sig: logo, person: false); t += 1.0 / 30 }
    check(verdict, "a picture that never changes is static after 2 s")
    t += 0.1
    check(!w.add(t: t, sig: logo, person: true), "a person seen: not static")
    check(!w.add(t: t + 5, sig: logo, person: false), "a person seen once: never static again")
    var n = StaticWatch(), nv = false, tt = 0.0
    while tt < 4 { nv = n.add(t: tt, sig: logo.map { UInt8(max(0, min(255, Int($0) + Int(rng.gauss() * 2)))) }, person: false); tt += 1.0 / 30 }
    check(!nv, "a noisy real camera is not static")
    var m = StaticWatch(), mv = false, mt = 0.0
    while mt < 4 { let shift = Int(mt * 10); mv = m.add(t: mt, sig: logo.map { UInt8(min(255, Int($0) + shift % 40)) }, person: false); mt += 1.0 / 30 }
    check(!mv, "a changing picture is not static")
}

// 7. the PDF writes
do {
    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("skeleton-board-test.pdf")
    check(BoardSpec.writePDF(to: u, a3: false) && (try? Data(contentsOf: u).count) ?? 0 > 1000, "A4 board PDF written")
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
