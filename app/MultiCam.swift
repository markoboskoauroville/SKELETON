// MultiCam.swift: two or three cameras at once: calibration wizard, sync, triangulation, tracking quality.
import AppKit
import AVFoundation

extension MainView {
    // MARK: frames

    func primaryPose(_ poses: [Pose]) -> Pose? { poses.max { ($0.torso ?? 0) < ($1.torso ?? 0) } }

    func frame(_ s: Slot, _ f: Frame) {
        guard let idx = slots.firstIndex(where: { $0 === s }) else { return }
        s.size = f.size
        if let k = s.intr, k.width != Int(f.size.width) || k.height != Int(f.size.height) {
            s.intr = nil; s.extr = nil
            if !s.sizeWarned { s.sizeWarned = true; s.stage.toast("THE CALIBRATION IS FOR ANOTHER PICTURE SIZE: CALIBRATE AGAIN") }
        }
        let prim = primaryPose(f.poses)
        var motion = 0.0
        if let p = prim, let last = s.hist.last, let lp = last.pose, f.t > last.t {
            motion = Double(hypot(p.centre.x - lp.centre.x, p.centre.y - lp.centre.y)) / (f.t - last.t)
        }
        s.hist.append((f.t, prim, f.size))
        if s.hist.count > 40 { s.hist.removeFirst() }
        if calStep == .measure { s.sig.append((f.t, f.lum, motion)) }

        var frontal: Pose?
        if idx == 0 {
            lastTri = slots.count > 1 ? triangulateFrame(f) : nil
            if let t = lastTri {
                frontal = frontalPose(t.joints, aspect: f.size.width / f.size.height)
                s.stage.quality = t.quality
            } else { s.stage.quality = nil }
            let others = slots.dropFirst().map { String(format: "%+.0f", $0.offset * 1000) }
            s.stage.extraInfo = slots.count > 1 ? "SYNC " + others.joined(separator: "/") + " MS" : nil
        }
        s.stage.update(image: f.image, size: f.size, poses: f.poses, frontal: frontal)
        if idx == 0, let r = recorder { r.add(time: f.t, raw: f.raw, size: f.size, v3: f.v3, tri: lastTri) }

        switch calStep {
        case .intrinsics(let i): if idx == i { detect(s, f) }
        case .pair(let i): if idx == 0 || idx == i { detect(s, f) }
        case .measure: if idx == 0 && measureStart == 0 { measureStart = f.t }
            if f.t - measureStart > 5, measureStart > 0 { finishMeasure() }
        case .idle: break
        }
        if let c = wizardClear, Date() > c { wizardClear = nil; setWizard(nil) }
    }

    // MARK: triangulation

    var calibrated: Bool {
        guard slots.count > 1 else { return false }
        for (i, s) in slots.enumerated() { if s.intr == nil { return false }; if i > 0 && s.extr == nil { return false } }
        return true
    }

    func triangulateFrame(_ f: Frame) -> TriResult? {
        guard calibrated, let KA = slots[0].intr, let pa = primaryPose(f.poses) else { return nil }
        struct Partner { var K: Intrinsics; var e: Extrinsics; var pose: Pose; var H: Double }
        var partners: [Partner] = []
        for s in slots.dropFirst() {
            guard let K = s.intr, let e = s.extr?.E else { continue }
            let want = f.t + s.offset
            guard let h = s.hist.min(by: { abs($0.t - want) < abs($1.t - want) }), abs(h.t - want) < 0.05, let pb = h.pose else { continue }
            partners.append(Partner(K: K, e: e, pose: pb, H: Double(h.size.height)))
        }
        guard !partners.isEmpty else { return nil }
        let HA = Double(f.size.height)
        var joints: [Jt: V3] = [:]
        var errs: [Double] = []
        for jt in Jt.allCases {
            var rays: [Ray] = []
            var obs: [(Intrinsics, M3, V3, V2)] = []
            if let p = pa.j[jt] {
                let px = V2(Double(p.x) * HA, Double(p.y) * HA)
                rays.append(Ray(xy: KA.unproject(px), R: matrix_identity_double3x3, t: V3(0, 0, 0), w: Double(pa.conf[jt] ?? 0.5)))
                obs.append((KA, matrix_identity_double3x3, V3(0, 0, 0), px))
            }
            for pt in partners {
                if let p = pt.pose.j[jt] {
                    let px = V2(Double(p.x) * pt.H, Double(p.y) * pt.H)
                    rays.append(Ray(xy: pt.K.unproject(px), R: pt.e.R, t: pt.e.T, w: Double(pt.pose.conf[jt] ?? 0.5)))
                    obs.append((pt.K, pt.e.R, pt.e.T, px))
                }
            }
            guard rays.count >= 2, let X = triangulate(rays) else { continue }
            var e = 0.0
            for (K, R, t, px) in obs { if let q = K.project(R * X + t) { e += length(q - px) } else { e += 100 } }
            e /= Double(obs.count)
            if e < 12 { joints[jt] = X; errs.append(e) }
        }
        guard joints.count >= 6 else { return nil }
        let mean = errs.reduce(0, +) / Double(errs.count)
        let cover = Double(joints.count) / Double(Jt.allCases.count)
        let q = Int((50 * cover + 50 * (1 - min(1, mean / 8))).rounded())
        return TriResult(joints: joints, quality: max(0, min(100, q)), meanErrPx: mean, views: partners.count + 1)
    }

    // MARK: cameras count

    @objc func camCountChanged() {
        let n = camSeg.selectedSegment + 1
        defaults.set(n, forKey: "camcount")
        setCameraCount(n)
    }

    func setCameraCount(_ n: Int) {
        while slots.count > n {
            let s = slots.removeLast()
            s.pipe.detach()
            s.stage.removeFromSuperview()
        }
        while slots.count < n {
            let s = Slot()
            s.stage.isSecondary = true
            wire(s)
            addSubview(s.stage, positioned: .below, relativeTo: controls)
            slots.append(s)
        }
        camBPopup.isHidden = n < 2
        camCPopup.isHidden = n < 3
        multiRow.isHidden = n < 2
        calStep = .idle
        setWizard(nil)
        needsLayout = true
        if !devices.isEmpty { reloadDevices() }
        setTitle(calibrateButton, calibrated ? "RECALIBRATE" : "CALIBRATE")
    }

    func loadCalibration(_ s: Slot) {
        if let i = CalibStore.loadIntrinsics(s.uid) { s.intr = i.K; s.intrInfo = i } else { s.intr = nil; s.intrInfo = nil }
        if let a = slots.first, s !== a {
            if let e = CalibStore.loadExtrinsics(a: a.uid, b: s.uid) { s.extr = e } else { s.extr = nil }
            s.offset = defaults.double(forKey: "offset." + CalibStore.safe(a.uid) + "." + CalibStore.safe(s.uid))
        } else if s === slots.first {
            for o in slots.dropFirst() {
                o.extr = CalibStore.loadExtrinsics(a: s.uid, b: o.uid)
                o.offset = defaults.double(forKey: "offset." + CalibStore.safe(s.uid) + "." + CalibStore.safe(o.uid))
            }
        }
        setTitle(calibrateButton, calibrated ? "RECALIBRATE" : "CALIBRATE")
    }

    // MARK: the board

    @objc func boardA4() { saveBoard(a3: false) }
    @objc func boardA3() { saveBoard(a3: true) }

    func saveBoard(a3 big: Bool) {
        a3 = big; defaults.set(big, forKey: "boardA3")
        let p = NSSavePanel()
        p.nameFieldStringValue = "Skeleton calibration board \(big ? "A3" : "A4").pdf"
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        if BoardSpec.writePDF(to: u, a3: big) {
            NSWorkspace.shared.open(u)
            stage.toast("PRINT AT 100 %: THE RULER ON THE SHEET MUST MEASURE 50 MM")
        } else { stage.toast("COULD NOT WRITE THE BOARD") }
    }

    // MARK: wizard

    func setWizard(_ t: String?) { for s in slots { s.stage.wizard = t; if t == nil { s.stage.calibPoints = nil } } }

    @objc func calibratePressed() {
        guard slots.count > 1 else { stage.toast("CHOOSE 2 OR 3 CAMERAS FIRST"); return }
        guard slots.allSatisfy({ $0.device != nil }) else { return }
        if calibrated {
            for s in slots { s.intr = nil; s.extr = nil }
        }
        advanceCalibration()
    }

    func advanceCalibration() {
        for (i, s) in slots.enumerated() where s.intr == nil { startIntrinsics(i); return }
        for i in 1..<slots.count where slots[i].extr == nil { startPair(i); return }
        calStep = .idle
        let e = slots.dropFirst().compactMap { $0.extr?.E.rms }.map { String(format: "%.2f", $0) }.joined(separator: " / ")
        setWizard("CALIBRATION READY: REPROJECTION " + e + " PX")
        wizardClear = Date().addingTimeInterval(8)
        setTitle(calibrateButton, "RECALIBRATE")
    }

    func startIntrinsics(_ i: Int) {
        calStep = .intrinsics(i); calViews = []; lastCap = nil
        for s in slots { s.lastBoard = nil; s.prevBoard = nil; s.stable = 0 }
        setWizard("CAMERA \(i + 1) (\(slots[i].stage.cameraName)): HOLD THE BOARD IN VIEW, MOVE IT AROUND AND TILT IT: 0 OF 18")
    }

    func startPair(_ i: Int) {
        calStep = .pair(i); calPairs = []; lastCap = nil
        for s in slots { s.lastBoard = nil; s.prevBoard = nil; s.stable = 0 }
        setWizard("CAMERAS 1 AND \(i + 1): HOLD THE BOARD SO BOTH SEE IT, KEEP IT STILL, MOVE IT: 0 OF 12  (BOARD \(a3 ? "A3" : "A4"))")
    }

    func detect(_ s: Slot, _ f: Frame) {
        guard !s.detectBusy, f.t - s.lastDetect > 0.2 else { return }
        s.detectBusy = true; s.lastDetect = f.t
        let img = f.image, t = f.t
        DispatchQueue.global(qos: .userInitiated).async {
            let pts = grayPixels(img).flatMap { detectBoard(gray: $0.0, width: $0.1, height: $0.2) }
            DispatchQueue.main.async {
                s.detectBusy = false
                self.boardResult(s, t: t, pts: pts)
            }
        }
    }

    func meanShift(_ a: [V2], _ b: [V2]) -> Double {
        var d = 0.0
        for i in 0..<min(a.count, b.count) { d += length(a[i] - b[i]) }
        return d / Double(max(1, min(a.count, b.count)))
    }

    func boardResult(_ s: Slot, t: Double, pts: [V2]?) {
        s.stage.calibPoints = pts
        if let p = pts {
            if let prev = s.prevBoard { s.stable = meanShift(prev, p) < 3 ? s.stable + 1 : 0 } else { s.stable = 0 }
            s.prevBoard = p; s.lastBoard = (t, p)
        } else { s.prevBoard = nil; s.stable = 0; s.lastBoard = nil }
        calibTick()
    }

    /// Different enough from the last capture: moved, or a different size.
    func diverse(_ a: [V2], _ b: [V2], width: Double) -> Bool {
        func stats(_ p: [V2]) -> (V2, Double) {
            var c = V2(0, 0); for q in p { c += q }; c /= Double(p.count)
            var d = 0.0; for q in p { d += length(q - c) }
            return (c, d / Double(p.count))
        }
        let (ca, da) = stats(a), (cb, db) = stats(b)
        let ratio = db / max(da, 1e-6)
        return length(ca - cb) > 0.07 * width || ratio < 0.85 || ratio > 1.18 || meanShift(a, b) > 0.09 * width
    }

    func calibTick() {
        switch calStep {
        case .intrinsics(let i):
            let s = slots[i]
            guard let b = s.lastBoard, s.stable >= 2 else { return }
            if let last = lastCap, !diverse(last, b.pts, width: Double(s.size.width)) { return }
            calViews.append(b.pts); lastCap = b.pts
            setWizard("CAMERA \(i + 1) (\(s.stage.cameraName)): MOVE AND TILT THE BOARD: \(calViews.count) OF 18")
            if calViews.count >= 18 { solveIntrinsics(i) }
        case .pair(let i):
            let a = slots[0], s = slots[i]
            guard let ba = a.lastBoard, let bs = s.lastBoard, a.stable >= 2, s.stable >= 2, abs(ba.t - bs.t) < 0.3 else { return }
            if let last = lastCap, !diverse(last, ba.pts, width: Double(a.size.width)) { return }
            calPairs.append((ba.pts, bs.pts)); lastCap = ba.pts
            setWizard("CAMERAS 1 AND \(i + 1): MOVE THE BOARD, KEEP IT STILL FOR A MOMENT: \(calPairs.count) OF 12")
            if calPairs.count >= 12 { solvePair(i) }
        default: break
        }
    }

    func solveIntrinsics(_ i: Int) {
        let s = slots[i], views = calViews
        let w = Int(s.size.width), h = Int(s.size.height)
        calStep = .idle
        setWizard("CALCULATING THE LENS OF CAMERA \(i + 1)...")
        DispatchQueue.global(qos: .userInitiated).async {
            let res = calibrateCamera(views: views, board: BoardSpec.points(a3: false), width: w, height: h)
            DispatchQueue.main.async {
                if let r = res, r.rms < 1.5 {
                    s.intr = r.K
                    let info = StoredIntrinsics(uid: s.uid, name: s.stage.cameraName, K: r.K, rms: r.rms, views: views.count, date: CalibStore.now())
                    s.intrInfo = info; CalibStore.save(info)
                    s.stage.toast(String(format: "CAMERA %d CALIBRATED: ERROR %.2f PX%@", i + 1, r.rms, r.rms > 1 ? " (OVER 1 PX: REPEAT FOR BEST RESULT)" : ""))
                    self.advanceCalibration()
                } else {
                    s.stage.toast(res == nil ? "THE LENS CALCULATION FAILED, TRYING AGAIN" : String(format: "ERROR %.1f PX IS TOO HIGH, TRYING AGAIN", res!.rms))
                    self.startIntrinsics(i)
                }
            }
        }
    }

    func solvePair(_ i: Int) {
        let pairs = calPairs, a = slots[0], s = slots[i]
        guard let KA = a.intr, let KB = s.intr else { return }
        let big = a3
        calStep = .idle
        setWizard("CALCULATING THE POSITION OF CAMERA \(i + 1)...")
        DispatchQueue.global(qos: .userInitiated).async {
            let e = calibrateStereo(pairs: pairs, board: BoardSpec.points(a3: big), A: KA, B: KB)
            DispatchQueue.main.async {
                if let e = e, e.rms < 1.5 {
                    let st = StoredExtrinsics(uidA: a.uid, uid: s.uid, E: e, spacingMm: BoardSpec.spacingMm(a3: big), date: CalibStore.now())
                    s.extr = st; CalibStore.save(st)
                    s.stage.toast(String(format: "CAMERA %d POSITIONED: ERROR %.2f PX, %.2f M APART%@", i + 1, e.rms, length(e.T), e.rms > 1 ? " (OVER 1 PX)" : ""))
                    self.advanceCalibration()
                } else {
                    s.stage.toast("THE POSITION DID NOT FIT (CHECK THE BOARD SIZE A4 OR A3): TRYING AGAIN")
                    self.startPair(i)
                }
            }
        }
    }

    // MARK: sync

    @objc func measureDelay() {
        guard slots.count > 1 else { stage.toast("CHOOSE 2 OR 3 CAMERAS FIRST"); return }
        for s in slots { s.sig = [] }
        measureStart = 0
        calStep = .measure
        setWizard("MEASURING THE DELAY FOR 5 S: FLASH A LIGHT AT THE CAMERAS (A PHONE TORCH), OR WAVE YOUR ARMS")
    }

    func signal(_ s: Slot) -> [(Double, Double)] {
        let v = s.sig
        guard v.count > 10 else { return [] }
        var d: [Double] = [0], m: [Double] = [0]
        for i in 1..<v.count { d.append(abs(v[i].lum - v[i - 1].lum)); m.append(v[i].motion) }
        func z(_ x: [Double]) -> [Double] {
            let mean = x.reduce(0, +) / Double(x.count)
            let sd = (x.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(x.count)).squareRoot()
            return sd < 1e-9 ? x.map { _ in 0 } : x.map { ($0 - mean) / sd }
        }
        let zd = z(d), zm = z(m)
        return v.indices.map { (v[$0].t, zd[$0] + 0.7 * zm[$0]) }
    }

    func finishMeasure() {
        calStep = .idle
        let a = signal(slots[0])
        var report: [String] = []
        for (i, s) in slots.enumerated() where i > 0 {
            if let r = estimateOffset(a: a, b: signal(s)), r.peak > 0.05, abs(r.offset) < 1 {
                s.offset = r.offset
                defaults.set(r.offset, forKey: "offset." + CalibStore.safe(slots[0].uid) + "." + CalibStore.safe(s.uid))
                report.append(String(format: "CAMERA %d %+.0f MS", i + 1, r.offset * 1000))
            } else { report.append("CAMERA \(i + 1): NO CLEAR SIGNAL") }
        }
        setWizard("DELAY: " + report.joined(separator: ", "))
        wizardClear = Date().addingTimeInterval(8)
        refreshSettings()
    }

    // MARK: file header and settings

    func camerasHeader() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for (i, s) in slots.enumerated() {
            var c: [String: Any] = ["name": s.stage.cameraName, "uid": s.uid, "width": Int(s.size.width), "height": Int(s.size.height),
                                    "offsetMs": r4(s.offset * 1000)]
            if let k = s.intr { c["fx"] = r4(k.fx); c["fy"] = r4(k.fy); c["cx"] = r4(k.cx); c["cy"] = r4(k.cy); c["k"] = k.k; c["model"] = "fisheye-kb4" }
            if i == 0 { c["R"] = [1, 0, 0, 0, 1, 0, 0, 0, 1]; c["t"] = [0, 0, 0] }
            else if let e = s.extr?.E {
                let R = e.R
                var flat: [Double] = []
                for r in 0..<3 { for col in 0..<3 { flat.append(r4(R[col][r])) } }
                c["R"] = flat; c["t"] = e.t.map { r4($0) }; c["reprojectionPx"] = r4(e.rms)
            }
            out.append(c)
        }
        return out
    }

    func multiSettings() -> String {
        guard slots.count > 1 else { return "CAMERAS: 1" }
        var lines = ["CAMERAS: \(slots.count)  CALIBRATED: \(calibrated ? "yes" : "no")"]
        for (i, s) in slots.enumerated() {
            var l = "  \(i + 1) \(s.stage.cameraName) \(s.formatText)"
            if let k = s.intrInfo { l += String(format: "  lens %.2f px", k.rms) }
            if i > 0 {
                if let e = s.extr?.E { l += String(format: "  position %.2f px, %.2f m", e.rms, length(e.T)) }
                l += String(format: "  delay %+.0f ms", s.offset * 1000)
            }
            lines.append(l)
        }
        if let t = lastTri { lines.append(String(format: "  TRACKING %d: %d joints, %.1f px", t.quality, t.joints.count, t.meanErrPx)) }
        return lines.joined(separator: "\n")
    }
}
