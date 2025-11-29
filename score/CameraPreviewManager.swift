//
//  CameraPreviewManager.swift
//  score
//
//  Manages camera preview session with lens switching and quality adjustment
//

import Foundation
@preconcurrency import AVFoundation
import UIKit
import Combine

@MainActor
class CameraPreviewManager: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var availableDeviceTypes: [AVCaptureDevice.DeviceType] = []

    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private var isSessionRunning = false

    override init() {
        super.init()
        checkPermissions()
        discoverAvailableDevices()
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
            .builtInTelephotoCamera
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )

        availableDeviceTypes = discoverySession.devices.map { $0.deviceType }
        print("[CameraPreview] Available device types: \(availableDeviceTypes.map { "\($0.rawValue)" })")
    }

    // MARK: - Permissions

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        default:
            print("[CameraPreview] Camera permission denied")
        }
    }

    // MARK: - Session Management

    func startSession() {
        guard !isSessionRunning else { return }

        let sessionToStart = session
        Task.detached {
            sessionToStart.startRunning()
        }
        isSessionRunning = true
    }

    func stopSession() {
        guard isSessionRunning else { return }

        let sessionToStop = session
        Task.detached {
            sessionToStop.stopRunning()
        }
        isSessionRunning = false
    }

    // MARK: - Camera Switching

    func switchCamera(to deviceType: CameraDeviceType) {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [deviceType.avDeviceType],
            mediaType: .video,
            position: .back
        )

        guard let device = discoverySession.devices.first else {
            print("[CameraPreview] Device type \(deviceType.displayName) not available")
            return
        }

        session.beginConfiguration()

        // Remove existing input
        if let currentInput = currentInput {
            session.removeInput(currentInput)
        }

        // Add new input
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                currentDevice = device
                print("[CameraPreview] Switched to \(deviceType.displayName)")
            }
        } catch {
            print("[CameraPreview] Error switching camera: \(error)")
        }

        session.commitConfiguration()
    }

    // MARK: - Quality Update

    func updateQuality(_ quality: VideoQualityPreset) {
        guard session.canSetSessionPreset(quality.avPreset) else {
            print("[CameraPreview] Preset \(quality.displayName) not supported")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = quality.avPreset
        session.commitConfiguration()

        print("[CameraPreview] Updated quality to \(quality.displayName)")
    }
}

// MARK: - SwiftUI Representable

import SwiftUI

struct CameraPreviewRepresentable: UIViewRepresentable {
    @ObservedObject var manager: CameraPreviewManager

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.session = manager.session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.session = manager.session
    }
}

// MARK: - Preview UIView

class CameraPreviewUIView: UIView {
    var session: AVCaptureSession? {
        didSet {
            updatePreviewLayer()
        }
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
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

    private func updatePreviewLayer() {
        previewLayer.session = session
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
