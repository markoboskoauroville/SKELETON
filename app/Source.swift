// Source.swift: the camera-source abstraction (Marko, 16.11.2026: "Sony and phone through Iriun or two phones or any
// combination"). Anything that delivers frames can be one of the 1 to 3 views of Skeleton: an AVFoundation camera
// (AVCameraSource, Camera.swift), the Pixel through USB (Manual Camera, its own file), a network or file source.
//
// The contract:
//  - `onPixelBuffer` is called with each frame as a BGRA CVPixelBuffer and its HOST-CLOCK time in seconds
//    (CMTime seconds of the capture timestamp on the Mac's host clock; for a source that has only its own clock,
//    convert to the host clock on arrival, e.g. ProcessInfo.systemUptime, and say so in `clockNote`).
//    It may be called on any queue; the pipeline hops to its own.
//  - `start` is asynchronous and calls `completion(true)` when frames flow, `completion(false)` when it could not start.
//  - `intrinsics` is the lens model the source brings itself (nil = the user calibrates it with the board).
//  - `uniqueID` is stable between launches: calibrations are stored by it.
import Foundation
import CoreVideo
import CoreGraphics
import VideoToolbox

protocol FrameSource: AnyObject {
    var name: String { get }
    var uniqueID: String { get }
    var intrinsics: Intrinsics? { get }
    var formatText: String { get }
    var clockNote: String { get }
    var onPixelBuffer: ((CVPixelBuffer, Double) -> Void)? { get set }
    func start(completion: @escaping (Bool) -> Void)
    func stop()
}

func cgImage(from pb: CVPixelBuffer) -> CGImage? {
    var cg: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
    return cg
}

/// Mean luminance 0...255 of a BGRA buffer, sampled on a coarse grid (used for the flash-based sync).
func meanLuminance(_ pb: CVPixelBuffer) -> Double { lumaStats(pb).mean }

/// Mean and standard deviation of the luminance on a coarse grid: a black or uniform picture has both near zero.
func lumaStats(_ pb: CVPixelBuffer) -> (mean: Double, std: Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return (0, 0) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var sum = 0.0, sum2 = 0.0, n = 0.0
    let sx = max(1, w / 48), sy = max(1, h / 27)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            let o = y * bpr + x * 4
            let l = 0.114 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.299 * Double(p[o + 2])
            sum += l; sum2 += l * l
            n += 1
            x += sx
        }
        y += sy
    }
    guard n > 0 else { return (0, 0) }
    let m = sum / n
    return (m, max(0, sum2 / n - m * m).squareRoot())
}

/// A 48 x 27 luminance signature of the picture (for the static-picture check: a placeholder logo never changes).
func lumaSignature(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    guard w >= 48, h >= 27 else { return [] }
    let p = base.assumingMemoryBound(to: UInt8.self)
    var out: [UInt8] = []
    out.reserveCapacity(48 * 27)
    for gy in 0..<27 {
        let y = min(h - 1, (gy * h + h / 2) / 27)
        for gx in 0..<48 {
            let x = min(w - 1, (gx * w + w / 2) / 48)
            let o = y * bpr + x * 4
            out.append(UInt8(min(255.0, 0.114 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.299 * Double(p[o + 2]))))
        }
    }
    return out
}
