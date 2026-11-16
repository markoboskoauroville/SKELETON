// Board.swift: the printable circle-grid board (A4 / A3 PDF) and its detector. A grid of 8 x 6 black circles on white, the
// circle at the origin corner larger so the board has one orientation. Circles are found as dark blobs (works on the
// strongly distorted Sony picture: no corner detector needed), then ordered by growing the lattice from the marker.
import Foundation
import CoreGraphics
import simd

enum BoardSpec {
    static let cols = 8, rows = 6
    /// A4: 25 mm spacing, A3: 40 mm spacing.
    static func spacingMm(a3: Bool) -> Double { a3 ? 40 : 25 }
    static func points(a3: Bool) -> [V3] { boardPoints(cols: cols, rows: rows, spacing: spacingMm(a3: a3) / 1000) }

    /// Writes the PDF (landscape) and returns whether it succeeded. Print at 100 %, no "fit to page".
    static func writePDF(to url: URL, a3: Bool) -> Bool {
        let mm = 72.0 / 25.4
        let pw = (a3 ? 420.0 : 297.0) * mm, ph = (a3 ? 297.0 : 210.0) * mm
        var box = CGRect(x: 0, y: 0, width: pw, height: ph)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
        let s = spacingMm(a3: a3) * mm
        let w = Double(cols - 1) * s, h = Double(rows - 1) * s
        let ox = (pw - w) / 2, oy = (ph - h) / 2 + 6 * mm
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in 0..<rows {
            for x in 0..<cols {
                let d = (x == 0 && y == 0) ? 0.85 * s : 0.5 * s
                let cx = ox + Double(x) * s, cy = oy + Double(rows - 1 - y) * s      // y down on the page, PDF y is up
                ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            }
        }
        // a 50 mm ruler, to check the print is not scaled
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(1)
        let rx = ox, ry = 12 * mm
        ctx.move(to: CGPoint(x: rx, y: ry)); ctx.addLine(to: CGPoint(x: rx + 50 * mm, y: ry)); ctx.strokePath()
        ctx.move(to: CGPoint(x: rx, y: ry - 3)); ctx.addLine(to: CGPoint(x: rx, y: ry + 3)); ctx.strokePath()
        ctx.move(to: CGPoint(x: rx + 50 * mm, y: ry - 3)); ctx.addLine(to: CGPoint(x: rx + 50 * mm, y: ry + 3)); ctx.strokePath()
        ctx.endPDFPage(); ctx.closePDF()
        return true
    }
}

struct Blob { var c: V2; var area: Double }

/// Dark round blobs in a gray 8-bit image.
func findBlobs(gray g: [UInt8], width w: Int, height h: Int) -> [Blob] {
    // integral image for the local mean
    var integ = [Int32](repeating: 0, count: (w + 1) * (h + 1))
    for y in 0..<h {
        var row: Int32 = 0
        for x in 0..<w {
            row += Int32(g[y * w + x])
            integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row
        }
    }
    let hw = max(8, w / 40)
    var mask = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let y0 = max(0, y - hw), y1 = min(h, y + hw + 1)
        for x in 0..<w {
            let x0 = max(0, x - hw), x1 = min(w, x + hw + 1)
            let sum = integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0]
            let mean = Double(sum) / Double((x1 - x0) * (y1 - y0))
            let v = Double(g[y * w + x])
            if v < mean * 0.72 && v < 150 { mask[y * w + x] = 1 }
        }
    }
    var label = [Bool](repeating: false, count: w * h)
    var blobs: [Blob] = []
    var stack: [Int] = []
    for start in 0..<(w * h) where mask[start] == 1 && !label[start] {
        stack.removeAll(keepingCapacity: true)
        stack.append(start); label[start] = true
        var area = 0, minx = w, maxx = 0, miny = h, maxy = 0
        var sx = 0.0, sy = 0.0, sw = 0.0
        var px: [Int] = []
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            area += 1
            if x < minx { minx = x }; if x > maxx { maxx = x }; if y < miny { miny = y }; if y > maxy { maxy = y }
            if area <= 30000 { px.append(p) }
            if x > 0, mask[p - 1] == 1, !label[p - 1] { label[p - 1] = true; stack.append(p - 1) }
            if x < w - 1, mask[p + 1] == 1, !label[p + 1] { label[p + 1] = true; stack.append(p + 1) }
            if y > 0, mask[p - w] == 1, !label[p - w] { label[p - w] = true; stack.append(p - w) }
            if y < h - 1, mask[p + w] == 1, !label[p + w] { label[p + w] = true; stack.append(p + w) }
        }
        let bw = maxx - minx + 1, bh = maxy - miny + 1
        guard area >= 25, area <= 25000, bw >= 5, bh >= 5 else { continue }
        let asp = Double(bw) / Double(bh)
        let fill = Double(area) / Double(bw * bh)
        guard asp > 0.4, asp < 2.5, fill > 0.5, fill < 0.95 else { continue }
        for p in px {
            let wgt = 255 - Double(g[p])
            sx += Double(p % w) * wgt; sy += Double(p / w) * wgt; sw += wgt
        }
        guard sw > 0 else { continue }
        blobs.append(Blob(c: V2(sx / sw + 0.5, sy / sw + 0.5), area: Double(area)))
    }
    return blobs
}

/// The ordered image points (row-major, index = y * cols + x) of the board, or nil.
func orderGrid(_ blobs: [Blob], cols: Int, rows: Int) -> [V2]? {
    guard blobs.count >= cols * rows else { return nil }
    let areas = blobs.map { $0.area }.sorted()
    let median = areas[areas.count / 2]
    guard let mi = blobs.indices.max(by: { blobs[$0].area < blobs[$1].area }), blobs[mi].area > 1.7 * median else { return nil }
    let second = blobs.indices.filter { $0 != mi }.map { blobs[$0].area }.max() ?? 0
    guard blobs[mi].area > 1.5 * second else { return nil }
    let m = blobs[mi].c
    let others = blobs.indices.filter { $0 != mi }.sorted { length(blobs[$0].c - m) < length(blobs[$1].c - m) }
    guard others.count >= 2 else { return nil }
    let i1 = others[0], a = blobs[i1].c - m
    var i2: Int?
    for o in others.dropFirst() {
        let b = blobs[o].c - m
        let cr = abs(a.x * b.y - a.y * b.x) / (length(a) * length(b))
        if cr > 0.5 && length(b) < 2.2 * length(a) { i2 = o; break }
    }
    guard let j2 = i2 else { return nil }
    let maxDim = max(cols, rows)
    var grid: [Int: Int] = [0: mi]                       // key = i * 100 + j
    grid[1 * 100 + 0] = i1; grid[0 * 100 + 1] = j2
    var used: Set<Int> = [mi, i1, j2]
    func at(_ i: Int, _ j: Int) -> V2? { grid[i * 100 + j].map { blobs[$0].c } }
    var changed = true
    while changed {
        changed = false
        for s in 2..<(2 * maxDim) {
            for i in 0..<maxDim {
                let j = s - i
                guard j >= 0, j < maxDim, grid[i * 100 + j] == nil else { continue }
                var pred: V2?, step = 0.0
                if let p1 = at(i - 1, j), let p2 = at(i - 2, j) { pred = 2 * p1 - p2; step = length(p1 - p2) }
                else if let p1 = at(i, j - 1), let p2 = at(i, j - 2) { pred = 2 * p1 - p2; step = length(p1 - p2) }
                else if let p1 = at(i - 1, j), let p2 = at(i, j - 1), let p3 = at(i - 1, j - 1) { pred = p1 + p2 - p3; step = length(p1 - p3) }
                guard let pr = pred else { continue }
                var bi = -1, bd = 0.4 * step
                for k in blobs.indices where !used.contains(k) {
                    let d = length(blobs[k].c - pr)
                    if d < bd { bd = d; bi = k }
                }
                if bi >= 0 { grid[i * 100 + j] = bi; used.insert(bi); changed = true }
            }
        }
    }
    var na = 0, nb = 0
    for key in grid.keys { na = max(na, key / 100 + 1); nb = max(nb, key % 100 + 1) }
    guard grid.count == cols * rows else { return nil }
    let swap: Bool
    if na == cols && nb == rows { swap = false } else if na == rows && nb == cols { swap = true } else { return nil }
    let xdir = swap ? (blobs[j2].c - m) : a, ydir = swap ? a : (blobs[j2].c - m)
    guard xdir.x * ydir.y - xdir.y * ydir.x > 0 else { return nil }          // a board seen from behind is refused
    var out = [V2](repeating: V2(0, 0), count: cols * rows)
    for (key, bi) in grid {
        let i = key / 100, j = key % 100
        let x = swap ? j : i, y = swap ? i : j
        out[y * cols + x] = blobs[bi].c
    }
    return out
}

func detectBoard(gray: [UInt8], width: Int, height: Int) -> [V2]? {
    orderGrid(findBlobs(gray: gray, width: width, height: height), cols: BoardSpec.cols, rows: BoardSpec.rows)
}

/// 8-bit gray pixels of a CGImage.
func grayPixels(_ img: CGImage) -> ([UInt8], Int, Int)? {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h)
    let ok = buf.withUnsafeMutableBytes { p -> Bool in
        guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (buf, w, h) : nil
}
