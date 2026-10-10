//
//  VideoRecordingManager.swift
//  score
//
//  Owns the AVCaptureSession used to record the match and the movie file output.
//  All state is main-actor isolated; AVFoundation delegate callbacks hop back onto it.
//

@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class VideoRecordingManager: NSObject {
    var error: String?
    var captureSession: AVCaptureSession?
    var currentVideoURL: URL?

    private var videoOutput: AVCaptureMovieFileOutput?
    private var cameraDeviceType: CameraDeviceType = .wide
    private var videoQualityPreset: VideoQualityPreset = .hd720p

    /// Resumed by the AVCaptureFileOutputRecordingDelegate once the movie file is finalized.
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    nonisolated deinit {
        Log.video.debug("🧹 VideoRecordingManager deallocated")
    }

    func configure(deviceType: CameraDeviceType, quality: VideoQualityPreset) {
        cameraDeviceType = deviceType
        videoQualityPreset = quality
        Log.video.debug("🎥 Configured with deviceType: \(deviceType.displayName), quality: \(quality.displayName)")
    }

    // MARK: - Capture session

    func setupCaptureSession(completion: @escaping @Sendable () -> Void) {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        Log.video.debug("🎥 Camera authorization status: \(authStatus.rawValue)")

        switch authStatus {
        case .authorized:
            configureCaptureSession(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Log.video.info("🎥 Camera permission granted: \(granted)")
                guard granted else { return }
                Task { @MainActor in
                    self?.configureCaptureSession(completion: completion)
                }
            }
        default:
            Log.video.error("❌ Camera access denied (status: \(authStatus.rawValue))")
            error = "Camera access denied"
        }
    }

    private func configureCaptureSession(completion: @escaping @Sendable () -> Void) {
        let session = AVCaptureSession()
        applyPreset(to: session)

        guard let device = preferredCameraDevice() else {
            fail("Failed to access camera device")
            return
        }
        guard let videoInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(videoInput) else {
            fail("Cannot add video input to session")
            return
        }
        session.addInput(videoInput)
        addAudioInput(to: session)

        let movieOutput = AVCaptureMovieFileOutput()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            videoOutput = movieOutput
        } else {
            Log.video.error("❌ Cannot add movie output to session")
        }

        captureSession = session

        // startRunning() blocks, so run it off the main actor, then let the session settle
        // before telling the caller it is safe to start writing to a file.
        Task.detached(priority: .userInitiated) {
            session.startRunning()
            Log.video.info("✅ Capture session running: \(session.isRunning)")
            try? await Task.sleep(for: .milliseconds(500))
            completion()
        }
    }

    private func fail(_ message: String) {
        Log.video.error("❌ \(message)")
        error = message
    }

    private func applyPreset(to session: AVCaptureSession) {
        if session.canSetSessionPreset(videoQualityPreset.avPreset) {
            session.sessionPreset = videoQualityPreset.avPreset
        } else {
            session.sessionPreset = .hd1280x720
            Log.video.warning("🎥 Preset \(self.videoQualityPreset.displayName) not supported, falling back to HD 720p")
        }
    }

    private func addAudioInput(to session: AVCaptureSession) {
        guard let audioDevice = AVCaptureDevice.default(for: .audio),
            let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
            session.canAddInput(audioInput)
        else {
            Log.video.warning("⚠️ No usable audio input - recording video only")
            return
        }
        session.addInput(audioInput)
    }

    private func preferredCameraDevice() -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [cameraDeviceType.avDeviceType],
            mediaType: .video,
            position: .back
        )
        if let preferredDevice = discoverySession.devices.first {
            return preferredDevice
        }
        Log.video.warning(
            "🎥 Preferred camera \(self.cameraDeviceType.displayName) not available, falling back to wide angle")
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    // MARK: - Recording

    func startRecording(to fileURL: URL) {
        guard let output = videoOutput else {
            Log.video.error("❌ videoOutput is nil, cannot start recording")
            return
        }
        guard !output.isRecording else {
            Log.video.warning("⚠️ Already recording, ignoring startRecording call")
            return
        }

        if let connection = output.connection(with: .video) {
            let rotationAngle = MediaExportService.VideoOrientation.current().rotationAngle
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
                Log.video.debug("📱 Recording orientation set to angle: \(rotationAngle)")
            }
        }

        output.startRecording(to: fileURL, recordingDelegate: self)
        currentVideoURL = fileURL
        Log.video.info("✅ Started recording to: \(fileURL.lastPathComponent)")
    }

    /// Stops the movie file output and suspends until AVFoundation reports the file is finished.
    /// Returns the finalized file URL, or nil if nothing was recording or writing failed.
    func stopRecording() async -> URL? {
        guard let output = videoOutput, output.isRecording else { return nil }
        if let pending = stopContinuation {
            // A stop is already in flight; don't leak the earlier continuation.
            stopContinuation = nil
            pending.resume(returning: nil)
        }
        Log.video.debug("Stopping recording, waiting for file to finalize")
        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
            output.stopRecording()
        }
    }

    private func recordingDidFinish(url: URL?) {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume(returning: url)
    }

    func stopCaptureSession() {
        guard let session = captureSession else { return }
        Task.detached {
            if session.isRunning {
                session.stopRunning()
                Log.video.debug("📹 Capture session stopped - camera/mic released")
            }
        }
        captureSession = nil
        videoOutput = nil
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VideoRecordingManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
    ) {
        Log.video.info(
            "✅ DELEGATE: Recording started to: \(fileURL.lastPathComponent) (\(connections.count) connections)")
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // AVFoundation reports some benign conditions (e.g. max duration reached) as errors
        // while still writing a playable file; honour its "successfully finished" flag.
        var finishedURL: URL? = outputFileURL
        if let error {
            let info = (error as NSError).userInfo
            let stillUsable = (info[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            Log.video.error(
                "❌ DELEGATE: Recording error (\((error as NSError).code)): \(error.localizedDescription); file usable: \(stillUsable)"
            )
            if !stillUsable { finishedURL = nil }
        } else {
            Log.video.info("✅ DELEGATE: Recording finished: \(outputFileURL.lastPathComponent)")
        }
        Task { @MainActor in
            self.recordingDidFinish(url: finishedURL)
        }
    }
}
