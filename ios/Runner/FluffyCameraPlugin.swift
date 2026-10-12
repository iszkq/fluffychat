// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Flutter
import UIKit

/// Avoids UIImagePickerController's system review screen and its result callback.
/// Keep ownership in the engine so rotating/rebuilding a Flutter chat cannot
/// discard a pending photo. Return only after the native controller is dismissed.
final class FluffyCameraPlugin: NSObject, FlutterPlugin {
  private var pendingResult: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "im.fluffychat/ios_camera", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(FluffyCameraPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "capturePhoto" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard pendingResult == nil else {
      result(FlutterError(code: "camera_busy", message: "Camera is already open", details: nil))
      return
    }
    pendingResult = result
    let args = call.arguments as? [String: Any]
    let labels = CameraLabels(language: args?["languageCode"] as? String ?? "en")
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      presentCamera(labels)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted {
            self.presentCamera(labels)
          } else {
            self.finish(FlutterError(code: "camera_access_denied", message: labels.permission, details: nil))
          }
        }
      }
    default:
      finish(FlutterError(code: "camera_access_denied", message: labels.permission, details: nil))
    }
  }

  private func presentCamera(_ labels: CameraLabels) {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard var presenter = scenes.filter({ $0.activationState == .foregroundActive })
      .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
      finish(FlutterError(code: "camera_unavailable", message: labels.failed, details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let camera = FluffyCameraController(labels: labels)
    camera.modalPresentationStyle = .fullScreen
    camera.completion = { [weak self, weak camera] value in
      camera?.dismiss(animated: true) { self?.finish(value) }
    }
    presenter.present(camera, animated: true)
  }

  private func finish(_ value: Any?) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }
}

private final class FluffyCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
  var completion: ((Any?) -> Void)?
  private let labels: CameraLabels
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "im.fluffychat.camera.session")
  private let output = AVCapturePhotoOutput()
  private var input: AVCaptureDeviceInput?
  private var preview: AVCaptureVideoPreviewLayer!
  private let review = UIImageView()
  private let leftButton = UIButton(type: .system)
  private let shutter = UIButton(type: .system)
  private let rightButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .large)
  private var photoData: Data?
  private var capturing = false
  private var finished = false
  private var lastOrientation: AVCaptureVideoOrientation = .portrait

  private enum Metrics {
    static let inset: CGFloat = 16
    static let buttonHeight: CGFloat = 56
    static let shutterSize: CGFloat = 48
  }

  init(labels: CameraLabels) {
    self.labels = labels
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
  override var prefersStatusBarHidden: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    review.contentMode = .scaleAspectFit
    review.backgroundColor = .black
    review.isHidden = true
    review.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(review)

    let toolbar = UIStackView(arrangedSubviews: [leftButton, shutter, rightButton])
    toolbar.axis = .horizontal
    toolbar.distribution = .equalSpacing
    toolbar.alignment = .center
    toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.75)
    toolbar.isLayoutMarginsRelativeArrangement = true
    toolbar.layoutMargins = UIEdgeInsets(top: 0, left: Metrics.inset, bottom: 0, right: Metrics.inset)
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toolbar)
    for button in [leftButton, shutter, rightButton] {
      button.tintColor = .white
      button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
      button.titleLabel?.adjustsFontForContentSizeCategory = true
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.buttonHeight).isActive = true
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.buttonHeight).isActive = true
    }
    shutter.setImage(UIImage(systemName: "circle.inset.filled", withConfiguration:
      UIImage.SymbolConfiguration(pointSize: Metrics.shutterSize)), for: .normal)
    shutter.accessibilityLabel = labels.capture
    leftButton.addTarget(self, action: #selector(leftAction), for: .touchUpInside)
    shutter.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)
    rightButton.addTarget(self, action: #selector(rightAction), for: .touchUpInside)
    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.buttonHeight),
      review.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      review.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      review.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      review.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    updateControls()
    setBusy(true)
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(self, selector: #selector(deviceRotated),
      name: UIDevice.orientationDidChangeNotification, object: nil)
    deviceRotated()
    sessionQueue.async {
      do {
        self.session.beginConfiguration()
        self.session.sessionPreset = .photo
        try self.configureInput(position: .back)
        guard self.session.canAddOutput(self.output) else { throw CameraFailure.unavailable }
        self.session.addOutput(self.output)
        self.session.commitConfiguration()
        self.session.startRunning()
        DispatchQueue.main.async { self.setBusy(false); self.view.setNeedsLayout() }
      } catch {
        self.session.commitConfiguration()
        DispatchQueue.main.async { self.fail(error) }
      }
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    UIDevice.current.endGeneratingDeviceOrientationNotifications()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview.frame = view.bounds
    if let connection = preview.connection, connection.isVideoOrientationSupported {
      switch view.window?.windowScene?.interfaceOrientation {
      case .landscapeLeft: connection.videoOrientation = .landscapeLeft
      case .landscapeRight: connection.videoOrientation = .landscapeRight
      case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
      default: connection.videoOrientation = .portrait
      }
    }
  }

  @objc private func deviceRotated() {
    // Physical left/right are reversed relative to capture coordinates. Keep
    // the last valid value when a phone is flat or its orientation is unknown.
    lastOrientation = CameraPhotoSupport.orientation(
      for: UIDevice.current.orientation, fallback: lastOrientation)
  }

  private func configureInput(position: AVCaptureDevice.Position) throws {
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    else { throw CameraFailure.unavailable }
    let replacement = try AVCaptureDeviceInput(device: device)
    let previous = input
    if let previous = previous { session.removeInput(previous) }
    guard session.canAddInput(replacement) else {
      if let previous = previous { session.addInput(previous) }
      throw CameraFailure.unavailable
    }
    session.addInput(replacement)
    input = replacement
  }

  private func setBusy(_ busy: Bool) {
    capturing = busy
    leftButton.isEnabled = !busy
    shutter.isEnabled = !busy
    rightButton.isEnabled = !busy
    if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
  }

  private func updateControls() {
    let reviewing = photoData != nil
    review.isHidden = !reviewing
    shutter.isHidden = reviewing
    leftButton.setTitle(reviewing ? labels.retake : labels.cancel, for: .normal)
    rightButton.setTitle(reviewing ? labels.usePhoto : nil, for: .normal)
    rightButton.setImage(reviewing ? nil : UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
    rightButton.accessibilityLabel = reviewing ? labels.usePhoto : labels.switchCamera
  }

  @objc private func leftAction() {
    guard !capturing else { return }
    if photoData != nil {
      photoData = nil
      review.image = nil
      updateControls()
      sessionQueue.async { self.session.startRunning() }
    } else { complete(nil) }
  }

  @objc private func rightAction() {
    guard !capturing else { return }
    if let data = photoData {
      setBusy(true)
      sessionQueue.async {
        do {
          let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-\(UUID().uuidString).jpg")
          try data.write(to: url, options: .atomic)
          DispatchQueue.main.async { self.complete(url.path) }
        } catch { DispatchQueue.main.async { self.fail(error) } }
      }
    } else {
      setBusy(true)
      sessionQueue.async {
        self.session.beginConfiguration()
        do {
          try self.configureInput(position: self.input?.device.position == .back ? .front : .back)
          self.session.commitConfiguration()
          DispatchQueue.main.async { self.setBusy(false); self.view.setNeedsLayout() }
        } catch {
          self.session.commitConfiguration()
          DispatchQueue.main.async { self.fail(error) }
        }
      }
    }
  }

  @objc private func takePhoto() {
    guard !capturing, photoData == nil else { return }
    setBusy(true)
    deviceRotated()
    let orientation = lastOrientation
    sessionQueue.async {
      if let connection = self.output.connection(with: .video), connection.isVideoOrientationSupported {
        connection.videoOrientation = orientation
      }
      // Request JPEG explicitly; never pass HEIC to Flutter's image decoder.
      let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
      self.output.capturePhoto(with: settings, delegate: self)
    }
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                   error: Error?) {
    if let error = error {
      DispatchQueue.main.async { self.fail(error) }
      return
    }
    // UIKit draws UIImage's EXIF orientation into the actual pixels. Native
    // review, Flutter preview and upload all receive this exact JPEG.
    guard let raw = photo.fileDataRepresentation(), let image = UIImage(data: raw) else {
      DispatchQueue.main.async { self.fail(CameraFailure.unavailable) }
      return
    }
    guard let jpeg = CameraPhotoSupport.jpeg(from: image), let normalized = UIImage(data: jpeg) else {
      DispatchQueue.main.async { self.fail(CameraFailure.unavailable) }
      return
    }
    sessionQueue.async { self.session.stopRunning() }
    DispatchQueue.main.async {
      self.photoData = jpeg
      self.review.image = normalized
      self.setBusy(false)
      self.updateControls()
    }
  }

  private func fail(_ error: Error) {
    complete(FlutterError(code: "camera_capture_failed", message: labels.failed,
      details: String(describing: error)))
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                   error: Error?) {
    if let error = error { DispatchQueue.main.async { self.fail(error) } }
  }

  private func complete(_ value: Any?) {
    guard !finished else { return }
    finished = true
    sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    completion?(value)
  }

  private enum CameraFailure: Error { case unavailable }
}
