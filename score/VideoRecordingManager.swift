//
//  VideoRecordingManager.swift
//  score
//
//  Owns the AVCaptureSession used to record the match and the movie file output.
//  Reports capture state (including interruptions such as screen lock, calls or the system
//  stopping the file) so the UI can be honest and the match can resume into a new segment.
//  All state is main-actor isolated; AVFoundation callbacks hop back onto it.
//

@preconcurrency import AVFoundation
import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class VideoRecordingManager: NSObject {
    enum CaptureState: Equatable {
        case idle
        case configuring
        /// Session running, not writing a file.
        case ready
        case recording
        /// Capture stopped by the system; the session resumes on its own when the cause ends.
        case interrupted(String)
        case failed(String)

        var isRecording: Bool { self == .recording }

        /// Short text for the status bar when nothing is being written.
        var userMessage: String? {
            switch self {
            case .interrupted(let reason): return "Recording paused: \(reason)"
            case .failed(let reason): return "Recording stopped: \(reason)"
            case .configuring: return "Starting camera…"
            default: return nil
            }
        }
    }

    private(set) var state: CaptureState = .idle
    var captureSession: AVCaptureSession?
    private(set) var currentVideoURL: URL?

    /// A movie file has actually begun capturing (URL, wall-clock time).
    var onSegmentStarted: ((URL, Date) -> Void)?
    /// A file finished for a reason other than stopRecording() (interruption or system stop).
    var onSegmentInterrupted: ((URL) -> Void)?
    /// A capture interruption ended and the session is running again: start a new segment here.
    var onInterruptionEnded: (() -> Void)?

    private var videoOutput: AVCaptureMovieFileOutput?
    private var cameraDeviceType: CameraDeviceType = .wide
    private var videoQualityPreset: VideoQualityPreset = .hd720p
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observers: [any NSObjectProtocol] = []

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
            state = .configuring
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Log.video.info("🎥 Camera permission granted: \(granted)")
                Task { @MainActor in
                    if granted {
                        self?.configureCaptureSession(completion: completion)
                    } else {
                        self?.fail("Camera access denied")
                    }
                }
            }
        default:
            fail("Camera access denied in Settings")
        }
    }

    private func configureCaptureSession(completion: @escaping @Sendable () -> Void) {
        state = .configuring
        let session = AVCaptureSession()
        // AudioSessionCoordinator owns the app audio session so announcements keep using the speaker
        session.automaticallyConfiguresApplicationAudioSession = false
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
        guard session.canAddOutput(movieOutput) else {
            fail("Cannot add movie output to session")
            return
        }
        session.addOutput(movieOutput)
        videoOutput = movieOutput

        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        observe(session)
        captureSession = session

        // startRunning() blocks, so run it off the main actor, then let the session settle
        // before telling the caller it is safe to start writing to a file.
        Task.detached(priority: .userInitiated) { [weak self] in
            session.startRunning()
            Log.video.info("✅ Capture session running: \(session.isRunning)")
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                guard let self, self.captureSession === session else { return }
                if case .configuring = self.state { self.state = .ready }
            }
            completion()
        }
    }

    private func fail(_ message: String) {
        Log.video.error("❌ \(message)")
        state = .failed(message)
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

    // MARK: - Interruptions

    private func observe(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) {
                [weak self] note in
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                MainActor.assumeIsolated { self?.sessionInterrupted(reason: reason) }
            })
        observers.append(
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.sessionInterruptionEnded() }
            })
        observers.append(
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) {
                [weak self] note in
                let message =
                    (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
                MainActor.assumeIsolated { self?.fail("Camera error: \(message)") }
            })
    }

    private func sessionInterrupted(reason: AVCaptureSession.InterruptionReason?) {
        let text: String
        switch reason {
        case .videoDeviceNotAvailableInBackground: text = "the app is in the background or the screen is locked"
        case .audioDeviceInUseByAnotherClient: text = "the microphone is in use by another app"
        case .videoDeviceInUseByAnotherClient: text = "the camera is in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: text = "another app is in the foreground"
        case .videoDeviceNotAvailableDueToSystemPressure: text = "system pressure"
        default: text = "capture was interrupted"
        }
        Log.video.warning("⚠️ Capture interrupted: \(text)")
        state = .interrupted(text)
    }

    private func sessionInterruptionEnded() {
        Log.video.info("✅ Capture interruption ended")
        if case .interrupted = state { state = .ready }
        onInterruptionEnded?()
    }

    // MARK: - Recording

    func startRecording(to fileURL: URL) {
        guard let output = videoOutput else {
            fail("videoOutput is nil, cannot start recording")
            return
        }
        guard !output.isRecording else {
            Log.video.warning("⚠️ Already recording, ignoring startRecording call")
            return
        }

        if let connection = output.connection(with: .video), let coordinator = rotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                Log.video.debug("📱 Recording orientation set to angle: \(angle)")
            }
        }

        try? FileManager.default.removeItem(at: fileURL)
        output.startRecording(to: fileURL, recordingDelegate: self)
        currentVideoURL = fileURL
        Log.video.info("🎬 Starting recording to: \(fileURL.lastPathComponent)")
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

    private func recordingDidStart(url: URL, at date: Date) {
        state = .recording
        onSegmentStarted?(url, date)
    }

    private func recordingDidFinish(url: URL?, fileURL: URL) {
        if let continuation = stopContinuation {
            // Requested stop
            stopContinuation = nil
            if case .recording = state { state = .ready }
            continuation.resume(returning: url)
            return
        }
        // The system ended the file (interruption, disk full, max duration...)
        if case .interrupted = state {} else { state = .interrupted("recording was stopped by the system") }
        onSegmentInterrupted?(fileURL)
    }

    func stopCaptureSession() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        rotationCoordinator = nil
        guard let session = captureSession else {
            state = .idle
            return
        }
        Task.detached {
            if session.isRunning {
                session.stopRunning()
                Log.video.debug("📹 Capture session stopped - camera/mic released")
            }
        }
        captureSession = nil
        videoOutput = nil
        state = .idle
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VideoRecordingManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
    ) {
        let startedAt = Date()
        Log.video.info(
            "✅ DELEGATE: Recording started to: \(fileURL.lastPathComponent) (\(connections.count) connections)")
        Task { @MainActor in
            self.recordingDidStart(url: fileURL, at: startedAt)
        }
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
            self.recordingDidFinish(url: finishedURL, fileURL: outputFileURL)
        }
    }
}
