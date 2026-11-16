// Recorder.swift: the skeleton recording (format skeleton-mantra/1, docs/skel-format.md): 2D + 3D per frame, no video.
import Foundation
import Vision

enum J3: String, CaseIterable {
    case root, spine, centerShoulder, centerHead, topHead
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
    var vn: VNHumanBodyPose3DObservation.JointName {
        switch self {
        case .root: return .root
        case .spine: return .spine
        case .centerShoulder: return .centerShoulder
        case .centerHead: return .centerHead
        case .topHead: return .topHead
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        }
    }
}

private func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

final class Recorder {
    let camera: String
    let mirror: Bool
    private var frames: [Data] = []
    private var first: Double?
    private(set) var last = 0.0
    private var width = 0, height = 0
    let started = Date()

    init(camera: String, mirror: Bool) { self.camera = camera; self.mirror = mirror }

    var count: Int { frames.count }
    var seconds: Double { Date().timeIntervalSince(started) }

    func add(time: Double, obs2d: [VNHumanBodyPoseObservation], obs3d: VNHumanBodyPose3DObservation?, w: Int, h: Int) {
        if first == nil { first = time }
        let t = time - (first ?? time)
        last = t; width = w; height = h
        var f: [String: Any] = ["t": r4(t)]
        // the primary person: the longest torso (neck to root)
        func torso(_ o: VNHumanBodyPoseObservation) -> Double {
            guard let n = try? o.recognizedPoint(.neck), let r = try? o.recognizedPoint(.root), n.confidence >= 0.3, r.confidence >= 0.3 else { return 0 }
            return Double(hypot(n.location.x - r.location.x, (n.location.y - r.location.y) * CGFloat(h) / CGFloat(max(1, w))))
        }
        var p2: [String: [Double]] = [:]
        if let o = obs2d.max(by: { torso($0) < torso($1) }) {
            for jt in Jt.allCases {
                if let pt = try? o.recognizedPoint(jt.vn), pt.confidence >= 0.3 {
                    p2[jt.vn.rawValue.rawValue] = [r4(Double(pt.location.x)), r4(1 - Double(pt.location.y)), r4(Double(pt.confidence))]
                }
            }
        }
        f["p2"] = p2
        if let o3 = obs3d {
            var p3: [String: [Double]] = [:], r3: [String: [Double]] = [:]
            for j in J3.allCases {
                guard let pt = try? o3.recognizedPoint(j.vn) else { continue }
                let m = pt.position
                let name = j.vn.rawValue.rawValue
                p3[name] = [r4(Double(m.columns.3.x)), r4(Double(m.columns.3.y)), r4(Double(m.columns.3.z))]
                let l = pt.localPosition
                var flat: [Double] = []
                for row in 0..<4 { for col in 0..<4 { flat.append(r4(Double(l[col][row]))) } }
                r3[name] = flat
            }
            if !p3.isEmpty { f["p3"] = p3; if !r3.isEmpty { f["r3"] = r3 } }
            f["h"] = r4(Double(o3.bodyHeight))
        } else { f["h"] = NSNull() }
        if let d = try? JSONSerialization.data(withJSONObject: f) { frames.append(d) }
    }

    /// Writes ~/Movies/Skeleton/YYYY-MM-DD_HH-MM-SS.skel.json and returns its URL.
    func write() -> URL? {
        guard frames.count > 1 else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Skeleton", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent(f.string(from: started) + ".skel.json")
        let fps = last > 0 ? Double(frames.count - 1) / last : 30
        var roles3: [String: String] = [:], roles2: [String: String] = [:]
        for j in J3.allCases { roles3[j.vn.rawValue.rawValue] = j.rawValue }
        for j in Jt.allCases { roles2[j.vn.rawValue.rawValue] = j.rawValue }
        let rest: [String: Any] = [
            "fps": r4(fps), "camera": camera, "width": width, "height": height, "mirror": mirror,
            "joints3d": J3.allCases.map { $0.vn.rawValue.rawValue }, "joints2d": Jt.allCases.map { $0.vn.rawValue.rawValue },
            "roles3d": roles3, "roles2d": roles2,
        ]
        guard let rd = try? JSONSerialization.data(withJSONObject: rest), var inner = String(data: rd, encoding: .utf8) else { return nil }
        inner.removeFirst(); inner.removeLast()
        var out = Data("{\"format\":\"skeleton-mantra/1\",\"duration\":\(r4(last)),\(inner),\"frames\":[".utf8)
        for (i, d) in frames.enumerated() { if i > 0 { out.append(0x2C) }; out.append(d) }
        out.append(Data("]}".utf8))
        do { try out.write(to: url); return url } catch { NSLog("[Skeleton] write: %@", "\(error)"); return nil }
    }
}
