//
//  PreviewSupport.swift
//  score
//
//  Shared fixtures for #Preview blocks: an in-memory SwiftData container and a
//  WatchConnectivityManager wired to it. Not compiled into release builds.
//

#if DEBUG
    import SwiftData

    @MainActor
    enum PreviewSupport {
        struct Fixture {
            let container: ModelContainer
            let connectivity: WatchConnectivityManager
        }

        static func makeFixture() -> Fixture {
            // swiftlint:disable:next force_try
            let container = try! ModelContainer(
                for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = container.mainContext
            let eventStore = EventStore(modelContext: context)
            let stateProjector = StateProjector()
            let undoService = UndoService(eventStore: eventStore, stateProjector: stateProjector)
            let connectivity = WatchConnectivityManager(
                eventStore: eventStore,
                stateProjector: stateProjector,
                undoService: undoService,
                modelContext: context
            )
            return Fixture(container: container, connectivity: connectivity)
        }
    }
#endif
