// BundleAdjust.swift: bundle adjustment across all cameras after the pairwise, chained calibration.
// Unknowns: the pose of every camera except camera 1 (index 0, the reference), the pose of every board view in camera 1's
// frame, and optionally every camera's intrinsics. Cost: the reprojection error of every board point in every camera that
// saw it. Levenberg-Marquardt on the sparse normal equations; each observation's Jacobian block is built with a numeric
// derivative and its J^T J, J^T r go through Accelerate (cblas_dsyrk, cblas_dgemv). Pure maths, unit-tested in CI.
import Foundation
import simd
import Accelerate

/// One board position seen by several cameras at (nearly) the same time: camera index -> the board points in board order.
struct BAView { var obs: [Int: [V2]] }

struct BAResult {
    var K: [Intrinsics]
    var poses: [Pose6]           // camera i relative to camera 1 (index 0 = identity), the same convention as Extrinsics
    var rmsBefore: Double        // pixels per point, with the chained poses (only the board positions fitted)
    var rmsAfter: Double
    var perCamera: [Double]      // rms per camera after
    var iterations: Int
    var views: Int
}

private func pxRms(_ r: [Double]) -> Double { (r.reduce(0) { $0 + $1 * $1 } / Double(max(1, r.count / 2))).squareRoot() }

/// Refine `poses` (and `K` when `refineIntrinsics`) of all cameras jointly. `poses[0]` must be the identity.
func bundleAdjust(K K0: [Intrinsics], poses poses0: [Pose6], views viewsIn: [BAView], board: [V3],
                  refineIntrinsics: Bool = false, iterations: Int = 30) -> BAResult? {
    let nCam = K0.count
    guard nCam >= 2, poses0.count == nCam, !board.isEmpty else { return nil }
    let views = viewsIn.compactMap { v -> BAView? in
        let ok = v.obs.filter { $0.key >= 0 && $0.key < nCam && $0.value.count == board.count }
        return ok.count >= 2 ? BAView(obs: ok) : nil
    }
    guard views.count >= 3 else { return nil }
    var used = Set<Int>()
    for v in views { for c in v.obs.keys { used.insert(c) } }
    let camList = used.sorted()
    guard camList.contains(0) else { return nil }
    let movers = camList.filter { $0 > 0 }

    // parameter layout: [camera poses (movers)] [board views] [intrinsics (camList)]
    var camOff = [Int: Int](), kOff = [Int: Int]()
    var n = 0
    for c in movers { camOff[c] = n; n += 6 }
    let viewBase = n
    n += 6 * views.count
    if refineIntrinsics { for c in camList { kOff[c] = n; n += 8 } }

    var x = [Double](repeating: 0, count: n)
    for c in movers { let p = poses0[c]; let o = camOff[c]!; x[o] = p.r.x; x[o + 1] = p.r.y; x[o + 2] = p.r.z; x[o + 3] = p.t.x; x[o + 4] = p.t.y; x[o + 5] = p.t.z }
    if refineIntrinsics {
        for c in camList { let k = K0[c]; let o = kOff[c]!; x[o] = k.fx; x[o + 1] = k.fy; x[o + 2] = k.cx; x[o + 3] = k.cy
            for i in 0..<4 { x[o + 4 + i] = k.k[i] } }
    }
    let xInit = x

    // initial board poses (in camera 1's frame) from the camera that fits each view best
    for (v, view) in views.enumerated() {
        var best: (Pose6, Double)?
        for (c, pts) in view.obs {
            guard let (p, e) = solvePnP(K0[c], board: board, pts: pts) else { continue }
            if best == nil || e < best!.1 {
                // board in camera c -> board in camera 1: Xw = Rc^T (R p + t - tc)
                var Rc = matrix_identity_double3x3, tc = V3(0, 0, 0)
                if c > 0 { Rc = poses0[c].R; tc = poses0[c].t }
                let R0 = Rc.transpose * p.R, t0 = Rc.transpose * (p.t - tc)
                best = (Pose6(r: rodriguesInv(R0), t: t0), e)
            }
        }
        guard let b = best?.0 else { return nil }
        let o = viewBase + 6 * v
        x[o] = b.r.x; x[o + 1] = b.r.y; x[o + 2] = b.r.z; x[o + 3] = b.t.x; x[o + 4] = b.t.y; x[o + 5] = b.t.z
    }

    // residuals of one observation; xl = [camera pose (if c > 0)] [board pose] [intrinsics (if refined)]
    func obsResiduals(_ c: Int, _ pts: [V2], _ xl: [Double]) -> [Double] {
        var o = 0
        var Rc = matrix_identity_double3x3, tc = V3(0, 0, 0)
        if c > 0 { Rc = rodrigues(V3(xl[0], xl[1], xl[2])); tc = V3(xl[3], xl[4], xl[5]); o = 6 }
        let Rb = rodrigues(V3(xl[o], xl[o + 1], xl[o + 2])), tb = V3(xl[o + 3], xl[o + 4], xl[o + 5])
        o += 6
        var K = K0[c]
        if refineIntrinsics {
            K = Intrinsics(fx: xl[o], fy: xl[o + 1], cx: xl[o + 2], cy: xl[o + 3], k: [xl[o + 4], xl[o + 5], xl[o + 6], xl[o + 7]],
                           width: K0[c].width, height: K0[c].height)
        }
        var out = [Double](); out.reserveCapacity(board.count * 2)
        for (i, X) in board.enumerated() {
            if let p = K.project(Rc * (Rb * X + tb) + tc) { out.append(p.x - pts[i].x); out.append(p.y - pts[i].y) }
            else { out.append(1000); out.append(1000) }
        }
        return out
    }
    /// Global indices of an observation's local parameters, in xl order.
    func localIndex(_ c: Int, _ v: Int) -> [Int] {
        var idx: [Int] = []
        if c > 0 { let o = camOff[c]!; idx += (0..<6).map { o + $0 } }
        let b = viewBase + 6 * v
        idx += (0..<6).map { b + $0 }
        if refineIntrinsics { let o = kOff[c]!; idx += (0..<8).map { o + $0 } }
        return idx
    }
    /// Is the local parameter at `pos` (in xl order) a camera pose or intrinsic (as opposed to the board pose)?
    func isCameraParam(_ c: Int, _ pos: Int) -> Bool { c > 0 ? (pos < 6 || pos >= 12) : pos >= 6 }

    func cost(_ x: [Double]) -> (Double, [Double]) {
        var total = 0.0, sums = [Double](repeating: 0, count: nCam), counts = [Double](repeating: 0, count: nCam)
        for (v, view) in views.enumerated() {
            for (c, pts) in view.obs {
                let r = obsResiduals(c, pts, localIndex(c, v).map { x[$0] })
                let s = r.reduce(0) { $0 + $1 * $1 }
                total += s; sums[c] += s; counts[c] += Double(r.count / 2)
            }
        }
        return (total, (0..<nCam).map { counts[$0] > 0 ? (sums[$0] / counts[$0]).squareRoot() : 0 })
    }
    func allResiduals(_ x: [Double]) -> [Double] {
        var out: [Double] = []
        for (v, view) in views.enumerated() { for (c, pts) in view.obs { out += obsResiduals(c, pts, localIndex(c, v).map { x[$0] }) } }
        return out
    }
    func regularisation(_ x: [Double]) -> Double {
        guard refineIntrinsics else { return 0 }
        var s = 0.0
        for c in camList { let o = kOff[c]!
            for i in 0..<4 { s += pow(0.5 * x[o + 4 + i], 2) }
            for i in 0..<4 { s += pow(0.02 * (x[o + i] - xInit[o + i]), 2) }
        }
        return s
    }

    /// Levenberg-Marquardt over the free parameters (stage 1: the board positions only; stage 2: everything).
    func optimise(_ x0: [Double], freeCameras: Bool, iterations: Int) -> ([Double], Int) {
        var x = x0
        var free = [Int](repeating: -1, count: n)
        var nf = 0
        for g in 0..<n where freeCameras || (g >= viewBase && g < viewBase + 6 * views.count) { free[g] = nf; nf += 1 }
        var cur = cost(x).0 + regularisation(x)
        var lambda = 1e-3
        var it = 0
        while it < iterations {
            it += 1
            var A = [Double](repeating: 0, count: nf * nf), g = [Double](repeating: 0, count: nf)
            for (v, view) in views.enumerated() {
                for (c, pts) in view.obs {
                    let idx = localIndex(c, v)
                    let xl = idx.map { x[$0] }
                    let r0 = obsResiduals(c, pts, xl)
                    let m = r0.count
                    let pos = (0..<idx.count).filter { free[idx[$0]] >= 0 && (freeCameras || !isCameraParam(c, $0)) }
                    let p = pos.count
                    if p == 0 { continue }
                    var J = [Double](repeating: 0, count: m * p)
                    for (col, ps) in pos.enumerated() {
                        let h = 1e-6 * max(1.0, abs(xl[ps]))
                        var xp = xl; xp[ps] += h
                        let rp = obsResiduals(c, pts, xp)
                        for i in 0..<m { J[i * p + col] = (rp[i] - r0[i]) / h }
                    }
                    var JtJ = [Double](repeating: 0, count: p * p), Jtr = [Double](repeating: 0, count: p)
                    cblas_dsyrk(CblasRowMajor, CblasUpper, CblasTrans, Int32(p), Int32(m), 1.0, J, Int32(p), 0.0, &JtJ, Int32(p))
                    cblas_dgemv(CblasRowMajor, CblasTrans, Int32(m), Int32(p), 1.0, J, Int32(p), r0, 1, 0.0, &Jtr, 1)
                    for a in 0..<p {
                        let ga = free[idx[pos[a]]]
                        g[ga] += Jtr[a]
                        for b in a..<p {
                            let gb = free[idx[pos[b]]]
                            let val = JtJ[a * p + b]
                            A[ga * nf + gb] += val
                            if a != b { A[gb * nf + ga] += val }
                        }
                    }
                }
            }
            if freeCameras && refineIntrinsics {
                for c in camList { let o = kOff[c]!
                    for i in 0..<4 { let k = free[o + 4 + i]; A[k * nf + k] += 0.25; g[k] += 0.25 * x[o + 4 + i] }
                    for i in 0..<4 { let k = free[o + i]; let w = 0.02 * 0.02; A[k * nf + k] += w; g[k] += w * (x[o + i] - xInit[o + i]) }
                }
            }
            var improved = false, tiny = false
            for _ in 0..<10 {
                var Ad = A
                for a in 0..<nf { Ad[a * nf + a] += lambda * max(A[a * nf + a], 1e-9) }
                guard let d = solveLinear(Ad, g.map { -$0 }, nf) else { lambda *= 10; continue }
                var xn = x
                for gi in 0..<n where free[gi] >= 0 { xn[gi] += d[free[gi]] }
                let cn = cost(xn).0 + regularisation(xn)
                if cn.isFinite && cn < cur {
                    let dn = d.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    x = xn; cur = cn; lambda = max(lambda / 3, 1e-9); improved = true
                    if dn < 1e-9 { tiny = true }
                    break
                } else { lambda *= 4 }
            }
            if !improved || tiny { break }
        }
        return (x, it)
    }

    let (xBoards, _) = optimise(x, freeCameras: false, iterations: 15)
    let rmsBefore = pxRms(allResiduals(xBoards))
    let (xf, its) = optimise(xBoards, freeCameras: true, iterations: iterations)

    let after = cost(xf).1
    let rmsAfter = pxRms(allResiduals(xf))
    guard rmsAfter.isFinite, xf.allSatisfy({ $0.isFinite }) else { return nil }

    var K = K0, poses = poses0
    for c in movers { let o = camOff[c]!; poses[c] = Pose6(r: V3(xf[o], xf[o + 1], xf[o + 2]), t: V3(xf[o + 3], xf[o + 4], xf[o + 5])) }
    if refineIntrinsics {
        for c in camList { let o = kOff[c]!
            K[c] = Intrinsics(fx: xf[o], fy: xf[o + 1], cx: xf[o + 2], cy: xf[o + 3], k: [xf[o + 4], xf[o + 5], xf[o + 6], xf[o + 7]],
                              width: K0[c].width, height: K0[c].height) }
    }
    return BAResult(K: K, poses: poses, rmsBefore: rmsBefore, rmsAfter: rmsAfter, perCamera: after, iterations: its, views: views.count)
}
