// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import UIKit

struct CameraLabels {
  let cancel: String
  let capture: String
  let switchCamera: String
  let retake: String
  let usePhoto: String
  let permission: String
  let failed: String

  init(language: String) {
    let language = language.lowercased()
    if language.hasPrefix("zh") {
      let traditional = language.contains("hant") || language.contains("tw") || language.contains("hk")
      cancel = "取消"
      capture = "拍照"
      switchCamera = traditional ? "切換鏡頭" : "切换摄像头"
      retake = "重拍"
      usePhoto = "使用照片"
      permission = traditional ? "請在設定中允許使用相機" : "请在设置中允许使用相机"
      failed = traditional ? "無法拍照，請重試" : "无法拍照，请重试"
    } else {
      cancel = "Cancel"
      capture = "Take photo"
      switchCamera = "Switch camera"
      retake = "Retake"
      usePhoto = "Use photo"
      permission = "Allow camera access in Settings"
      failed = "Unable to take photo. Please try again."
    }
  }
}

enum CameraPhotoSupport {
  static func orientation(for device: UIDeviceOrientation,
                          fallback: AVCaptureVideoOrientation) -> AVCaptureVideoOrientation {
    switch device {
    case .landscapeLeft: return .landscapeRight
    case .landscapeRight: return .landscapeLeft
    case .portrait: return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    default: return fallback
    }
  }

  static func jpeg(from image: UIImage) -> Data? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
    return normalized.jpegData(compressionQuality: 0.95)
  }
}
