//
//  scoreApp.swift
//  score
//
//  Created by Alex Davis on 29/11/2025.
//

import SwiftUI
import SwiftData

@main
struct scoreApp: App {
    let modelContainer: ModelContainer
    @StateObject private var connectivity: WatchConnectivityManager

    init() {
        do {
            // Set up SwiftData model container
            modelContainer = try ModelContainer(
                for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self,
                configurations: ModelConfiguration(
                    isStoredInMemoryOnly: false,
                    allowsSave: true
                )
            )

            // Initialize connectivity with model context
            let context = modelContainer.mainContext
            let eventStore = EventStore(modelContext: context)
            let stateProjector = StateProjector()
            let undoService = UndoService(eventStore: eventStore, stateProjector: stateProjector)

            _connectivity = StateObject(wrappedValue: WatchConnectivityManager(
                eventStore: eventStore,
                stateProjector: stateProjector,
                undoService: undoService,
                modelContext: context
            ))

            print("[App] SwiftData initialized successfully")
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivity)
                .modelContainer(modelContainer)
        }
    }
}
