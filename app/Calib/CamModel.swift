// CamModel.swift: the lens model (Kannala-Brandt fisheye, 4 coefficients: handles the very wide Sony lens and, with
// small coefficients, an ordinary phone or FaceTime lens), the board, pose from a plane, Zhang-style calibration with
// a multi-start focal guess and a full refinement, stereo extrinsics.
import Foundation
import simd

struct Intrinsics: Codable {
    var fx: Double, fy: Double, cx: Double, cy: Double
    var k: [Double]          // k1...k4
    var width: Int, height: Int

    /// Camera-frame point (z > 0) -> pixel.
    func project(_ X: V3) -> V2? {
        guard X.z > 1e-9 else { return nil }
        let x = X.x / X.z, y = X.y / X.z
        let r = (x * x + y * y).squareRoot()
        let th = atan(r), t2 = th * th
        let thd = th * (1 + t2 * (k[0] + t2 * (k[1] + t2 * (k[2] + t2 * k[3]))))
        let s = r > 1e-9 ? thd / r : 1
        return V2(fx * x * s + cx, fy * y * s + cy)
    }

    /// Pixel -> normalised ray (x, y) at z = 1.
    func unproject(_ p: V2) -> V2 {
        let du = (p.x - cx) / fx, dv = (p.y - cy) / fy
        let thd = (du * du + dv * dv).squareRoot()
        if thd < 1e-9 { return V2(du, dv) }
        var th = min(thd, 1.5)
        for _ in 0..<25 {
            let t2 = th * th
            let f = th * (1 + t2 * (k[0] + t2 * (k[1] + t2 * (k[2] + t2 * k[3])))) - thd
            let d = 1 + t2 * (3 * k[0] + t2 * (5 * k[1] + t2 * (7 * k[2] + t2 * 9 * k[3])))
            if abs(d) < 1e-9 { break }
            th -= f / d
            th = max(0, min(th, 1.55))
        }
        let r = tan(th)
        return V2(du / thd * r, dv / thd * r)
    }
}

struct Pose6 { var r: V3; var t: V3
    var R: M3 { rodrigues(r) }
    func apply(_ X: V3) -> V3 { R * X + t }
}

/// The board: cols x rows circles, spacing in metres, row-major, origin at the marker circle (0,0).
func boardPoints(cols: Int, rows: Int, spacing: Double) -> [V3] {
    var p: [V3] = []
    for y in 0..<rows { for x in 0..<cols { p.append(V3(Double(x) * spacing, Double(y) * spacing, 0)) } }
    return p
}

private func rms(_ r: [Double]) -> Double { (r.reduce(0) { $0 + $1 * $1 } / Double(max(1, r.count / 2))).squareRoot() }

func reprojectionResiduals(_ K: Intrinsics, _ pose: Pose6, _ board: [V3], _ pts: [V2]) -> [Double] {
    let R = pose.R
    var out: [Double] = []
    out.reserveCapacity(board.count * 2)
    for (i, X) in board.enumerated() {
        if let p = K.project(R * X + pose.t) { out.append(p.x - pts[i].x); out.append(p.y - pts[i].y) }
        else { out.append(1000); out.append(1000) }
    }
    return out
}

/// Pose of the board in the camera: homography on the rays, then Levenberg-Marquardt on the pixels.
func solvePnP(_ K: Intrinsics, board: [V3], pts: [V2]) -> (Pose6, Double)? {
    let rays = pts.map { K.unproject($0) }
    guard let H = homography(src: board.map { V2($0.x, $0.y) }, dst: rays) else { return nil }
    let h1 = H.columns.0, h2 = H.columns.1, h3 = H.columns.2
    let lam = 2 / (length(h1) + length(h2))
    var r1 = h1 * lam, r2 = h2 * lam, t = h3 * lam
    if t.z < 0 { r1 = -r1; r2 = -r2; t = -t }
    let R = orthonormalise(M3(columns: (r1, r2, cross(r1, r2))))
    let r0 = rodriguesInv(R)
    let x0 = [r0.x, r0.y, r0.z, t.x, t.y, t.z]
    let x = levenbergMarquardt(x0, iterations: 30) { x in
        reprojectionResiduals(K, Pose6(r: V3(x[0], x[1], x[2]), t: V3(x[3], x[4], x[5])), board, pts)
    }
    let pose = Pose6(r: V3(x[0], x[1], x[2]), t: V3(x[3], x[4], x[5]))
    guard pose.t.z > 0 else { return nil }
    return (pose, rms(reprojectionResiduals(K, pose, board, pts)))
}

struct CalibResult { var K: Intrinsics; var poses: [Pose6]; var rms: Double }

/// Intrinsics of one camera from views of the board (image points ordered as `board`).
func calibrateCamera(views: [[V2]], board: [V3], width: Int, height: Int) -> CalibResult? {
    guard views.count >= 4 else { return nil }
    let w = Double(width), h = Double(height)
    var best: (Intrinsics, [Pose6], Double)?
    for f in [0.25, 0.35, 0.5, 0.7, 1.0] {
        let K0 = Intrinsics(fx: f * w, fy: f * w, cx: w / 2, cy: h / 2, k: [0, 0, 0, 0], width: width, height: height)
        var poses: [Pose6] = [], total = 0.0, n = 0
        for v in views {
            guard let (p, e) = solvePnP(K0, board: board, pts: v) else { poses = []; break }
            poses.append(p); total += e * e * Double(board.count); n += board.count
        }
        guard poses.count == views.count else { continue }
        let e = (total / Double(max(1, n))).squareRoot()
        if best == nil || e < best!.2 { best = (K0, poses, e) }
    }
    guard let (K0, poses0, _) = best else { return nil }
    var x0: [Double] = [K0.fx, K0.fy, K0.cx, K0.cy, 0, 0, 0, 0]
    for p in poses0 { x0 += [p.r.x, p.r.y, p.r.z, p.t.x, p.t.y, p.t.z] }
    func unpack(_ x: [Double]) -> (Intrinsics, [Pose6]) {
        let K = Intrinsics(fx: x[0], fy: x[1], cx: x[2], cy: x[3], k: [x[4], x[5], x[6], x[7]], width: width, height: height)
        var ps: [Pose6] = []
        for i in 0..<views.count {
            let o = 8 + i * 6
            ps.append(Pose6(r: V3(x[o], x[o + 1], x[o + 2]), t: V3(x[o + 3], x[o + 4], x[o + 5])))
        }
        return (K, ps)
    }
    let x = levenbergMarquardt(x0, iterations: 60) { x in
        let (K, ps) = unpack(x)
        var out: [Double] = []
        for (i, v) in views.enumerated() { out += reprojectionResiduals(K, ps[i], board, v) }
        for i in 4..<8 { out.append(x[i] * 0.5) }          // a soft prior keeps the coefficients quiet
        return out
    }
    let (K, ps) = unpack(x)
    var all: [Double] = []
    for (i, v) in views.enumerated() { all += reprojectionResiduals(K, ps[i], board, v) }
    guard K.fx > 0, K.fy > 0, all.allSatisfy({ $0.isFinite }) else { return nil }
    return CalibResult(K: K, poses: ps, rms: rms(all))
}

struct Extrinsics: Codable {
    var r: [Double]        // Rodrigues vector, camera A frame -> this camera frame
    var t: [Double]        // metres
    var rms: Double        // reprojection error in this camera, pixels
    var pairs: Int
    var R: M3 { rodrigues(V3(r[0], r[1], r[2])) }
    var T: V3 { V3(t[0], t[1], t[2]) }
}

/// The pose of camera B relative to camera A from pairs of simultaneous board views.
func calibrateStereo(pairs: [([V2], [V2])], board: [V3], A: Intrinsics, B: Intrinsics) -> Extrinsics? {
    var poseA: [Pose6] = [], ptsB: [[V2]] = []
    var cands: [(Double, V3, V3)] = []
    for (pa, pb) in pairs {
        guard let (a, ea) = solvePnP(A, board: board, pts: pa), let (b, eb) = solvePnP(B, board: board, pts: pb) else { continue }
        poseA.append(a); ptsB.append(pb)
        let Rab = b.R * a.R.transpose
        cands.append((ea + eb, rodriguesInv(Rab), b.t - Rab * a.t))
    }
    guard poseA.count >= 3, let first = cands.min(by: { $0.0 < $1.0 }) else { return nil }
    func residuals(_ x: [Double]) -> [Double] {
        let Rab = rodrigues(V3(x[0], x[1], x[2])), t = V3(x[3], x[4], x[5])
        var out: [Double] = []
        for i in 0..<poseA.count {
            for (j, X) in board.enumerated() {
                if let p = B.project(Rab * poseA[i].apply(X) + t) { out.append(p.x - ptsB[i][j].x); out.append(p.y - ptsB[i][j].y) }
                else { out.append(1000); out.append(1000) }
            }
        }
        return out
    }
    let x = levenbergMarquardt([first.1.x, first.1.y, first.1.z, first.2.x, first.2.y, first.2.z], iterations: 40, residuals: residuals)
    return Extrinsics(r: [x[0], x[1], x[2]], t: [x[3], x[4], x[5]], rms: rms(residuals(x)), pairs: poseA.count)
}
