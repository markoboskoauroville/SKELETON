// Camera.swift: any camera (built-in, USB/UVC like the Sony ILCE-7M5, Continuity, virtual) -> frames + Vision body poses.
import AVFoundation
import Vision
import VideoToolbox
import CoreImage

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
            }
        }
        if p.j.count >= 4 { out.append(p) }
    }
    return out
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CGImage, CGSize, [Pose]) -> Void)?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let videoQ = DispatchQueue(label: "skeleton.video")
    private let sessionQ = DispatchQueue(label: "skeleton.session")
    private let tracker = Tracker()
    private(set) var formatText = ""
    private var current: AVCaptureDevice?

    static func devices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        var all = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        for d in AVCaptureDevice.devices(for: .video) where !all.contains(where: { $0.uniqueID == d.uniqueID }) { all.append(d) }
        return all
    }

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQ)
    }

    func start(_ device: AVCaptureDevice, done: @escaping () -> Void) {
        sessionQ.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for i in self.session.inputs { self.session.removeInput(i) }
            if !self.session.outputs.contains(self.output), self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) { self.session.addInput(input) }
            self.session.commitConfiguration()
            self.pickFormat(device)
            self.current = device
            self.session.startRunning()
            DispatchQueue.main.async(execute: done)
        }
    }

    func stop() { sessionQ.async { if self.session.isRunning { self.session.stopRunning() } } }

    /// Best format: 1920x1080 at 30 fps, else 1280x720, else what the camera gives.
    private func pickFormat(_ d: AVCaptureDevice) {
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
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        guard let img = cg else { return }
        let w = CGFloat(CVPixelBufferGetWidth(pb)), h = CGFloat(CVPixelBufferGetHeight(pb))
        let req = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        try? handler.perform([req])
        let poses = tracker.update(extractPoses(req.results ?? [], aspect: w / h))
        let cb = onFrame
        DispatchQueue.main.async { cb?(img, CGSize(width: w, height: h), poses) }
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
