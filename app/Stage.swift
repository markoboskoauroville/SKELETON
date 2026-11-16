// Stage.swift: the picture (aspect-fit, never cropped), the user's skeleton coloured per limb, the white ghost of the
// target pose, the ring with the score, the band with the pose name and cues.
import AppKit

final class StageView: NSView {
    override var isFlipped: Bool { true }

    var image: CGImage?
    var imgSize = CGSize.zero
    var people: [Pose] = []
    var primary: Int?
    var target: NamedPose? { didSet { greenSince = nil; matched = false; fired = false } }
    var ghost: Pose?
    var comparison: Comparison?
    var level = Level.beginner
    var mirror = false
    var showAngles = false
    var skeletonOnly = false
    var cameraName = ""
    var fps = 0
    var band: (title: String, text: String)?
    var onAchieved: (() -> Void)?
    var onDropURL: ((URL) -> Void)?

    private var toastText: String?
    private var toastUntil = Date.distantPast
    private var greenSince: Date?
    private var matched = false
    private var fired = false
    private var frames = 0
    private var fpsStart = Date()

    static let green = NSColor(srgbRed: 0.2, green: 0.82, blue: 0.48, alpha: 1)
    static let yellow = NSColor(srgbRed: 0.96, green: 0.85, blue: 0.04, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let plain = NSColor(srgbRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)
    static func color(_ z: Zone) -> NSColor { [green, yellow, red][z.rawValue] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("Camera picture with skeleton")
    }
    required init?(coder: NSCoder) { fatalError() }

    func toast(_ s: String) { toastText = s; toastUntil = Date().addingTimeInterval(4); needsDisplay = true }

    var heldFraction: Double {
        guard let g = greenSince else { return 0 }
        return min(1, Date().timeIntervalSince(g) / level.hold)
    }

    func resetHold() { greenSince = nil; matched = false; fired = false }

    func update(image: CGImage, size: CGSize, poses: [Pose]) {
        self.image = image; imgSize = size; people = poses
        primary = poses.indices.max { (poses[$0].torso ?? 0) < (poses[$1].torso ?? 0) }
        let aspect = size.width / max(1, size.height)
        if let t = target?.pose {
            let user = primary.map { poses[$0] }
            ghost = place(t, onto: user, aspect: aspect)
            if let u = user { comparison = compare(user: u, target: t, level: level) } else { comparison = nil }
        } else { ghost = nil; comparison = nil }
        if let c = comparison, c.worst <= level.green {
            if greenSince == nil { greenSince = Date() }
            if Date().timeIntervalSince(greenSince!) >= level.hold {
                matched = true
                if !fired { fired = true; onAchieved?() }
            }
        } else { greenSince = nil; matched = false }
        frames += 1
        let el = Date().timeIntervalSince(fpsStart)
        if el >= 1 { fps = Int((Double(frames) / el).rounded()); frames = 0; fpsStart = Date() }
        needsDisplay = true
    }

    // MARK: geometry

    var bandHeight: CGFloat { band == nil ? 0 : 78 }
    var pictureArea: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: max(10, bounds.height - bandHeight)) }

    func fit(_ size: CGSize, in r: CGRect) -> CGRect {
        let s = min(r.width / size.width, r.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    func toView(_ p: CGPoint, _ aspect: CGFloat, _ rect: CGRect) -> CGPoint {
        var nx = p.x / aspect
        if mirror { nx = 1 - nx }
        return CGPoint(x: rect.minX + nx * rect.width, y: rect.minY + p.y * rect.height)
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill(); bounds.fill()
        let area = pictureArea
        guard imgSize.width > 0, let img = image else {
            text("WAITING FOR THE CAMERA", at: CGPoint(x: area.midX, y: area.midY), size: 14, color: .white.withAlphaComponent(0.6), center: true)
            drawBand(); return
        }
        let rect = fit(imgSize, in: area)
        let aspect = imgSize.width / imgSize.height
        if !skeletonOnly {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            if mirror { ctx.translateBy(x: rect.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }
        if let g = ghost { drawGhost(g, aspect, rect, ctx) }
        for (i, p) in people.enumerated() { drawPerson(p, aspect, rect, ctx, isPrimary: i == primary) }
        drawInfo(area, rect)
        drawRing(area)
        drawBand()
        if let t = toastText, Date() < toastUntil {
            text(t, at: CGPoint(x: area.midX, y: area.minY + 150), size: 14, color: .white, center: true, back: true)
        }
        if people.isEmpty {
            text("NO PERSON SEEN", at: CGPoint(x: area.midX, y: area.maxY - 60), size: 12, color: .white.withAlphaComponent(0.7), center: true, back: true)
        }
        if target == nil {
            text("LOAD A POSE PHOTO (OR DROP ONE HERE), OR FREEZE YOUR POSE, OR START A SESSION", at: CGPoint(x: area.midX, y: area.maxY - 28),
                 size: 12, color: .white.withAlphaComponent(0.7), center: true, back: true)
        }
    }

    private func drawGhost(_ g: Pose, _ aspect: CGFloat, _ rect: CGRect, _ ctx: CGContext) {
        let c = NSColor.white.withAlphaComponent(0.5)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(9)
        for b in BONES {
            guard let a = g.j[b.a], let d = g.j[b.b] else { continue }
            let pa = toView(a, aspect, rect), pd = toView(d, aspect, rect)
            ctx.move(to: pa); ctx.addLine(to: pd)
        }
        ctx.strokePath()
        ctx.setFillColor(c.cgColor)
        for (_, p) in g.j {
            let v = toView(p, aspect, rect)
            ctx.fillEllipse(in: CGRect(x: v.x - 7, y: v.y - 7, width: 14, height: 14))
        }
    }

    private func drawPerson(_ p: Pose, _ aspect: CGFloat, _ rect: CGRect, _ ctx: CGContext, isPrimary: Bool) {
        var limbZone: [Limb: Zone] = [:]
        if isPrimary, let c = comparison { for (l, d) in c.diffs { limbZone[l] = zoneOf(d, level) } }
        func col(_ z: Zone?) -> NSColor { z.map { StageView.color($0) } ?? StageView.plain }
        ctx.setLineCap(.round); ctx.setLineWidth(4)
        var jointZone: [Jt: Zone] = [:]
        for b in BONES {
            guard let a = p.j[b.a], let d = p.j[b.b] else { continue }
            let z = b.limb.flatMap { limbZone[$0] }
            if let z = z {
                for k in [b.a, b.b] { if let o = jointZone[k] { if z.rawValue > o.rawValue { jointZone[k] = z } } else { jointZone[k] = z } }
            }
            ctx.setStrokeColor(col(z).cgColor)
            ctx.move(to: toView(a, aspect, rect)); ctx.addLine(to: toView(d, aspect, rect)); ctx.strokePath()
        }
        for (k, pt) in p.j {
            let v = toView(pt, aspect, rect)
            ctx.setFillColor(col(jointZone[k]).cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10))
        }
        if showAngles {
            let triples: [(Jt, Jt, Jt)] = [(.leftShoulder, .leftElbow, .leftWrist), (.rightShoulder, .rightElbow, .rightWrist),
                                           (.leftHip, .leftKnee, .leftAnkle), (.rightHip, .rightKnee, .rightAnkle),
                                           (.leftShoulder, .leftHip, .leftKnee), (.rightShoulder, .rightHip, .rightKnee)]
            for (a, b, c) in triples {
                guard let pa = p.j[a], let pb = p.j[b], let pc = p.j[c] else { continue }
                let v = toView(pb, aspect, rect)
                text("\(jointAngle(pa, pb, pc))°", at: CGPoint(x: v.x + 10, y: v.y - 18), size: 12, color: .white, center: false, back: true)
            }
        }
    }

    private func drawInfo(_ area: CGRect, _ rect: CGRect) {
        let info = "\(cameraName.isEmpty ? "NO CAMERA" : cameraName)  ·  \(fps) fps"
        text(info, at: CGPoint(x: 14, y: area.maxY - 22), size: 11, color: .white.withAlphaComponent(0.7), center: false)
        if let t = target, let th = t.thumb {
            let w: CGFloat = 110, h = w * CGFloat(th.height) / CGFloat(th.width)
            let r = CGRect(x: 14, y: area.maxY - 34 - h, width: w, height: h)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(th, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
            NSColor.white.withAlphaComponent(0.7).setStroke()
            let b = NSBezierPath(rect: r); b.lineWidth = 1; b.stroke()
            text(t.name.uppercased(), at: CGPoint(x: r.minX, y: r.minY - 16), size: 10, color: .white.withAlphaComponent(0.8), center: false)
        } else if let t = target {
            text("TARGET: " + t.name.uppercased(), at: CGPoint(x: 14, y: area.maxY - 40), size: 10, color: .white.withAlphaComponent(0.8), center: false)
        }
    }

    private func drawRing(_ area: CGRect) {
        guard target != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: area.maxX - 78, y: area.maxY - 96)
        var col = NSColor.gray, label = "NO PERSON", scoreText = "--"
        if let cmp = comparison {
            let z = zoneOf(cmp.worst, level)
            col = StageView.color(z)
            scoreText = "\(cmp.score)"
            label = z == .green ? (matched ? "MATCHED" : "ALIGNED") : (z == .yellow ? "CLOSE" : "FAR")
        }
        ctx.setLineWidth(9); ctx.setStrokeColor(col.cgColor)
        ctx.strokeEllipse(in: CGRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92))
        if heldFraction > 0 {
            ctx.setLineWidth(3); ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addArc(center: c, radius: 36, startAngle: -.pi / 2, endAngle: -.pi / 2 + CGFloat(heldFraction) * 2 * .pi, clockwise: false)
            ctx.strokePath()
        }
        text(scoreText, at: CGPoint(x: c.x, y: c.y - 16), size: 28, color: .white, center: true)
        text(label, at: CGPoint(x: c.x, y: c.y + 56), size: 13, color: col, center: true, back: true)
    }

    private func drawBand() {
        guard let b = band else { return }
        let r = CGRect(x: 0, y: bounds.height - bandHeight, width: bounds.width, height: bandHeight)
        NSColor(white: 0.07, alpha: 1).setFill(); r.fill()
        text(b.title, at: CGPoint(x: 16, y: r.minY + 8), size: 14, color: StageView.green, center: false)
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white, .paragraphStyle: ps]
        (b.text as NSString).draw(in: CGRect(x: 16, y: r.minY + 30, width: r.width - 32, height: r.height - 34), withAttributes: attrs)
    }

    func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, center: Bool, back: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: a)
        let sz = str.size()
        let o = CGPoint(x: center ? p.x - sz.width / 2 : p.x, y: p.y)
        if back {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: CGRect(x: o.x - 6, y: o.y - 2, width: sz.width + 12, height: sz.height + 4), xRadius: 4, yRadius: 4).fill()
        }
        str.draw(at: o)
    }

    // MARK: drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: ["public.image"]]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], let u = urls.first else { return false }
        onDropURL?(u)
        return true
    }
}
