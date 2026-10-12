// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import UIKit

@main
struct CameraPhotoSupportTests {
  static func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
  }

  static func rgb(_ image: CGImage, x: Int, y: Int) -> [Int] {
    let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { data in
      let context = CGContext(data: data.baseAddress, width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes.prefix(3).map(Int.init)
  }

  static func main() {
    for language in ["zh", "zh-Hans", "zh-CN", "zh-Hant", "zh-TW"] {
      let labels = CameraLabels(language: language)
      check(labels.retake == "重拍" && labels.usePhoto == "使用照片", "Chinese review buttons: \(language)")
    }
    check(CameraLabels(language: "en").usePhoto == "Use photo", "English fallback")
    check(CameraPhotoSupport.orientation(for: .landscapeLeft, fallback: .portrait) == .landscapeRight,
      "Left landscape capture")
    check(CameraPhotoSupport.orientation(for: .landscapeRight, fallback: .portrait) == .landscapeLeft,
      "Right landscape capture")
    for flat in [UIDeviceOrientation.faceUp, .faceDown, .unknown] {
      check(CameraPhotoSupport.orientation(for: flat, fallback: .landscapeLeft) == .landscapeLeft,
        "Flat phone preserves capture orientation")
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let colors: [UIColor] = [.red, .green, .blue, .yellow]
    let source = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { ctx in
      for (index, color) in colors.enumerated() {
        ctx.cgContext.setFillColor(color.cgColor)
        ctx.cgContext.fill(CGRect(x: (index % 2) * 40, y: (index / 2) * 20, width: 40, height: 20))
      }
    }.cgImage!
    let expectedColors = [(10, 10), (70, 10), (10, 30), (70, 30)].map { rgb(source, x: $0.0, y: $0.1) }
    let cases: [(UIImage.Orientation, [Int], Bool)] = [
      (.up, [0, 1, 2, 3], false), (.upMirrored, [1, 0, 3, 2], false),
      (.down, [3, 2, 1, 0], false), (.downMirrored, [2, 3, 0, 1], false),
      (.left, [1, 3, 0, 2], true), (.leftMirrored, [0, 2, 1, 3], true),
      (.right, [2, 0, 3, 1], true), (.rightMirrored, [3, 1, 2, 0], true),
    ]
    for (orientation, corners, swapsDimensions) in cases {
      let image = UIImage(cgImage: source, scale: 1, orientation: orientation)
      let jpeg = CameraPhotoSupport.jpeg(from: image)!
      let decoded = UIImage(data: jpeg)!
      let pixels = decoded.cgImage!
      check(decoded.imageOrientation == .up, "JPEG orientation must be baked")
      check(pixels.width == (swapsDimensions ? 40 : 80), "Oriented width: \(orientation)")
      check(pixels.height == (swapsDimensions ? 80 : 40), "Oriented height: \(orientation)")
      let points = [(10, 10), (pixels.width - 10, 10), (10, pixels.height - 10),
        (pixels.width - 10, pixels.height - 10)]
      for (index, point) in points.enumerated() {
        let actual = rgb(pixels, x: point.0, y: point.1)
        let expected = expectedColors[corners[index]]
        check(zip(actual, expected).allSatisfy { pair in abs(pair.0 - pair.1) < 20 },
          "Oriented corner: \(orientation), \(index)")
      }
      let again = UIImage(data: CameraPhotoSupport.jpeg(from: decoded)!)!
      check(again.size == decoded.size && again.imageOrientation == .up, "No double rotation")
      print("PASS JPEG orientation \(orientation.rawValue)")
    }
    print("PASS native Chinese controls, both landscape directions and flat-phone fallback")
  }
}
