//
//  MatchSummaryServiceTests.swift
//  scoreTests
//
//  MatchSummaryService with an injected availability and a fake generator (the on-device model is
//  never called): one generation per match, saving to the match by id, error mapping and which
//  failures become error cards; and MatchSummaryDisplay, the summary container's state priority.
//

import Foundation
import FoundationModels
import SwiftData
import Testing

@testable import score

/// Counts generator calls and holds a generation open until released.
private final class GeneratorProbe {
    var generations = 0
    var secondCallerStarted = false
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Model availability a test can change, e.g. from inside the generator.
private final class AvailabilityProbe {
    var current: SystemLanguageModel.Availability = .available
}

extension MatchSummaryDisplay {
    /// The case as text, for assertions (MatchAnalysis is not Equatable).
    fileprivate var label: String {
        switch self {
        case .summary(let analysis): "summary: \(analysis.matchSummary.headline)"
        case .generating: "generating"
        case .unavailable(let reason): "unavailable: \(reason)"
        case .failed(let error): "failed: \(error.localizedDescription)"
        case .ready: "ready"
        }
    }
}

@Suite("MatchSummary service")
struct MatchSummaryServiceTests {
    typealias AIError = MatchSummaryService.AIError

    private let container: ModelContainer  // kept alive on purpose: the context does not retain its container
    private let store: EventStore
    private let matchId = UUID()

    init() throws {
        container = try ModelContainer(
            for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = EventStore(modelContext: container.mainContext)
        _ = try store.createMatch(
            id: matchId, matchName: "Ann vs Bob - 10 Oct 2026 at 15:00", playerOneName: "Ann", playerTwoName: "Bob",
            startTimestamp: Date())
    }

    private var match: MatchResult {
        MatchResult(
            id: matchId, playerOneName: "Ann", playerTwoName: "Bob", playerOneGames: 3, playerTwoGames: 1, winner: 1,
            games: [])
    }

    private static func analysis() -> MatchAnalysis {
        MatchAnalysis(
            matchSummary: MatchSummary(
                headline: "Ann edges Bob", narrative: "n", winnerInsights: "w", keyMoments: "k", funFact: "f"),
            rivalryAnalysis: nil)
    }

    private func failure(of result: Result<MatchAnalysis, AIError>) -> AIError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test(
        "Concurrent requests for one match share a single generation, which is saved to that match",
        .timeLimit(.minutes(1)))
    func concurrentRequestsShareOneGeneration() async {
        let probe = GeneratorProbe()
        let service = MatchSummaryService(
            availability: { .available },
            generator: { _ in
                probe.generations += 1
                await probe.waitForRelease()
                return Self.analysis()
            })
        let match = match
        let store = store

        let first = Task { await service.generateAndStoreSummary(for: match, history: [], store: store) }
        while !service.isGenerating(matchId: matchId) { await Task.yield() }
        let second = Task {
            probe.secondCallerStarted = true  // set synchronously before the call joins the running task
            return await service.generateAndStoreSummary(for: match, history: [], store: store)
        }
        while !probe.secondCallerStarted { await Task.yield() }
        probe.release()
        let results = [await first.value, await second.value]

        #expect(probe.generations == 1)
        #expect(results.allSatisfy { (try? $0.get())?.matchSummary.headline == "Ann edges Bob" })
        #expect(!service.isGenerating(matchId: matchId))
        #expect(service.latestSummary(for: matchId)?.matchSummary.headline == "Ann edges Bob")
        #expect(MatchSummaryService.cachedSummary(for: matchId, in: store)?.matchSummary.headline == "Ann edges Bob")
    }

    @Test("A failed generation is remembered for the match, saves nothing, and a later success clears it")
    func failureThenSuccess() async {
        let probe = GeneratorProbe()
        let service = MatchSummaryService(
            availability: { .available },
            generator: { _ in
                probe.generations += 1
                if probe.generations == 1 {
                    throw LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "busy"))
                }
                return Self.analysis()
            })

        let failed = await service.generateAndStoreSummary(for: match, history: [], store: store)
        #expect(failure(of: failed) == .rateLimited)
        #expect(service.error(for: matchId) == .rateLimited)
        #expect(MatchSummaryService.cachedSummary(for: matchId, in: store) == nil)

        let retried = await service.generateAndStoreSummary(for: match, history: [], store: store)
        #expect(failure(of: retried) == nil)
        #expect(service.error(for: matchId) == nil)
        #expect(MatchSummaryService.cachedSummary(for: matchId, in: store) != nil)
    }

    @Test("With the model unavailable the generator is never called and no error card is recorded")
    func unavailableModel() async {
        let probe = GeneratorProbe()
        let service = MatchSummaryService(
            availability: { .unavailable(.appleIntelligenceNotEnabled) },
            generator: { _ in
                probe.generations += 1
                return Self.analysis()
            })

        let result = await service.generateAndStoreSummary(for: match, history: [], store: store)
        let reason = MatchSummaryService.describe(.unavailable(.appleIntelligenceNotEnabled))
        #expect(failure(of: result) == .modelUnavailable(reason))
        #expect(probe.generations == 0)
        #expect(service.error(for: matchId) == nil)
        #expect(!service.isAvailable)
        #expect(service.availabilityDescription.contains("Settings"))
    }

    @Test("Foundation Models errors map to specific user-facing errors")
    func errorMapping() {
        #expect(AIError(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: ""))) == .rateLimited)
        #expect(AIError(LanguageModelSession.Error.concurrentRequests) == .rateLimited)
        #expect(AIError(LanguageModelError.guardrailViolation(.init(debugDescription: ""))) == .guardrailViolation)
        #expect(
            AIError(LanguageModelError.refusal(.init(explanation: "", debugDescription: ""))) == .guardrailViolation)
        let language = LanguageModelError.unsupportedLanguageOrLocale(
            .init(languageCode: Locale.LanguageCode("xx"), debugDescription: ""))
        #expect(AIError(language) == .unsupportedLanguage)
        let context = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4096, tokenCount: 5000, debugDescription: ""))
        #expect(AIError(context) == .contextWindowExceeded)
        #expect(AIError(LanguageModelError.timeout(.init(debugDescription: ""))) == .generationFailed)
        #expect(
            AIError(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "")))
                == .modelUnavailable("The on-device model isn't ready yet. Try again later."))
        #expect(AIError(CocoaError(.fileNoSuchFile)) == .generationFailed)
    }

    @Test("A model that throws as unavailable while still reported available gets an error card")
    func thrownUnavailableWhileAvailable() async throws {
        let service = MatchSummaryService(
            availability: { .available },
            generator: { _ in throw SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "gone")) })

        let result = await service.generateAndStoreSummary(for: match, history: [], store: store)
        let error = try #require(failure(of: result))
        #expect(error == .modelUnavailable("The on-device model isn't ready yet. Try again later."))
        #expect(service.error(for: matchId) == error)
        #expect(
            MatchSummaryDisplay(matchId: matchId, cachedSummary: nil, service: service).label
                == "failed: \(error.localizedDescription)")
    }

    @Test("A model that becomes unavailable mid-generation shows the unavailable card, not an error")
    func becameUnavailableMidGeneration() async {
        let availability = AvailabilityProbe()
        let service = MatchSummaryService(
            availability: { availability.current },
            generator: { _ in
                availability.current = .unavailable(.modelNotReady)
                throw SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "gone"))
            })

        let result = await service.generateAndStoreSummary(for: match, history: [], store: store)
        #expect(failure(of: result) != nil)
        #expect(service.error(for: matchId) == nil)
        #expect(
            MatchSummaryDisplay(matchId: matchId, cachedSummary: nil, service: service).label
                == "unavailable: \(MatchSummaryService.describe(.unavailable(.modelNotReady)))")
    }

    // MARK: - Display priority

    @Test("A saved summary is shown even when the model is unavailable")
    func savedSummaryBeatsUnavailable() {
        let service = MatchSummaryService(
            availability: { .unavailable(.deviceNotEligible) }, generator: { _ in Self.analysis() })
        let cached = Self.analysis()
        #expect(
            MatchSummaryDisplay(matchId: matchId, cachedSummary: cached, service: service).label
                == "summary: Ann edges Bob")
        #expect(
            MatchSummaryDisplay(matchId: matchId, cachedSummary: nil, service: service).label
                == "unavailable: \(MatchSummaryService.describe(.unavailable(.deviceNotEligible)))")
    }

    @Test(
        "Progress while generating, then the generated summary; an available model offers the button",
        .timeLimit(.minutes(1)))
    func displayFollowsGeneration() async {
        let probe = GeneratorProbe()
        let service = MatchSummaryService(
            availability: { .available },
            generator: { _ in
                await probe.waitForRelease()
                return Self.analysis()
            })
        let display = { MatchSummaryDisplay(matchId: matchId, cachedSummary: nil, service: service).label }
        #expect(display() == "ready")

        let match = match
        let store = store
        let generation = Task { await service.generateAndStoreSummary(for: match, history: [], store: store) }
        while !service.isGenerating(matchId: matchId) { await Task.yield() }
        #expect(display() == "generating")

        probe.release()
        _ = await generation.value
        #expect(display() == "summary: Ann edges Bob")
    }

    @Test("Every error has its own non-empty message")
    func errorMessages() {
        let errors: [AIError] = [
            .modelUnavailable("Not ready"), .rateLimited, .guardrailViolation, .unsupportedLanguage,
            .contextWindowExceeded, .generationFailed, .noMatchData,
        ]
        let messages = errors.compactMap(\.errorDescription)
        #expect(messages.count == errors.count)
        #expect(Set(messages).count == errors.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }
}
