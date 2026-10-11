//
//  ScoreApp.swift
//  score
//
//  App entry point: builds the SwiftData container and the shared WatchConnectivityManager.
//

import SwiftData
import SwiftUI
import os

@main
struct ScoreApp: App {
    let modelContainer: ModelContainer
    @State private var connectivity: WatchConnectivityManager

    init() {
        do {
            modelContainer = try ModelContainer(
                for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false, allowsSave: true)
            )

            let context = modelContainer.mainContext
            let eventStore = EventStore(modelContext: context)
            #if DEBUG
                // Launch-argument sample data for screenshots; runs before anything reads the store
                DebugSeed.applyIfRequested(eventStore: eventStore, modelContext: context)
            #endif
            let stateProjector = StateProjector()
            let undoService = UndoService(eventStore: eventStore, stateProjector: stateProjector)

            _connectivity = State(
                initialValue: WatchConnectivityManager(
                    eventStore: eventStore,
                    stateProjector: stateProjector,
                    undoService: undoService,
                    modelContext: context
                )
            )
            Log.app.debug("SwiftData initialized successfully")
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectivity)
                .modelContainer(modelContainer)
        }
    }
}
