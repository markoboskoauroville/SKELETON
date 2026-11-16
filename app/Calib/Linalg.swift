// Linalg.swift: the small numerical toolbox of the calibration (pure Swift, no OpenCV): Rodrigues, solving, symmetric
// eigenproblem (Jacobi), homography by DLT, Levenberg-Marquardt with a numeric Jacobian.
import Foundation
import simd

typealias V2 = SIMD2<Double>
typealias V3 = SIMD3<Double>
typealias M3 = simd_double3x3

func skew(_ v: V3) -> M3 { M3(columns: (V3(0, v.z, -v.y), V3(-v.z, 0, v.x), V3(v.y, -v.x, 0))) }

func rodrigues(_ r: V3) -> M3 {
    let th = length(r)
    if th < 1e-12 { return matrix_identity_double3x3 + skew(r) }
    let k = skew(r / th)
    return matrix_identity_double3x3 + sin(th) * k + (1 - cos(th)) * (k * k)
}

func rodriguesInv(_ R: M3) -> V3 {
    var q = simd_quatd(R)
    if q.real < 0 { q = simd_quatd(real: -q.real, imag: -q.imag) }
    let s = length(q.imag)
    if s < 1e-12 { return V3(0, 0, 0) }
    return q.imag / s * (2 * atan2(s, q.real))
}

/// Gaussian elimination with partial pivoting on a flat row-major n x n matrix. Returns nil when singular.
func solveLinear(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
    var m = a, x = b
    for c in 0..<n {
        var p = c, best = abs(m[c * n + c])
        for r in (c + 1)..<max(c + 1, n) where abs(m[r * n + c]) > best { best = abs(m[r * n + c]); p = r }
        if best < 1e-14 { return nil }
        if p != c {
            for k in 0..<n { m.swapAt(c * n + k, p * n + k) }
            x.swapAt(c, p)
        }
        let d = m[c * n + c]
        for r in (c + 1)..<max(c + 1, n) {
            let f = m[r * n + c] / d
            if f == 0 { continue }
            for k in c..<n { m[r * n + k] -= f * m[c * n + k] }
            x[r] -= f * x[c]
        }
    }
    for r in stride(from: n - 1, through: 0, by: -1) {
        var s = x[r]
        for k in (r + 1)..<max(r + 1, n) { s -= m[r * n + k] * x[k] }
        x[r] = s / m[r * n + r]
    }
    return x
}

/// Jacobi eigen decomposition of a symmetric n x n (flat). Returns (values, vectors as columns, flat n x n).
func symmetricEigen(_ a: [Double], _ n: Int) -> ([Double], [Double]) {
    var A = a
    var V = [Double](repeating: 0, count: n * n)
    for i in 0..<n { V[i * n + i] = 1 }
    for _ in 0..<80 {
        var off = 0.0
        for i in 0..<n { for j in (i + 1)..<max(i + 1, n) { off += A[i * n + j] * A[i * n + j] } }
        if off < 1e-22 { break }
        for p in 0..<n {
            for q in (p + 1)..<max(p + 1, n) {
                let apq = A[p * n + q]
                if abs(apq) < 1e-300 { continue }
                let theta = (A[q * n + q] - A[p * n + p]) / (2 * apq)
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<n {
                    let akp = A[k * n + p], akq = A[k * n + q]
                    A[k * n + p] = c * akp - s * akq
                    A[k * n + q] = s * akp + c * akq
                }
                for k in 0..<n {
                    let apk = A[p * n + k], aqk = A[q * n + k]
                    A[p * n + k] = c * apk - s * aqk
                    A[q * n + k] = s * apk + c * aqk
                }
                for k in 0..<n {
                    let vkp = V[k * n + p], vkq = V[k * n + q]
                    V[k * n + p] = c * vkp - s * vkq
                    V[k * n + q] = s * vkp + c * vkq
                }
            }
        }
    }
    return ((0..<n).map { A[$0 * n + $0] }, V)
}

/// The unit vector minimising |M v| for the row list M (n columns): the eigenvector of MtM with the smallest eigenvalue.
func nullVector(rows: [[Double]], n: Int) -> [Double] {
    var mtm = [Double](repeating: 0, count: n * n)
    for r in rows { for i in 0..<n { for j in 0..<n { mtm[i * n + j] += r[i] * r[j] } } }
    let (vals, vecs) = symmetricEigen(mtm, n)
    var best = 0
    for i in 1..<n where vals[i] < vals[best] { best = i }
    return (0..<n).map { vecs[$0 * n + best] }
}

func rowsMatrix(_ r0: V3, _ r1: V3, _ r2: V3) -> M3 { M3(rows: [r0, r1, r2]) }

/// Homography (3x3) mapping src -> dst by normalised DLT.
func homography(src: [V2], dst: [V2]) -> M3? {
    guard src.count == dst.count, src.count >= 4 else { return nil }
    func norm(_ p: [V2]) -> (M3, [V2]) {
        var c = V2(0, 0); for q in p { c += q }; c /= Double(p.count)
        var d = 0.0; for q in p { d += length(q - c) }; d /= Double(p.count)
        let s = d > 1e-12 ? 2.0.squareRoot() / d : 1
        let T = rowsMatrix(V3(s, 0, -s * c.x), V3(0, s, -s * c.y), V3(0, 0, 1))
        return (T, p.map { ($0 - c) * s })
    }
    let (T1, s) = norm(src), (T2, d) = norm(dst)
    var rows: [[Double]] = []
    for i in 0..<s.count {
        let X = s[i].x, Y = s[i].y, x = d[i].x, y = d[i].y
        rows.append([X, Y, 1, 0, 0, 0, -x * X, -x * Y, -x])
        rows.append([0, 0, 0, X, Y, 1, -y * X, -y * Y, -y])
    }
    let h = nullVector(rows: rows, n: 9)
    let Hn = rowsMatrix(V3(h[0], h[1], h[2]), V3(h[3], h[4], h[5]), V3(h[6], h[7], h[8]))
    let H = T2.inverse * Hn * T1
    return H
}

/// Closest rotation matrix to M (polar decomposition).
func orthonormalise(_ M: M3) -> M3 {
    let S = M.transpose * M
    var flat = [Double](repeating: 0, count: 9)
    for i in 0..<3 { for j in 0..<3 { flat[i * 3 + j] = S[j][i] } }
    let (vals, vecs) = symmetricEigen(flat, 3)
    var inv = [Double](repeating: 0, count: 9)
    for k in 0..<3 {
        let f = 1 / max(vals[k], 1e-12).squareRoot()
        for i in 0..<3 { for j in 0..<3 { inv[i * 3 + j] += f * vecs[i * 3 + k] * vecs[j * 3 + k] } }
    }
    let I = rowsMatrix(V3(inv[0], inv[1], inv[2]), V3(inv[3], inv[4], inv[5]), V3(inv[6], inv[7], inv[8]))
    var R = M * I
    if R.determinant < 0 { R = -R }
    return R
}

/// Levenberg-Marquardt with a forward-difference Jacobian. Returns the refined parameters.
func levenbergMarquardt(_ x0: [Double], iterations: Int = 40, residuals f: ([Double]) -> [Double]) -> [Double] {
    var x = x0
    let n = x.count
    var r = f(x)
    var cost = r.reduce(0) { $0 + $1 * $1 }
    var lambda = 1e-3
    let m = r.count
    for _ in 0..<iterations {
        var J = [Double](repeating: 0, count: m * n)
        for j in 0..<n {
            let h = 1e-6 * max(1.0, abs(x[j]))
            var xp = x; xp[j] += h
            let rp = f(xp)
            for i in 0..<m { J[i * n + j] = (rp[i] - r[i]) / h }
        }
        var A = [Double](repeating: 0, count: n * n), g = [Double](repeating: 0, count: n)
        for i in 0..<m {
            let row = i * n
            let ri = r[i]
            for a in 0..<n {
                let ja = J[row + a]
                if ja == 0 { continue }
                g[a] += ja * ri
                for b in a..<n { A[a * n + b] += ja * J[row + b] }
            }
        }
        for a in 0..<n { for b in 0..<a { A[a * n + b] = A[b * n + a] } }
        var improved = false
        for _ in 0..<10 {
            var Ad = A
            for a in 0..<n { Ad[a * n + a] += lambda * max(A[a * n + a], 1e-9) }
            guard let d = solveLinear(Ad, g.map { -$0 }, n) else { lambda *= 10; continue }
            var xn = x
            for a in 0..<n { xn[a] += d[a] }
            let rn = f(xn)
            let cn = rn.reduce(0) { $0 + $1 * $1 }
            if cn.isFinite && cn < cost {
                let dn = d.reduce(0) { $0 + $1 * $1 }.squareRoot()
                x = xn; r = rn; cost = cn; lambda = max(lambda / 3, 1e-9); improved = true
                if dn < 1e-9 { return x }
                break
            } else { lambda *= 4 }
        }
        if !improved { break }
    }
    return x
}
