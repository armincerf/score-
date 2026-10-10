//
//  ScoreAnnouncer.swift
//  score
//
//  Text-to-speech announcer for score changes
//

@preconcurrency import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
class ScoreAnnouncer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    var isEnabled = true

    override init() {
        super.init()
        synthesizer.delegate = self
        // The audio session is owned by AudioSessionCoordinator (activated per match)
    }

    func announceScore(
        playerOneScore: Int,
        playerTwoScore: Int,
        playerOneName: String? = nil,
        playerTwoName: String? = nil,
        playerOneGames: Int = 0,
        playerTwoGames: Int = 0,
        bestOf: Int = 5
    ) {
        guard isEnabled else { return }

        let announcement = ScoreAnnouncementUtils.generateAnnouncement(
            playerOneScore: playerOneScore,
            playerTwoScore: playerTwoScore,
            playerOneName: playerOneName,
            playerTwoName: playerTwoName,
            playerOneGames: playerOneGames,
            playerTwoGames: playerTwoGames,
            bestOf: bestOf
        )

        speak(announcement.text)
    }

    /// Speaks arbitrary text (used for "Game to Ann", "Match to Bob").
    func announce(_ text: String) {
        guard isEnabled else { return }
        speak(text)
    }

    func announceMatchEnd(
        playerOneName: String?,
        playerTwoName: String?,
        playerOneGames: Int,
        playerTwoGames: Int,
        winner: Int
    ) {
        guard isEnabled else { return }

        let score = "\(playerOneGames) to \(playerTwoGames)"
        let text: String
        switch winner {
        case 1: text = "Match complete! \(playerOneName ?? "Player 1") wins \(score)!"
        case 2: text = "Match complete! \(playerTwoName ?? "Player 2") wins \(score)!"
        default: text = "Match over, \(playerOneGames) games all."
        }
        speak(text)
    }

    private func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        if let premiumVoice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-GB.Malcolm") {
            utterance.voice = premiumVoice
        } else if let enhancedVoice = AVSpeechSynthesisVoice(
            identifier: "com.apple.ttsbundle.siri_Martha_en-GB_compact")
        {
            utterance.voice = enhancedVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        }

        synthesizer.speak(utterance)
        Log.audio.debug("Speaking: \(text)")
    }
}

extension ScoreAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Log.audio.debug("Finished speaking")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Log.audio.debug("Cancelled speaking")
    }
}
