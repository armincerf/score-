//
//  ScoreAnnouncementUtilsTests.swift
//  scoreTests
//
//  Announcement text and game/match-point detection (first to 11, win by 2).
//

import Testing

@testable import score

@Suite("ScoreAnnouncementUtils")
struct ScoreAnnouncementUtilsTests {
    private func text(_ p1: Int, _ p2: Int) -> String {
        ScoreAnnouncementUtils.generateAnnouncement(
            playerOneScore: p1, playerTwoScore: p2, playerOneName: "Ann", playerTwoName: "Bob"
        ).text
    }

    @Test("Leader's score is read first, then the leader's name")
    func leaderFirst() {
        #expect(text(3, 1) == "3 1 to Ann")
        #expect(text(1, 3) == "3 1 to Bob")
    }

    @Test("Ties below 10 are 'all', 10-10 and above are deuce")
    func tiesAndDeuce() {
        #expect(text(0, 0) == "0 all")
        #expect(text(7, 7) == "7 all")
        #expect(text(10, 10) == "Deuce")
        #expect(text(13, 13) == "Deuce")
    }

    @Test("Advantage after deuce")
    func advantage() {
        #expect(text(11, 10) == "Advantage Ann")
        #expect(text(10, 11) == "Advantage Bob")
    }

    @Test("Default player names")
    func defaultNames() {
        let a = ScoreAnnouncementUtils.generateAnnouncement(playerOneScore: 5, playerTwoScore: 2, playerOneName: nil, playerTwoName: nil)
        #expect(a.text == "5 2 to Player 1")
    }

    @Test("Game point flag")
    func gamePoint() {
        #expect(ScoreAnnouncementUtils.generateAnnouncement(playerOneScore: 10, playerTwoScore: 8, playerOneName: nil, playerTwoName: nil).isGamePoint)
        #expect(!ScoreAnnouncementUtils.generateAnnouncement(playerOneScore: 10, playerTwoScore: 10, playerOneName: nil, playerTwoName: nil).isGamePoint)
        #expect(!ScoreAnnouncementUtils.generateAnnouncement(playerOneScore: 9, playerTwoScore: 8, playerOneName: nil, playerTwoName: nil).isGamePoint)
    }

    @Test("Match point requires being one game from victory")
    func matchPoint() {
        let mp = ScoreAnnouncementUtils.generateAnnouncement(
            playerOneScore: 10, playerTwoScore: 5, playerOneName: nil, playerTwoName: nil, playerOneGames: 2, playerTwoGames: 0, bestOf: 5)
        #expect(mp.isMatchPoint)
        let notMp = ScoreAnnouncementUtils.generateAnnouncement(
            playerOneScore: 10, playerTwoScore: 5, playerOneName: nil, playerTwoName: nil, playerOneGames: 1, playerTwoGames: 0, bestOf: 5)
        #expect(!notMp.isMatchPoint)
    }

    @Test("Game is won at 11 with a two-point margin", arguments: [
        (11, 9, 1), (9, 11, 2), (12, 10, 1), (15, 13, 1), (11, 10, nil), (10, 10, nil), (13, 12, nil), (11, 0, 1),
    ])
    func gameWon(p1: Int, p2: Int, winner: Int?) {
        #expect(ScoreAnnouncementUtils.checkGameWon(playerOneScore: p1, playerTwoScore: p2) == winner)
    }

    @Test("Match is won with a majority of games")
    func matchWon() {
        #expect(ScoreAnnouncementUtils.checkMatchWon(playerOneGames: 3, playerTwoGames: 1, bestOf: 5) == 1)
        #expect(ScoreAnnouncementUtils.checkMatchWon(playerOneGames: 2, playerTwoGames: 2, bestOf: 5) == nil)
        #expect(ScoreAnnouncementUtils.checkMatchWon(playerOneGames: 1, playerTwoGames: 2, bestOf: 3) == 2)
    }
}
