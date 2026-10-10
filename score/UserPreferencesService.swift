//
//  UserPreferencesService.swift
//  score
//
//  Service for managing user preferences in SwiftData
//

import Foundation
import SwiftData
import os

class UserPreferencesService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Get or Create Preferences

    func getPreferences() -> UserPreferences {
        let descriptor = FetchDescriptor<UserPreferences>()

        do {
            let preferences = try modelContext.fetch(descriptor)

            if let existing = preferences.first {
                return existing
            }
            // Create default preferences
            let newPreferences = UserPreferences()
            modelContext.insert(newPreferences)
            try modelContext.save()
            Log.store.info("Created default preferences")
            return newPreferences
        } catch {
            Log.store.error("Error fetching preferences: \(error)")
            // Return defaults without saving on error
            return UserPreferences()
        }
    }

    // MARK: - Update Player Names

    func updatePlayerNames(player1: String, player2: String) {
        let preferences = getPreferences()
        preferences.mostRecentPlayer1Name = player1
        preferences.mostRecentPlayer2Name = player2
        preferences.lastUpdated = Date()

        do {
            try modelContext.save()
            Log.store.info("Updated player names: \(player1) vs \(player2)")
        } catch {
            Log.store.error("Error saving player names: \(error)")
        }
    }

    // MARK: - Get Recent Player Names

    func getMostRecentPlayerNames() -> (player1: String, player2: String) {
        let preferences = getPreferences()
        return (preferences.mostRecentPlayer1Name, preferences.mostRecentPlayer2Name)
    }

    // MARK: - Camera Preferences

    func updateCameraSettings(deviceType: String, qualityPreset: String) {
        let preferences = getPreferences()
        preferences.cameraDeviceType = deviceType
        preferences.videoQualityPreset = qualityPreset
        preferences.lastUpdated = Date()

        do {
            try modelContext.save()
            Log.store.info("Updated camera settings: \(deviceType), \(qualityPreset)")
        } catch {
            Log.store.error("Error saving camera settings: \(error)")
        }
    }

    func getCameraSettings() -> (deviceType: String, qualityPreset: String) {
        let preferences = getPreferences()
        return (
            preferences.cameraDeviceType ?? "wide",
            preferences.videoQualityPreset ?? "hd720p"
        )
    }

    func setCameraEnabled(_ enabled: Bool) {
        let preferences = getPreferences()
        preferences.cameraEnabled = enabled
        preferences.lastUpdated = Date()

        do {
            try modelContext.save()
            Log.store.debug("Camera recording \(enabled ? "enabled" : "disabled")")
        } catch {
            Log.store.error("Error saving camera enabled: \(error)")
        }
    }

    func isCameraEnabled() -> Bool {
        return getPreferences().cameraEnabled
    }
}
