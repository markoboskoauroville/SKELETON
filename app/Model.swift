// Model.swift: joints, poses, limbs, levels and the comparison (angles only, so size and distance do not matter).
import Foundation
import CoreGraphics
import Vision

enum Jt: String, CaseIterable {
    case nose, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
    var vn: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: return .nose
        case .neck: return .neck
        case .leftShoulder: return .leftShoulder
        case .rightShoulder: return .rightShoulder
        case .leftElbow: return .leftElbow
        case .rightElbow: return .rightElbow
        case .leftWrist: return .leftWrist
        case .rightWrist: return .rightWrist
        case .root: return .root
        case .leftHip: return .leftHip
        case .rightHip: return .rightHip
        case .leftKnee: return .leftKnee
        case .rightKnee: return .rightKnee
        case .leftAnkle: return .leftAnkle
        case .rightAnkle: return .rightAnkle
        }
    }
}

/// Points are in "height units": x = normalised x * aspect, y = normalised y from the top, so one unit is the same
/// length in both directions and angles are true angles.
struct Pose {
    var j: [Jt: CGPoint] = [:]
    var aspect: CGFloat = 16.0 / 9.0
    var conf: [Jt: CGFloat] = [:]
    var hipCentre: CGPoint? {
        if let l = j[.leftHip], let r = j[.rightHip] { return CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2) }
        return j[.root]
    }
    var torso: CGFloat? {
        guard let n = j[.neck], let h = hipCentre else { return nil }
        let d = hypot(n.x - h.x, n.y - h.y)
        return d > 0.01 ? d : nil
    }
    var centre: CGPoint {
        guard !j.isEmpty else { return .zero }
        let xs = j.values.map { $0.x }, ys = j.values.map { $0.y }
        return CGPoint(x: xs.reduce(0, +) / CGFloat(xs.count), y: ys.reduce(0, +) / CGFloat(ys.count))
    }
}

enum Limb: CaseIterable {
    case lUpperArm, lForearm, rUpperArm, rForearm, lThigh, lShin, rThigh, rShin, torso, shoulders
    func segment(_ p: Pose) -> (CGPoint, CGPoint)? {
        func s(_ a: Jt, _ b: Jt) -> (CGPoint, CGPoint)? {
            if let x = p.j[a], let y = p.j[b] { return (x, y) }
            return nil
        }
        switch self {
        case .lUpperArm: return s(.leftShoulder, .leftElbow)
        case .lForearm: return s(.leftElbow, .leftWrist)
        case .rUpperArm: return s(.rightShoulder, .rightElbow)
        case .rForearm: return s(.rightElbow, .rightWrist)
        case .lThigh: return s(.leftHip, .leftKnee)
        case .lShin: return s(.leftKnee, .leftAnkle)
        case .rThigh: return s(.rightHip, .rightKnee)
        case .rShin: return s(.rightKnee, .rightAnkle)
        case .torso:
            if let h = p.hipCentre, let n = p.j[.neck] { return (h, n) }
            return nil
        case .shoulders: return s(.rightShoulder, .leftShoulder)
        }
    }
}

struct Bone { let a: Jt; let b: Jt; let limb: Limb? }
let BONES: [Bone] = [
    Bone(a: .nose, b: .neck, limb: nil),
    Bone(a: .neck, b: .leftShoulder, limb: .shoulders), Bone(a: .neck, b: .rightShoulder, limb: .shoulders),
    Bone(a: .leftShoulder, b: .leftElbow, limb: .lUpperArm), Bone(a: .leftElbow, b: .leftWrist, limb: .lForearm),
    Bone(a: .rightShoulder, b: .rightElbow, limb: .rUpperArm), Bone(a: .rightElbow, b: .rightWrist, limb: .rForearm),
    Bone(a: .neck, b: .root, limb: .torso),
    Bone(a: .root, b: .leftHip, limb: .torso), Bone(a: .root, b: .rightHip, limb: .torso),
    Bone(a: .leftHip, b: .leftKnee, limb: .lThigh), Bone(a: .leftKnee, b: .leftAnkle, limb: .lShin),
    Bone(a: .rightHip, b: .rightKnee, limb: .rThigh), Bone(a: .rightKnee, b: .rightAnkle, limb: .rShin),
]

/// One table for the three levels (Marko, 16.11.2026: beginner, middle, professional yogi).
enum Level: Int, CaseIterable {
    case beginner, middle, professional
    var title: String { ["BEGINNER", "MIDDLE", "PROFESSIONAL"][rawValue] }
    var green: Double { [20, 12, 6][rawValue] }       // degrees per segment
    var yellow: Double { [40, 25, 14][rawValue] }
    var hold: TimeInterval { [2, 3, 5][rawValue] }    // seconds of green to count as achieved
}

enum Zone: Int { case green = 0, yellow, red }

func zoneOf(_ d: Double, _ l: Level) -> Zone { d <= l.green ? .green : (d <= l.yellow ? .yellow : .red) }

struct Comparison {
    var diffs: [Limb: Double]
    var worst: Double
    var score: Int
}

private func angleOf(_ s: (CGPoint, CGPoint)) -> Double { Double(atan2(s.1.y - s.0.y, s.1.x - s.0.x)) * 180 / .pi }

func compare(user: Pose, target: Pose, level: Level) -> Comparison? {
    var diffs: [Limb: Double] = [:]
    for l in Limb.allCases {
        guard let a = l.segment(user), let b = l.segment(target) else { continue }
        var d = abs(angleOf(a) - angleOf(b)).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        diffs[l] = d
    }
    guard !diffs.isEmpty, diffs.count >= 4 else { return nil }
    let worst = diffs.values.max() ?? 0
    let mean = diffs.values.map { d -> Double in
        1 - min(1, max(0, (d - level.green * 0.5) / (level.yellow * 1.5)))
    }.reduce(0, +) / Double(diffs.count)
    return Comparison(diffs: diffs, worst: worst, score: Int((mean * 100).rounded()))
}

/// The target, stood where the user stands: scaled by the torso (neck to hip centre), anchored at the hip centre.
func place(_ t: Pose, onto user: Pose?, aspect: CGFloat) -> Pose {
    var out = Pose(aspect: aspect)
    guard let th = t.hipCentre, let tt = t.torso else { return out }
    var anchor = CGPoint(x: aspect / 2, y: 0.6)
    var s: CGFloat = 0.25 / tt
    if let u = user, let uh = u.hipCentre, let ut = u.torso { anchor = uh; s = ut / tt }
    for (k, p) in t.j { out.j[k] = CGPoint(x: anchor.x + (p.x - th.x) * s, y: anchor.y + (p.y - th.y) * s) }
    return out
}

/// Interior angle at b, in degrees.
func jointAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Int {
    let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
    let m = hypot(v1.x, v1.y) * hypot(v2.x, v2.y)
    guard m > 0 else { return 0 }
    let c = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / m))
    return Int((acos(c) * 180 / .pi).rounded())
}

// MARK: saved poses (JSON, joints normalised 0...1 of the picture)

struct SavedPose: Codable {
    var id: String?
    var name: String
    var speak: String?
    var cues: [String]?
    var aspect: Double
    var joints: [String: [Double]]
    var created: String?
}

struct NamedPose {
    var pose: Pose
    var name: String
    var speak: String?
    var cues: [String]
    var thumb: CGImage?
    var id: String? = nil
}

extension SavedPose {
    func named() -> NamedPose {
        var p = Pose(aspect: CGFloat(aspect))
        for (k, v) in joints { if let jt = Jt(rawValue: k), v.count == 2 { p.j[jt] = CGPoint(x: v[0] * aspect, y: v[1]) } }
        return NamedPose(pose: p, name: name, speak: speak, cues: cues ?? [], thumb: nil, id: id)
    }
    static func from(_ n: NamedPose) -> SavedPose {
        var j: [String: [Double]] = [:]
        let a = Double(n.pose.aspect)
        for (k, v) in n.pose.j { j[k.rawValue] = [Double(v.x) / a, Double(v.y)] }
        let f = ISO8601DateFormatter()
        return SavedPose(id: nil, name: n.name, speak: n.speak, cues: n.cues.isEmpty ? nil : n.cues, aspect: a, joints: j, created: f.string(from: Date()))
    }
}
