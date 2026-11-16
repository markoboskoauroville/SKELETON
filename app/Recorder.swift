// Recorder.swift: the skeleton recording (format skeleton-mantra/1, docs/skel-format.md): 2D + 3D per frame, no video.
// 2D is always the raw camera picture (never mirrored); 3D is Vision's own, or triangulated from several calibrated cameras.
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
    var rawName: String { vn.rawValue.rawValue }
}

func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

struct V3Obs {
    var p3: [String: [Double]]
    var r3: [String: [Double]]
    var h: Double
}

func extract3D(_ o: VNHumanBodyPose3DObservation) -> V3Obs {
    var p3: [String: [Double]] = [:], r3: [String: [Double]] = [:]
    for j in J3.allCases {
        guard let pt = try? o.recognizedPoint(j.vn) else { continue }
        let m = pt.position
        p3[j.rawName] = [r4(Double(m.columns.3.x)), r4(Double(m.columns.3.y)), r4(Double(m.columns.3.z))]
        let l = pt.localPosition
        var flat: [Double] = []
        for row in 0..<4 { for col in 0..<4 { flat.append(r4(Double(l[col][row]))) } }
        r3[j.rawName] = flat
    }
    return V3Obs(p3: p3, r3: r3, h: r4(Double(o.bodyHeight)))
}

/// A triangulated body: joints in camera A's frame (metres, x right, y down, z forward), converted for the file.
struct TriResult {
    var joints: [Jt: V3]
    var quality: Int
    var meanErrPx: Double
    var views: Int
    var viewQuality: [Int: Int] = [:]      // per camera (slot index): 0...100

    /// Root-relative, y up, x = the subject's left when he faces the camera, z toward the camera, under the 3D joint names.
    func p3() -> [String: [Double]]? {
        func conv(_ v: V3) -> V3 { V3(v.x, -v.y, -v.z) }
        var hip: V3
        if let l = joints[.leftHip], let r = joints[.rightHip] { hip = (l + r) / 2 } else if let r = joints[.root] { hip = r } else { return nil }
        func rel(_ j: Jt) -> [Double]? { joints[j].map { let c = conv($0 - hip); return [r4(c.x), r4(c.y), r4(c.z)] } }
        var out: [String: [Double]] = [:]
        out[J3.root.rawName] = [0, 0, 0]
        func put(_ j3: J3, _ j: Jt) { if let v = rel(j) { out[j3.rawName] = v } }
        put(.centerShoulder, .neck); put(.centerHead, .nose)
        put(.leftShoulder, .leftShoulder); put(.rightShoulder, .rightShoulder)
        put(.leftElbow, .leftElbow); put(.rightElbow, .rightElbow); put(.leftWrist, .leftWrist); put(.rightWrist, .rightWrist)
        put(.leftHip, .leftHip); put(.rightHip, .rightHip); put(.leftKnee, .leftKnee); put(.rightKnee, .rightKnee)
        put(.leftAnkle, .leftAnkle); put(.rightAnkle, .rightAnkle)
        if let n = out[J3.centerShoulder.rawName] { out[J3.spine.rawName] = n.map { r4($0 / 2) } }
        if let n = out[J3.centerShoulder.rawName], let h = out[J3.centerHead.rawName] {
            out[J3.topHead.rawName] = [r4(h[0] + (h[0] - n[0]) * 0.55), r4(h[1] + (h[1] - n[1]) * 0.55), r4(h[2] + (h[2] - n[2]) * 0.55)]
        }
        return out.count >= 8 ? out : nil
    }
}

final class Recorder {
    let camera: String
    let mirror: Bool
    var cameras: [[String: Any]]?
    var source = "vision3d"
    private var frames: [Data] = []
    private var first: Double?
    private(set) var last = 0.0
    private var width = 0, height = 0
    let started = Date()

    init(camera: String, mirror: Bool) { self.camera = camera; self.mirror = mirror }

    var count: Int { frames.count }
    var seconds: Double { Date().timeIntervalSince(started) }

    /// `raw` are Vision's poses of the primary camera (unmirrored); the primary person has the longest torso.
    func add(time: Double, raw: [Pose], size: CGSize, v3: V3Obs?, tri: TriResult?) {
        if first == nil { first = time }
        let t = time - (first ?? time)
        last = t; width = Int(size.width); height = Int(size.height)
        var f: [String: Any] = ["t": r4(t)]
        var p2: [String: [Double]] = [:]
        if let p = raw.max(by: { ($0.torso ?? 0) < ($1.torso ?? 0) }) {
            for (jt, pt) in p.j {
                p2[jt.vn.rawValue.rawValue] = [r4(Double(pt.x / p.aspect)), r4(Double(pt.y)), r4(Double(p.conf[jt] ?? 1))]
            }
        }
        f["p2"] = p2
        if let tri = tri, let p3 = tri.p3() {
            f["p3"] = p3; f["s"] = "tri"; f["q"] = tri.quality
            f["h"] = v3.map { $0.h } ?? NSNull()
        } else if let v = v3, !v.p3.isEmpty {
            f["p3"] = v.p3
            if !v.r3.isEmpty { f["r3"] = v.r3 }
            f["h"] = v.h; f["s"] = "vision3d"
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
        for j in J3.allCases { roles3[j.rawName] = j.rawValue }
        for j in Jt.allCases { roles2[j.vn.rawValue.rawValue] = j.rawValue }
        var rest: [String: Any] = [
            "fps": r4(fps), "camera": camera, "width": width, "height": height, "mirror": mirror, "source": source,
            "joints3d": J3.allCases.map { $0.rawName }, "joints2d": Jt.allCases.map { $0.vn.rawValue.rawValue },
            "roles3d": roles3, "roles2d": roles2,
        ]
        if let c = cameras { rest["cameras"] = c }
        guard let rd = try? JSONSerialization.data(withJSONObject: rest), var inner = String(data: rd, encoding: .utf8) else { return nil }
        inner.removeFirst(); inner.removeLast()
        var out = Data("{\"format\":\"skeleton-mantra/1\",\"duration\":\(r4(last)),\(inner),\"frames\":[".utf8)
        for (i, d) in frames.enumerated() { if i > 0 { out.append(0x2C) }; out.append(d) }
        out.append(Data("]}".utf8))
        do { try out.write(to: url); return url } catch { NSLog("[Skeleton] write: %@", "\(error)"); return nil }
    }
}
