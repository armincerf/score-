//
//  CameraPreviewManager.swift
//  score
//
//  Camera preview session for the settings screen: permission, lens switching and quality.
//  Every session mutation (inputs, preset, start/stop) runs in order on one serial queue, and
//  the preview view keeps the picture horizon-level with an AVCaptureDevice.RotationCoordinator.
//

@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit
import os

@MainActor
@Observable
final class CameraPreviewManager: NSObject {
    let session = AVCaptureSession()
    var availableDeviceTypes: [AVCaptureDevice.DeviceType] = []
    /// Camera access is denied or restricted; the session is left without inputs and never started.
    private(set) var permissionDenied = false
    /// The last lens change that failed (lens missing or input rejected); nil once a change succeeds.
    private(set) var errorMessage: String?
    /// The camera feeding `session`; the preview builds its rotation coordinator from it.
    private(set) var currentDevice: AVCaptureDevice?

    /// `startRunning()` blocks, so session work runs here. The queue is serial, so start, stop and
    /// configuration never overlap and run in request order: the last start/stop request wins.
    private let sessionQueue = DispatchQueue(label: "armincerf.score.camera-preview", qos: .userInitiated)
    private var wantsRunning = false
    private var requestedDeviceType: CameraDeviceType = .wide
    private var requestedQuality: VideoQualityPreset?
    /// Bumped per queued input change so a stale completion can't overwrite a newer `currentDevice`.
    private var inputGeneration = 0

    override init() {
        super.init()
        discoverAvailableDevices()
        requestPermissionIfNeeded()
    }

    // MARK: - Available Devices

    private func discoverAvailableDevices() {
        // Check all possible device types
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )

        availableDeviceTypes = discoverySession.devices.map(\.deviceType)
        Log.video.debug("Available device types: \(self.availableDeviceTypes.map { "\($0.rawValue)" })")
    }

    // MARK: - Permissions

    private var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Asks for camera access when undecided. Inputs are only configured once access is granted.
    private func requestPermissionIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                self?.permissionResolved(granted: granted)
            }
        default:
            permissionDenied = true
            Log.video.warning("Camera permission denied")
        }
    }

    private func permissionResolved(granted: Bool) {
        Log.video.info("Camera permission granted: \(granted)")
        permissionDenied = !granted
        guard granted else { return }
        configureSession()
        if wantsRunning {
            enqueueRunning(true)
        }
    }

    // MARK: - Session Management

    func startSession() {
        wantsRunning = true
        // Re-read the status: access may have been changed in Settings since the last check.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        permissionDenied = status == .denied || status == .restricted
        guard status == .authorized else {
            // Not determined: permissionResolved(granted:) starts the session if access is granted.
            Log.video.debug("Preview start waiting for camera access (status \(status.rawValue))")
            return
        }
        if currentDevice == nil {
            configureSession()
        }
        enqueueRunning(true)
    }

    func stopSession() {
        wantsRunning = false
        enqueueRunning(false)
    }

    private func enqueueRunning(_ running: Bool) {
        let session = session
        sessionQueue.async {
            if running, !session.isRunning {
                session.startRunning()
                Log.video.debug("Preview session running: \(session.isRunning)")
            } else if !running, session.isRunning {
                session.stopRunning()
                Log.video.debug("Preview session stopped")
            }
        }
    }

    /// Applies the requested lens, then the requested quality (the preset must suit the lens).
    /// Safe to repeat: both steps are no-ops when already applied.
    private func configureSession() {
        enqueueInput(for: requestedDeviceType)
        if let requestedQuality {
            enqueuePreset(requestedQuality)
        }
    }

    // MARK: - Camera Switching

    func switchCamera(to deviceType: CameraDeviceType) {
        requestedDeviceType = deviceType
        guard isAuthorized else {
            Log.video.debug("No camera access yet; \(deviceType.displayName) is applied once it is granted")
            return
        }
        enqueueInput(for: deviceType)
    }

    private func enqueueInput(for deviceType: CameraDeviceType) {
        guard let device = AVCaptureDevice.default(deviceType.avDeviceType, for: .video, position: .back) else {
            Log.video.warning("Device type \(deviceType.displayName) not available")
            errorMessage = "\(deviceType.displayName) is not available on this device"
            return
        }
        inputGeneration += 1
        let generation = inputGeneration
        let requestedID = device.uniqueID
        let session = session
        sessionQueue.async { [weak self] in
            let active = CameraPreviewManager.replaceVideoInput(in: session, with: device)
            Task { @MainActor in
                self?.videoInputChanged(to: active, requestedID: requestedID, generation: generation)
            }
        }
    }

    private func videoInputChanged(to device: AVCaptureDevice?, requestedID: String, generation: Int) {
        // A newer lens change is queued behind this one; let that one report.
        guard generation == inputGeneration else { return }
        if currentDevice !== device {
            currentDevice = device
        }
        if let device, device.uniqueID == requestedID {
            errorMessage = nil
            Log.video.debug("Preview using \(device.localizedName)")
        } else {
            errorMessage = "Couldn't switch the camera lens"
        }
    }

    /// Runs on `sessionQueue`. Makes `device` the session's video input, keeping the previous
    /// input if the new one can't be added. Returns the camera now feeding the session.
    nonisolated private static func replaceVideoInput(
        in session: AVCaptureSession, with device: AVCaptureDevice
    ) -> AVCaptureDevice? {
        let existing = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
        if existing.contains(where: { $0.device.uniqueID == device.uniqueID }) {
            return device
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in existing {
            session.removeInput(input)
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                return device
            }
            Log.video.error("Session rejected the \(device.localizedName) input")
        } catch {
            Log.video.error("Error creating the \(device.localizedName) input: \(error)")
        }
        // Keep showing the previous lens rather than leaving the preview blank.
        for input in existing where session.canAddInput(input) {
            session.addInput(input)
        }
        return existing.first?.device
    }

    // MARK: - Quality Update

    func updateQuality(_ quality: VideoQualityPreset) {
        requestedQuality = quality
        guard isAuthorized else { return }
        enqueuePreset(quality)
    }

    private func enqueuePreset(_ quality: VideoQualityPreset) {
        let session = session
        let preset = quality.avPreset
        let name = quality.displayName
        sessionQueue.async {
            guard session.sessionPreset != preset else { return }
            guard session.canSetSessionPreset(preset) else {
                Log.video.warning("Preset \(name) not supported")
                return
            }
            session.beginConfiguration()
            session.sessionPreset = preset
            session.commitConfiguration()
            Log.video.info("Updated quality to \(name)")
        }
    }
}

// MARK: - SwiftUI Representable

struct CameraPreviewRepresentable: UIViewRepresentable {
    let manager: CameraPreviewManager

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = manager.session
        view.device = manager.currentDevice
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.session = manager.session
        // Reading the observable `currentDevice` here re-runs this update when the lens changes.
        uiView.device = manager.currentDevice
    }
}

// MARK: - Preview UIView

/// Shows a capture session and keeps it horizon-level: a rotation coordinator for `device` drives
/// the preview connection's rotation; without a device it follows the window scene's orientation.
final class CameraPreviewUIView: UIView {
    var session: AVCaptureSession? {
        didSet {
            guard session !== oldValue else { return }
            previewLayer.session = session
            applyPreviewRotation()
        }
    }

    /// The camera feeding `session`. Each new device gets a new rotation coordinator.
    var device: AVCaptureDevice? {
        didSet {
            guard device !== oldValue else { return }
            makeRotationCoordinator()
        }
    }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass guarantees the backing layer type
        // swiftlint:disable:next force_cast
        return layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPreviewLayer()
    }

    private func setupPreviewLayer() {
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A coordinator reports 0 degrees while its layer is outside a window, so rebuild it on screen.
        guard window != nil else { return }
        makeRotationCoordinator()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Interface rotation resizes the view: keeps the fallback angle current, and catches a
        // preview connection that appeared after the coordinator was made.
        applyPreviewRotation()
    }

    private func makeRotationCoordinator() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        if let device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            // Delivered on the main queue; the hop makes that explicit and reads the latest angle.
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
                [weak self] _, _ in
                Task { @MainActor in
                    self?.applyPreviewRotation()
                }
            }
        }
        applyPreviewRotation()
    }

    private func applyPreviewRotation() {
        guard let connection = previewLayer.connection else { return }
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? interfaceOrientationAngle()
        guard connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        Log.video.debug("Preview rotation set to \(angle) degrees")
    }

    /// Fallback when there is no device to coordinate with: the back camera's sensor is
    /// landscape-right native, so rotate by the interface orientation.
    private func interfaceOrientationAngle() -> CGFloat {
        switch window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }
}
