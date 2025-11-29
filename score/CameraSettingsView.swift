//
//  CameraSettingsView.swift
//  score
//
//  Camera configuration with live preview, lens selection, and quality settings
//

import SwiftUI
import AVFoundation
import SwiftData

struct CameraSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var cameraManager = CameraPreviewManager()
    @State private var preferences: UserPreferences?
    @State private var cameraEnabled: Bool = true
    @State private var selectedDeviceType: CameraDeviceType = .wide
    @State private var selectedQuality: VideoQualityPreset = .hd720p

    private var preferencesService: UserPreferencesService {
        UserPreferencesService(modelContext: modelContext)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Camera Enable/Disable Toggle
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $cameraEnabled) {
                            HStack(spacing: 12) {
                                Image(systemName: cameraEnabled ? "video.fill" : "video.slash.fill")
                                    .font(.title2)
                                    .foregroundColor(cameraEnabled ? .green : .gray)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Video Recording")
                                        .font(.headline)
                                    Text(cameraEnabled ? "Recording enabled for matches" : "Scoring only, no video recording")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .green))
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                        .onChange(of: cameraEnabled) { _, newValue in
                            preferencesService.setCameraEnabled(newValue)
                            if !newValue {
                                cameraManager.stopSession()
                            } else {
                                cameraManager.startSession()
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Live Camera Preview
                    ZStack {
                        if cameraEnabled {
                            CameraPreviewRepresentable(manager: cameraManager)
                                .frame(height: 300)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                        } else {
                            // Disabled state
                            VStack(spacing: 16) {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 60))
                                    .foregroundColor(.gray)
                                Text("Camera Disabled")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                Text("Enable video recording to preview camera")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                        }

                        // Preview overlay info (only when enabled)
                        if cameraEnabled {
                            VStack {
                                HStack {
                                    Text(selectedDeviceType.displayName)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(8)
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(12)
                        }
                    }
                    .padding(.horizontal)

                    // Camera Lens Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Camera Lens", systemImage: "camera.circle.fill")
                            .font(.headline)
                            .padding(.horizontal)
                            .foregroundColor(cameraEnabled ? .primary : .secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(CameraDeviceType.allAvailableCases(for: cameraManager.availableDeviceTypes), id: \.self) { deviceType in
                                    CameraLensCard(
                                        deviceType: deviceType,
                                        isSelected: selectedDeviceType == deviceType
                                    ) {
                                        selectedDeviceType = deviceType
                                        cameraManager.switchCamera(to: deviceType)
                                        savePreferences()
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .disabled(!cameraEnabled)
                        .opacity(cameraEnabled ? 1.0 : 0.5)
                    }

                    // Video Quality Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Video Quality", systemImage: "video.circle.fill")
                            .font(.headline)
                            .padding(.horizontal)
                            .foregroundColor(cameraEnabled ? .primary : .secondary)

                        VStack(spacing: 8) {
                            ForEach(VideoQualityPreset.allCases, id: \.self) { quality in
                                QualityPresetRow(
                                    quality: quality,
                                    isSelected: selectedQuality == quality
                                ) {
                                    selectedQuality = quality
                                    cameraManager.updateQuality(quality)
                                    savePreferences()
                                }
                            }
                        }
                        .padding(.horizontal)
                        .disabled(!cameraEnabled)
                        .opacity(cameraEnabled ? 1.0 : 0.5)
                    }

                    // Info Section
                    VStack(alignment: .leading, spacing: 8) {
                        Label("About Camera Settings", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Choose the camera lens and quality that best suits your recording environment. Higher quality settings may produce larger files but better video clarity.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadPreferences()
                if cameraEnabled {
                    cameraManager.startSession()
                }
            }
            .onDisappear {
                cameraManager.stopSession()
            }
        }
    }

    private func loadPreferences() {
        preferences = preferencesService.getPreferences()
        if let prefs = preferences {
            cameraEnabled = prefs.cameraEnabled
            selectedDeviceType = CameraDeviceType.from(string: prefs.cameraDeviceType ?? "wide")
            selectedQuality = VideoQualityPreset.from(string: prefs.videoQualityPreset ?? "hd720p")
            if cameraEnabled {
                cameraManager.switchCamera(to: selectedDeviceType)
                cameraManager.updateQuality(selectedQuality)
            }
        }
    }

    private func savePreferences() {
        guard let prefs = preferences else { return }
        prefs.cameraDeviceType = selectedDeviceType.rawValue
        prefs.videoQualityPreset = selectedQuality.rawValue
        prefs.lastUpdated = Date()

        do {
            try modelContext.save()
            print("[CameraSettings] Saved: \(selectedDeviceType.displayName), \(selectedQuality.displayName)")
        } catch {
            print("[CameraSettings] Error saving: \(error)")
        }
    }
}

// MARK: - Camera Lens Card

struct CameraLensCard: View {
    let deviceType: CameraDeviceType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: deviceType.icon)
                    .font(.title2)
                    .foregroundColor(isSelected ? .white : .primary)

                Text(deviceType.shortName)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .white : .primary)

                if !deviceType.isAvailable {
                    Text("Not Available")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 100, height: 90)
            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
            .cornerRadius(12)
        }
        .disabled(!deviceType.isAvailable)
        .opacity(deviceType.isAvailable ? 1.0 : 0.5)
    }
}

// MARK: - Quality Preset Row

struct QualityPresetRow: View {
    let quality: VideoQualityPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(quality.displayName)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(quality.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding()
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Camera Device Type Enum

enum CameraDeviceType: String, CaseIterable {
    case wide = "wide"
    case ultraWide = "ultraWide"
    case telephoto = "telephoto"
    case dual = "dual"
    case triple = "triple"

    var displayName: String {
        switch self {
        case .wide: return "Wide Angle"
        case .ultraWide: return "Ultra Wide"
        case .telephoto: return "Telephoto"
        case .dual: return "Dual Camera"
        case .triple: return "Triple Camera"
        }
    }

    var shortName: String {
        switch self {
        case .wide: return "Wide"
        case .ultraWide: return "Ultra Wide"
        case .telephoto: return "Telephoto"
        case .dual: return "Dual"
        case .triple: return "Triple"
        }
    }

    var icon: String {
        switch self {
        case .wide: return "camera.fill"
        case .ultraWide: return "camera.metering.multispot"
        case .telephoto: return "camera.aperture"
        case .dual: return "camera.on.rectangle"
        case .triple: return "camera.on.rectangle.fill"
        }
    }

    var avDeviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide:
            return .builtInWideAngleCamera
        case .ultraWide:
            return .builtInUltraWideCamera
        case .telephoto:
            return .builtInTelephotoCamera
        case .dual:
            return .builtInDualCamera
        case .triple:
            return .builtInTripleCamera
        }
    }

    var isAvailable: Bool {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [avDeviceType],
            mediaType: .video,
            position: .back
        )
        return !discoverySession.devices.isEmpty
    }

    static func from(string: String) -> CameraDeviceType {
        return CameraDeviceType(rawValue: string) ?? .wide
    }

    static func allAvailableCases(for availableTypes: [AVCaptureDevice.DeviceType]) -> [CameraDeviceType] {
        return allCases.filter { deviceType in
            availableTypes.contains(deviceType.avDeviceType)
        }
    }
}

// MARK: - Video Quality Preset Enum

enum VideoQualityPreset: String, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case hd720p = "hd720p"
    case hd1080p = "hd1080p"
    case hd4K = "hd4K"

    var displayName: String {
        switch self {
        case .low: return "Low (480p)"
        case .medium: return "Medium (540p)"
        case .high: return "High"
        case .hd720p: return "HD 720p"
        case .hd1080p: return "Full HD 1080p"
        case .hd4K: return "4K Ultra HD"
        }
    }

    var description: String {
        switch self {
        case .low: return "Smallest file size, lower quality"
        case .medium: return "Balanced quality and file size"
        case .high: return "Good quality for most uses"
        case .hd720p: return "Recommended • Great quality, manageable files"
        case .hd1080p: return "Excellent quality, larger files"
        case .hd4K: return "Maximum quality, very large files"
        }
    }

    var avPreset: AVCaptureSession.Preset {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .hd720p: return .hd1280x720
        case .hd1080p: return .hd1920x1080
        case .hd4K: return .hd4K3840x2160
        }
    }

    static func from(string: String) -> VideoQualityPreset {
        return VideoQualityPreset(rawValue: string) ?? .hd720p
    }
}

#Preview {
    CameraSettingsView()
        .modelContainer(for: [UserPreferences.self, StoredMatch.self])
}
