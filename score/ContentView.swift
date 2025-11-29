//
//  ContentView.swift
//  score
//
//  Main entry point - displays HomeView
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        HomeView()
    }
}

#Preview {
    // Preview with mock dependencies
    let container = try! ModelContainer(for: StoredMatch.self, StoredMatchEvent.self, UserPreferences.self)
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

    return ContentView()
        .environmentObject(connectivity)
        .modelContainer(container)
}
