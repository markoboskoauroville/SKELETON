// MultiCam.swift: two or three cameras at once: calibration wizard, sync, triangulation, tracking quality.
import AppKit
import AVFoundation

extension MainView {
    // MARK: frames

    func primaryPose(_ poses: [Pose]) -> Pose? { poses.max { ($0.torso ?? 0) < ($1.torso ?? 0) } }

    var activeIdx: [Int] { slots.indices.filter { ($0 == 0 || slots[$0].use) && slots[$0].missingText == nil } }

    func frame(_ s: Slot, _ f: Frame) {
        guard let idx = slots.firstIndex(where: { $0 === s }) else { return }
        s.size = f.size
        s.lastFrameWall = Date()
        checkPicture(s, f)
        if s.missingText != nil { return }          // a black or missing picture: no tile, no triangulation, listed below the grid
        if let k = s.intr, k.width != Int(f.size.width) || k.height != Int(f.size.height) {
            s.intr = nil; s.extr = nil
            if !s.sizeWarned { s.sizeWarned = true; s.stage.toast("THE CALIBRATION IS FOR ANOTHER PICTURE SIZE: CALIBRATE AGAIN") }
        }
        var parts: [String] = []
        if !s.formatText.isEmpty { parts.append(s.formatText) }
        if idx == 0 && slots.count > 1 {
            parts.append("SYNC " + slots.dropFirst().map { String(format: "%+.0f", $0.offset * 1000) }.joined(separator: "/") + " MS")
        }
        s.stage.extraInfo = parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
        guard f.analyzed else { s.stage.setImage(f.image, size: f.size); return }

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
            for (k, o) in slots.enumerated() { o.stage.viewQuality = lastTri?.viewQuality[k] }
        }
        s.stage.update(image: f.image, size: f.size, poses: f.poses, frontal: frontal)
        if idx == 0, let r = recorder { r.add(time: f.t, raw: f.raw, size: f.size, v3: f.v3, tri: lastTri) }

        switch calStep {
        case .intrinsics: if (idx == 0 || s.use) && s.intr == nil { detect(s, f) }
        case .pair: if idx == 0 || s.use { detect(s, f) }
        case .measure:
            if idx == 0 && measureStart == 0 { measureStart = f.t }
            if f.t - measureStart > 5, measureStart > 0 { finishMeasure() }
        case .idle: break
        }
        if let c = wizardClear, Date() > c { wizardClear = nil; setWizard(nil) }
    }

    // MARK: black pictures and sources that stopped

    /// Black or uniform for over a second (mean under 8 of 255, almost no variation): no picture. A picture that does not change
    /// for 2 s while no person was ever seen (the OBS Virtual Camera's placeholder logo) is "no picture (static)". Phones are
    /// real cameras with their own watchdog and are not tested for this. Back after half a second of a real picture.
    func checkPicture(_ s: Slot, _ f: Frame) {
        guard f.lum >= 0 else { return }
        let now = Date()
        var still = false
        if s.phone == nil { still = s.still.add(t: f.t, sig: f.sig, person: !f.poses.isEmpty) }
        let black = f.lum < 8 && f.lumStd < 4
        if black || still {
            s.goodSince = nil
            if black { if s.blackSince == nil { s.blackSince = now } } else { s.blackSince = nil }
            let why = black ? "no picture" : "no picture (static)"
            var ready = true
            if black, let since = s.blackSince { ready = now.timeIntervalSince(since) > 1.2 && now.timeIntervalSince(s.startedAt) > 1 }
            if ready, s.missingText != why { setMissing(s, why) }
        } else {
            s.blackSince = nil
            if s.goodSince == nil { s.goodSince = now }
            if s.missingText != nil, now.timeIntervalSince(s.goodSince!) > 0.5 {
                s.missingText = nil
                rebuildMissingBar(); needsLayout = true
            }
        }
    }

    func setMissing(_ s: Slot, _ why: String) {
        guard s.missingText != why else { return }
        s.missingText = why
        rebuildMissingBar(); needsLayout = true
    }

    func rebuildMissingBar() {
        let key = slots.map { ($0.missingText ?? "-") + $0.stage.cameraName }.joined(separator: "|")
        guard key != missingKey else { return }
        missingKey = key
        missingBar.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        for (k, s) in slots.enumerated() {
            guard let why = s.missingText else { continue }
            let name = s.stage.cameraName.isEmpty ? "CAMERA \(k + 1)" : s.stage.cameraName
            let label = NSTextField(labelWithString: "\(name)  ·  \(why)  ·  CHECKED AGAIN BY ITSELF")
            label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            label.textColor = NSColor(srgbRed: 0.91, green: 0.64, blue: 0.24, alpha: 1)
            label.lineBreakMode = .byWordWrapping
            label.frame = NSRect(x: 14, y: y + 4, width: 600, height: 18)
            missingBar.addSubview(label)
            let b = button((why.contains("offline") || s.phone != nil) ? "CONNECT" : "RETRY", #selector(retryPressed(_:)))
            b.tag = k
            b.frame = NSRect(x: 630, y: y + 3, width: 90, height: 20)
            missingBar.addSubview(b)
            y += 26
        }
    }

    @objc func retryPressed(_ b: NSButton) {
        guard b.tag < slots.count else { return }
        restart(b.tag)
        slots[b.tag].stage.toast("TRYING AGAIN...")
    }

    /// Start a source again: an AVFoundation camera is found again by its unique ID (or name) after a replug; a phone goes
    /// through its own start (adb forward, Manual Camera).
    func restart(_ k: Int) {
        let s = slots[k]
        s.lastRestart = Date()
        if let p = s.phone { selectPhone(p.phone, slot: k); return }
        devices = AVCameraSource.devices()
        let uid = s.uid, name = s.stage.cameraName
        if let d = devices.first(where: { $0.uniqueID == uid }) ?? devices.first(where: { $0.localizedName == name }) { select(d, slot: k) }
    }

    /// Every half second: sources that gave no frames for 2 s are listed as missing and started again every 10 s;
    /// the start-up line says which cameras are found.
    func watchSources() {
        let now = Date()
        for (k, s) in slots.enumerated() where s.device != nil || s.phone != nil {
            let silent = now.timeIntervalSince(s.lastFrameWall) > 2
            if s.missingText == nil, silent, now.timeIntervalSince(s.startedAt) > 4 {
                setMissing(s, s.phone != nil && s.phone?.statusText.contains("OFFLINE") == true ? "offline" : "no picture (no frames)")
            }
            if s.missingText != nil, silent, now.timeIntervalSince(s.lastRestart) > 10 { restart(k) }
        }
        rebuildMissingBar()
        if now < startupUntil, calStep == .idle {
            var all = true
            let parts = slots.enumerated().map { (k, s) -> String in
                let name = s.stage.cameraName.isEmpty ? "CAMERA \(k + 1)" : s.stage.cameraName
                let ok = s.lastFrameWall > Date.distantPast && s.missingText == nil
                if !ok { all = false }
                return name + (ok ? " ✓" : " ...")
            }
            if !all { setWizard("FINDING CAMERAS: " + parts.joined(separator: "   ")) }
            else if slots[0].stage.wizard?.hasPrefix("FINDING") == true { setWizard(nil) }
        } else if slots[0].stage.wizard?.hasPrefix("FINDING") == true { setWizard(nil) }
    }

    // MARK: triangulation

    var calibrated: Bool {
        let act = activeIdx
        guard slots.count > 1, act.count > 1 else { return false }
        return act.allSatisfy { slots[$0].intr != nil && ($0 == 0 || slots[$0].extr != nil) }
    }

    /// All views that see a joint, confidence-weighted; a view that disagrees with the others is rejected for that joint.
    func triangulateFrame(_ f: Frame) -> TriResult? {
        guard calibrated, let KA = slots[0].intr, let pa = primaryPose(f.poses) else { return nil }
        struct View { var idx: Int; var K: Intrinsics; var R: M3; var t: V3; var pose: Pose; var H: Double }
        var views: [View] = [View(idx: 0, K: KA, R: matrix_identity_double3x3, t: V3(0, 0, 0), pose: pa, H: Double(f.size.height))]
        for (k, s) in slots.enumerated() where k > 0 && s.use && s.missingText == nil {
            guard let K = s.intr, let e = s.extr?.E else { continue }
            let want = f.t + s.offset
            guard let h = s.hist.min(by: { abs($0.t - want) < abs($1.t - want) }), abs(h.t - want) < 0.05, let pb = h.pose else { continue }
            views.append(View(idx: k, K: K, R: e.R, t: e.T, pose: pb, H: Double(h.size.height)))
        }
        guard views.count >= 2 else { return nil }
        struct Obs { var view: Int; var px: V2; var w: Double }
        func solve(_ o: [Obs]) -> (V3, [Double])? {
            var rays: [Ray] = []
            for ob in o { let v = views[ob.view]; rays.append(Ray(xy: v.K.unproject(ob.px), R: v.R, t: v.t, w: ob.w)) }
            guard let X = triangulate(rays) else { return nil }
            var errs: [Double] = []
            for ob in o {
                let v = views[ob.view]
                if let q = v.K.project(v.R * X + v.t) { errs.append(length(q - ob.px)) } else { errs.append(100) }
            }
            return (X, errs)
        }
        var joints: [Jt: V3] = [:]
        var jointErrs: [Double] = []
        var viewErr: [Int: [Double]] = [:]
        for jt in Jt.allCases {
            var cur: [Obs] = []
            for (vi, v) in views.enumerated() {
                if let p = v.pose.j[jt] { cur.append(Obs(view: vi, px: V2(Double(p.x) * v.H, Double(p.y) * v.H), w: Double(v.pose.conf[jt] ?? 0.5))) }
            }
            guard cur.count >= 2, let first = solve(cur) else { continue }
            var X = first.0, e = first.1
            var rejected: [Int] = []
            for _ in 0..<2 where cur.count >= 3 {
                let sorted = e.sorted()
                let med = sorted[sorted.count / 2]
                guard let worst = e.max(), worst > max(8, 3 * med), let wi = e.firstIndex(of: worst) else { break }
                rejected.append(cur[wi].view)
                cur.remove(at: wi)
                guard let again = solve(cur) else { break }
                X = again.0; e = again.1
            }
            let mean = e.reduce(0, +) / Double(e.count)
            guard mean < 12 else { continue }
            joints[jt] = X; jointErrs.append(mean)
            for (i, ob) in cur.enumerated() { viewErr[views[ob.view].idx, default: []].append(e[i]) }
            for vi in rejected { viewErr[views[vi].idx, default: []].append(20) }
        }
        guard joints.count >= 6 else { return nil }
        let mean = jointErrs.reduce(0, +) / Double(jointErrs.count)
        let cover = Double(joints.count) / Double(Jt.allCases.count)
        let errScore: Double = 1.0 - min(1.0, mean / 8.0)
        let qd: Double = 50.0 * cover + 50.0 * errScore
        var res = TriResult(joints: joints, quality: max(0, min(100, Int(qd.rounded()))), meanErrPx: mean, views: views.count)
        for v in views {
            let es = viewErr[v.idx] ?? []
            guard !es.isEmpty else { res.viewQuality[v.idx] = 0; continue }
            let me = es.reduce(0, +) / Double(es.count)
            let part: Double = 70.0 * (1.0 - min(1.0, me / 8.0)) + 30.0 * min(1.0, Double(es.count) / 12.0)
            res.viewQuality[v.idx] = max(0, min(100, Int(part.rounded())))
        }
        return res
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
        for k in 1..<4 { camPopups[k].isHidden = k >= n; useSw[k - 1].isHidden = k >= n }
        multiRow.isHidden = n < 2
        for s in slots { s.pipe.analysisEvery = n >= 3 ? 2 : 1 }
        calStep = .idle
        setWizard(nil)
        needsLayout = true
        if !devices.isEmpty { reloadDevices() }
        setTitle(calibrateButton, calibrated ? "RECALIBRATE" : "CALIBRATE")
    }

    func loadCalibration(_ s: Slot) {
        if let i = CalibStore.loadIntrinsics(s.uid) { s.intr = i.K; s.intrInfo = i } else { s.intr = nil; s.intrInfo = nil }
        if let k = slots.firstIndex(where: { $0 === s }), k > 0 {
            s.use = defaults.object(forKey: "use." + CalibStore.safe(s.uid)) as? Bool ?? true
            useSw[k - 1].isOn = s.use
        }
        if let a = slots.first, s !== a {
            s.extr = CalibStore.loadExtrinsics(a: a.uid, b: s.uid)
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
        guard slots.count > 1 else { stage.toast("CHOOSE 2 TO 4 CAMERAS FIRST"); return }
        guard activeIdx.count > 1 else { stage.toast("SWITCH ON AT LEAST ONE MORE CAMERA"); return }
        guard activeIdx.allSatisfy({ slots[$0].device != nil || slots[$0].phone != nil }) else { return }
        if calibrated { for k in activeIdx { slots[k].intr = nil; slots[k].extr = nil } }
        startCalibration()
    }

    func resetBoardState() {
        for s in slots { s.lastBoard = nil; s.prevBoard = nil; s.stable = 0 }
    }

    /// Intrinsics of every camera together (the board goes in front of each one), then the cameras are placed one by one
    /// by pairs: a camera is positioned as soon as it shares 12 board views with a camera that is already positioned,
    /// and its pose is chained into camera 1's frame.
    func startCalibration() {
        resetBoardState()
        for s in slots { s.calViews = []; s.lastCap = nil; s.solving = false }
        pairData = [:]; pairLast = [:]; baViews = []; baIndex = [:]
        positioned = [0]
        for k in activeIdx where k > 0 && slots[k].extr != nil && slots[k].intr != nil { positioned.insert(k) }
        if activeIdx.contains(where: { slots[$0].intr == nil }) {
            calStep = .intrinsics
            calibTick()
        } else { startPairs() }
    }

    func startPairs() {
        resetBoardState()
        pairData = [:]; pairLast = [:]; baViews = []; baIndex = [:]
        if activeIdx.allSatisfy({ positioned.contains($0) }) { finishCalibration(); return }
        calStep = .pair
        calibTick()
    }

    func finishCalibration() {
        calStep = .idle
        let e = activeIdx.filter { $0 > 0 }.compactMap { slots[$0].extr?.E.rms }.map { String(format: "%.2f", $0) }.joined(separator: " / ")
        setWizard("CALIBRATION READY: REPROJECTION " + e + " PX")
        wizardClear = Date().addingTimeInterval(8)
        setTitle(calibrateButton, "RECALIBRATE")
        runBundleAdjust()
    }

    /// After the pairwise, chained calibration: all cameras' poses together by minimising the reprojection error of every
    /// board capture (bundle adjustment, BundleAdjust.swift). Kept only when the error went down.
    func runBundleAdjust() {
        let views = baViews
        let ids = activeIdx
        guard ids.count > 2, views.count >= 6, views.contains(where: { $0.obs[0] != nil }) else { return }
        let dummy = Intrinsics(fx: 1000, fy: 1000, cx: 960, cy: 540, k: [0, 0, 0, 0], width: 1920, height: 1080)
        let Ks = slots.map { $0.intr ?? dummy }
        let poses = slots.enumerated().map { (k, s) -> Pose6 in
            guard k > 0, let E = s.extr?.E else { return Pose6(r: V3(0, 0, 0), t: V3(0, 0, 0)) }
            return Pose6(r: V3(E.r[0], E.r[1], E.r[2]), t: V3(E.t[0], E.t[1], E.t[2]))
        }
        let board = BoardSpec.points(a3: a3)
        let refineK = defaults.bool(forKey: "ba.intrinsics")
        DispatchQueue.global(qos: .userInitiated).async {
            let res = bundleAdjust(K: Ks, poses: poses, views: views, board: board, refineIntrinsics: refineK)
            DispatchQueue.main.async {
                guard let r = res, r.rmsAfter < r.rmsBefore else { return }
                for k in ids where k > 0 {
                    guard let old = self.slots[k].extr else { continue }
                    let p = r.poses[k]
                    let E = Extrinsics(r: [p.r.x, p.r.y, p.r.z], t: [p.t.x, p.t.y, p.t.z], rms: r.perCamera[k], pairs: old.E.pairs)
                    var st = old; st.E = E; st.date = CalibStore.now()
                    self.slots[k].extr = st; CalibStore.save(st)
                }
                if refineK {
                    for k in ids {
                        self.slots[k].intr = r.K[k]
                        if var info = self.slots[k].intrInfo { info.K = r.K[k]; self.slots[k].intrInfo = info; CalibStore.save(info) }
                    }
                }
                let msg = String(format: "BUNDLE ADJUSTMENT OVER %d BOARD VIEWS: ERROR %.2f PX, WAS %.2f PX", r.views, r.rmsAfter, r.rmsBefore)
                self.setWizard("CALIBRATION READY. " + msg)
                self.wizardClear = Date().addingTimeInterval(8)
                self.stage.toast(msg)
            }
        }
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
        case .intrinsics:
            var lines: [String] = []
            for k in activeIdx {
                let s = slots[k]
                guard s.intr == nil else { continue }
                lines.append("\(k + 1): \(s.calViews.count)/18")
                guard !s.solving, let b = s.lastBoard, s.stable >= 2 else { continue }
                if let last = s.lastCap, !diverse(last, b.pts, width: Double(s.size.width)) { continue }
                s.calViews.append(b.pts); s.lastCap = b.pts
                if s.calViews.count >= 18 { solveIntrinsics(k) }
            }
            if calStep == .intrinsics {
                setWizard("MOVE THE BOARD IN FRONT OF EACH CAMERA, TILT IT, HOLD IT STILL A MOMENT. CAMERA " + lines.joined(separator: "   "))
            }
        case .pair:
            var lines: [String] = []
            for i in activeIdx where !positioned.contains(i) {
                let s = slots[i]
                var best = 0
                for j in positioned.sorted() {
                    let a = slots[j]
                    let key = "\(j)-\(i)"
                    best = max(best, pairData[key]?.count ?? 0)
                    guard !s.solving, let ba = a.lastBoard, let bs = s.lastBoard, a.stable >= 2, s.stable >= 2, abs(ba.t - bs.t) < 0.3 else { continue }
                    if let last = pairLast[key], !diverse(last, ba.pts, width: Double(a.size.width)) { continue }
                    pairData[key, default: []].append((ba.pts, bs.pts)); pairLast[key] = ba.pts
                    let vk = "\(i)@\(bs.t)"
                    if let vi = baIndex[vk] { baViews[vi].obs[j] = ba.pts }
                    else { baIndex[vk] = baViews.count; baViews.append(BAView(obs: [j: ba.pts, i: bs.pts])) }
                    best = max(best, pairData[key]!.count)
                    if pairData[key]!.count >= 12 { solvePair(j, i); break }
                }
                lines.append("\(i + 1): \(best)/12")
            }
            if calStep == .pair {
                setWizard("HOLD THE BOARD WHERE A NEW CAMERA AND A POSITIONED ONE (\(positioned.sorted().map { String($0 + 1) }.joined(separator: ","))) SEE IT TOGETHER, KEEP IT STILL, MOVE IT. CAMERA " + lines.joined(separator: "   ") + "  (BOARD \(a3 ? "A3" : "A4"))")
            }
        default: break
        }
    }

    func solveIntrinsics(_ k: Int) {
        let s = slots[k], views = s.calViews
        let w = Int(s.size.width), h = Int(s.size.height)
        s.solving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = calibrateCamera(views: views, board: BoardSpec.points(a3: false), width: w, height: h)
            DispatchQueue.main.async {
                s.solving = false
                if let r = res, r.rms < 1.5 {
                    s.intr = r.K
                    let info = StoredIntrinsics(uid: s.uid, name: s.stage.cameraName, K: r.K, rms: r.rms, views: views.count, date: CalibStore.now())
                    s.intrInfo = info; CalibStore.save(info)
                    s.stage.toast(String(format: "CAMERA %d LENS DONE: ERROR %.2f PX%@", k + 1, r.rms, r.rms > 1 ? " (OVER 1 PX: REPEAT FOR BEST RESULT)" : ""))
                    if self.calStep == .intrinsics, self.activeIdx.allSatisfy({ self.slots[$0].intr != nil }) { self.startPairs() }
                } else {
                    s.calViews = []; s.lastCap = nil
                    s.stage.toast(res == nil ? "THE LENS CALCULATION FAILED, TRYING AGAIN" : String(format: "ERROR %.1f PX IS TOO HIGH, TRYING AGAIN", res!.rms))
                }
            }
        }
    }

    /// Pose of camera i from pairs with the positioned camera j, chained into camera 1's frame.
    func solvePair(_ j: Int, _ i: Int) {
        let key = "\(j)-\(i)"
        guard let pairs = pairData[key], let KA = slots[j].intr, let KB = slots[i].intr else { return }
        let a = slots[0], s = slots[i], big = a3
        s.solving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let e = calibrateStereo(pairs: pairs, board: BoardSpec.points(a3: big), A: KA, B: KB)
            DispatchQueue.main.async {
                s.solving = false
                guard let e = e, e.rms < 1.5 else {
                    self.pairData[key] = []; self.pairLast[key] = nil
                    s.stage.toast("THE POSITION DID NOT FIT (CHECK THE BOARD SIZE A4 OR A3): TRYING AGAIN")
                    return
                }
                var total = e
                if j != 0, let ej = self.slots[j].extr?.E {
                    let R = e.R * ej.R, t = e.R * ej.T + e.T
                    let r = rodriguesInv(R)
                    total = Extrinsics(r: [r.x, r.y, r.z], t: [t.x, t.y, t.z], rms: e.rms, pairs: e.pairs)
                }
                let st = StoredExtrinsics(uidA: a.uid, uid: s.uid, E: total, spacingMm: BoardSpec.spacingMm(a3: big), date: CalibStore.now())
                s.extr = st; CalibStore.save(st)
                self.positioned.insert(i)
                s.stage.toast(String(format: "CAMERA %d POSITIONED (VIA CAMERA %d): ERROR %.2f PX, %.2f M FROM CAMERA 1%@", i + 1, j + 1, e.rms, length(total.T), e.rms > 1 ? " (OVER 1 PX)" : ""))
                if self.activeIdx.allSatisfy({ self.positioned.contains($0) }) { self.finishCalibration() }
            }
        }
    }

    // MARK: sync

    @objc func measureDelay() {
        guard slots.count > 1 else { stage.toast("CHOOSE 2 TO 4 CAMERAS FIRST"); return }
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
        for (i, s) in slots.enumerated() where i > 0 && s.use {
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
            var c: [String: Any] = ["name": s.stage.cameraName, "uid": s.uid, "used": i == 0 || s.use, "width": Int(s.size.width), "height": Int(s.size.height),
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
            if !(i == 0 || s.use) { l += "  (not used)" }
            if i > 0 {
                if let e = s.extr?.E { l += String(format: "  position %.2f px, %.2f m", e.rms, length(e.T)) }
                l += String(format: "  delay %+.0f ms", s.offset * 1000)
            }
            lines.append(l)
        }
        if let t = lastTri {
            lines.append(String(format: "  TRACKING %d: %d joints from %d views, %.1f px", t.quality, t.joints.count, t.views, t.meanErrPx))
            lines.append("  PER CAMERA: " + t.viewQuality.keys.sorted().map { "\($0 + 1)=\(t.viewQuality[$0]!)" }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
