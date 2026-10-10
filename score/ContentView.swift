//
//  ContentView.swift
//  score
//
//  Main entry point - displays HomeView
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity

    var body: some View {
        HomeView()
    }
}

#Preview {
    let fixture = PreviewSupport.makeFixture()
    ContentView()
        .environment(fixture.connectivity)
        .modelContainer(fixture.container)
}
