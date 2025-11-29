//
//  ScoreAnnouncer.swift
//  score
//
//  Text-to-speech announcer for score changes
//

import Foundation
@preconcurrency import AVFoundation
import Combine

@MainActor
class ScoreAnnouncer: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    @Published var isEnabled = true
    
    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }
    
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("[Announcer] Failed to configure audio session: \(error)")
        }
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

    func announceMatchEnd(
        playerOneName: String?,
        playerTwoName: String?,
        playerOneGames: Int,
        playerTwoGames: Int,
        winner: Int
    ) {
        guard isEnabled else { return }

        let winnerName = winner == 1 ? (playerOneName ?? "Player 1") : (playerTwoName ?? "Player 2")
        let score = "\(playerOneGames) to \(playerTwoGames)"
        let text = "Match complete! \(winnerName) wins \(score)!"

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
        } else if let enhancedVoice = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.siri_Martha_en-GB_compact") {
            utterance.voice = enhancedVoice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        }
        
        synthesizer.speak(utterance)
        print("[Announcer] Speaking: \(text)")
    }
}

extension ScoreAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("[Announcer] Finished speaking")
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("[Announcer] Cancelled speaking")
    }
}
