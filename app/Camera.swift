// Camera.swift: AVFoundation camera as a FrameSource (Source.swift), and the Pipeline that turns any FrameSource into
// Frames: the picture, Vision 2D poses (and 3D while recording), light smoothing.
import AVFoundation
import Vision
import CoreImage
import QuartzCore

final class Tracker {
    private struct T { var pose: Pose }
    private var tracks: [T] = []

    /// Light moving average: each joint is the mean of its last smoothed place and the new one.
    func update(_ raw: [Pose]) -> [Pose] {
        var used = Set<Int>(), next: [T] = []
        for p in raw {
            let c = p.centre
            var best = -1, bd = CGFloat.greatestFiniteMagnitude
            for (i, t) in tracks.enumerated() where !used.contains(i) {
                let o = t.pose.centre
                let d = hypot(c.x - o.x, c.y - o.y)
                if d < bd { bd = d; best = i }
            }
            if best >= 0 && bd < 0.35 {
                used.insert(best)
                var sm = Pose(aspect: p.aspect)
                sm.conf = p.conf
                for (k, v) in p.j {
                    if let o = tracks[best].pose.j[k] { sm.j[k] = CGPoint(x: (o.x + v.x) / 2, y: (o.y + v.y) / 2) } else { sm.j[k] = v }
                }
                next.append(T(pose: sm))
            } else { next.append(T(pose: p)) }
        }
        tracks = next
        return next.map { $0.pose }
    }
}

func extractPoses(_ results: [VNHumanBodyPoseObservation], aspect: CGFloat) -> [Pose] {
    var out: [Pose] = []
    for o in results {
        var p = Pose(aspect: aspect)
        for jt in Jt.allCases {
            if let pt = try? o.recognizedPoint(jt.vn), pt.confidence >= 0.3 {
                p.j[jt] = CGPoint(x: pt.location.x * aspect, y: 1 - pt.location.y)
                p.conf[jt] = CGFloat(pt.confidence)
            }
        }
        if p.j.count >= 4 { out.append(p) }
    }
    return out
}

/// One processed frame.
struct Frame {
    var image: CGImage
    var size: CGSize
    var poses: [Pose]        // smoothed
    var raw: [Pose]          // as Vision gave them (for the recording)
    var t: Double            // host clock seconds
    var lum: Double
    var lumStd = 0.0
    var v3: V3Obs?
    var analyzed = true      // false: only the picture is new, the poses are the last analysed ones (see Pipeline.analysisEvery)
}

/// An AVFoundation camera: built-in, USB/UVC (Sony ILCE-7M5), Continuity, Iriun, OBS/NDI virtual cameras.
final class AVCameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let device: AVCaptureDevice
    var name: String { device.localizedName }
    var uniqueID: String { device.uniqueID }
    var intrinsics: Intrinsics? { nil }
    private(set) var formatText = ""
    var clockNote: String { "AVCapture host clock" }
    var onPixelBuffer: ((CVPixelBuffer, Double) -> Void)?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let videoQ = DispatchQueue(label: "skeleton.video")
    private let sessionQ = DispatchQueue(label: "skeleton.session")

    init(device: AVCaptureDevice) {
        self.device = device
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQ)
    }

    static func devices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        var all = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        for d in AVCaptureDevice.devices(for: .video) where !all.contains(where: { $0.uniqueID == d.uniqueID }) { all.append(d) }
        return all
    }

    func start(completion: @escaping (Bool) -> Void) {
        sessionQ.async {
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            var ok = false
            if let input = try? AVCaptureDeviceInput(device: self.device), self.session.canAddInput(input) { self.session.addInput(input); ok = true }
            self.session.commitConfiguration()
            if ok { self.pickFormat(); self.session.startRunning() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func stop() {
        onPixelBuffer = nil
        sessionQ.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Best format: 1920x1080 at 30 fps, else 1280x720, else what the camera gives.
    private func pickFormat() {
        let d = device
        var best: (AVCaptureDevice.Format, Int)?
        for f in d.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { continue }
            var score = 0
            if dim.width == 1920 && dim.height == 1080 { score = 3 } else if dim.width == 1280 && dim.height == 720 { score = 2 }
            if score > 0, best == nil || score > best!.1 { best = (f, score) }
        }
        if let (f, _) = best {
            do {
                try d.lockForConfiguration()
                d.activeFormat = f
                d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                d.unlockForConfiguration()
            } catch { NSLog("[Skeleton] format: %@", "\(error)") }
        }
        let dim = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        formatText = "\(dim.width)x\(dim.height)"
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPixelBuffer?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}

/// Turns the frames of any FrameSource into Frames (Vision 2D, optional 3D). Late frames are dropped, never queued.
final class Pipeline {
    var onFrame: ((Frame) -> Void)?
    var want3D = false
    /// Vision runs on every n-th frame (n = 2 with three or four cameras, to keep the Mac up); the picture is shown at full rate.
    var analysisEvery = 1
    private var counter = 0
    private var lastPoses: [Pose] = []
    private(set) var source: FrameSource?
    private let tracker = Tracker()
    private let q = DispatchQueue(label: "skeleton.pipeline")
    private let lock = NSLock()
    private var busy = false

    /// Quarter turns clockwise that stand this camera's picture upright (0...3), set per camera (MainView remembers it).
    /// Vision is told the orientation (no pixels moved for it); the picture is turned by Core Image.
    var turns = 0
    /// Marko, 16.11.2026: "I am upside down ... detect upside down picture and simply rotate them." For the first 15 s of a
    /// camera, while no person is seen upright, the other three turns are tried every few analysed frames; one that finds an
    /// upright body 3 times is taken and told through [onAutoTurns]. Once a person is seen upright it stops for good (a
    /// headstand later never turns the camera). Off when the turn was set by hand.
    var autoOrient = true
    var onAutoTurns: ((Int) -> Void)?
    private var autoUntil = 0.0
    private var autoVotes: [Int: Int] = [:]
    private var autoProbe = 0
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    static func orientation(_ turns: Int) -> CGImagePropertyOrientation {
        switch (turns % 4 + 4) % 4 { case 1: return .right; case 2: return .down; case 3: return .left; default: return .up }
    }

    /// A person standing up in the picture (y grows downward): the neck or nose clearly above the hips.
    static func upright(_ poses: [Pose]) -> Bool {
        poses.contains { p in
            guard p.j.count >= 6, let hip = p.hipCentre, let top = p.j[.neck] ?? p.j[.nose] else { return false }
            return top.y < hip.y - 0.05
        }
    }

    func attach(_ s: FrameSource) {
        detach()
        source = s
        autoUntil = CACurrentMediaTime() + 15; autoVotes = [:]; autoProbe = 0
        s.onPixelBuffer = { [weak self] pb, t in self?.handle(pb, t) }
    }

    func detach() { source?.stop(); source = nil }

    private func handle(_ pb: CVPixelBuffer, _ t: Double) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        q.async {
            self.process(pb, t)
            self.lock.lock(); self.busy = false; self.lock.unlock()
        }
    }

    private func process(_ pb: CVPixelBuffer, _ t: Double) {
        let turn = turns
        let o = Pipeline.orientation(turn)
        var img: CGImage
        var w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        if turn % 4 == 0 {
            guard let c = cgImage(from: pb) else { return }
            img = c
        } else {
            let ci = CIImage(cvPixelBuffer: pb).oriented(o)
            guard let c = Pipeline.ci.createCGImage(ci, from: ci.extent) else { return }
            img = c; w = ci.extent.width; h = ci.extent.height
        }
        counter += 1
        if analysisEvery > 1 && counter % analysisEvery != 0 {
            let f = Frame(image: img, size: CGSize(width: w, height: h), poses: lastPoses, raw: [], t: t, lum: -1, lumStd: 0, v3: nil, analyzed: false)
            let cb = onFrame
            DispatchQueue.main.async { cb?(f) }
            return
        }
        let req = VNDetectHumanBodyPoseRequest()
        var reqs: [VNRequest] = [req]
        var req3: VNDetectHumanBodyPose3DRequest?
        if want3D { let r = VNDetectHumanBodyPose3DRequest(); req3 = r; reqs.append(r) }
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: o, options: [:]).perform(reqs)
        let raw = extractPoses(req.results ?? [], aspect: w / h)
        if autoOrient && autoUntil > 0 { autoCheck(pb, raw, turn) }
        let poses = tracker.update(raw)
        lastPoses = poses
        let v3 = req3?.results?.first.map { extract3D($0) }
        let luma = lumaStats(pb)
        let f = Frame(image: img, size: CGSize(width: w, height: h), poses: poses, raw: raw, t: t, lum: luma.mean, lumStd: luma.std, v3: v3)
        let cb = onFrame
        DispatchQueue.main.async { cb?(f) }
    }
}

extension Pipeline {
    /// The start-up orientation check (see [autoOrient]); runs on the pipeline's queue.
    fileprivate func autoCheck(_ pb: CVPixelBuffer, _ raw: [Pose], _ turn: Int) {
        if Pipeline.upright(raw) { autoUntil = 0; return }               // upright as it is: never again for this camera
        if CACurrentMediaTime() > autoUntil { autoUntil = 0; return }
        autoProbe += 1
        guard autoProbe % 6 == 0 else { return }                          // a trial every 6th analysed frame: light on the Mac
        for k in 1...3 {
            let cand = (turn + k) % 4
            let o = Pipeline.orientation(cand)
            let r = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: o, options: [:]).perform([r])
            let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
            let aspect = cand % 2 == 1 ? h / w : w / h
            if Pipeline.upright(extractPoses(r.results ?? [], aspect: aspect)) {
                autoVotes[cand, default: 0] += 1
                if autoVotes[cand]! >= 3 {
                    turns = cand; autoUntil = 0
                    let cb = onAutoTurns
                    DispatchQueue.main.async { cb?(cand) }
                }
                return
            }
        }
    }
}

/// A still photo -> its skeleton (the biggest person), once.
func poseFromPhoto(_ url: URL) -> (Pose, CGImage)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 1600]
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let req = VNDetectHumanBodyPoseRequest()
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    let aspect = CGFloat(img.width) / CGFloat(img.height)
    let poses = extractPoses(req.results ?? [], aspect: aspect)
    guard let p = poses.max(by: { ($0.torso ?? 0) < ($1.torso ?? 0) }) else { return nil }
    return (p, img)
}
