//
//  ExportProgressView.swift
//  score
//
//  Modal shown while finishActiveMatch() stops recording, exports and saves the match.
//

import SwiftUI

struct ExportProgressView: View {
    @Environment(WatchConnectivityManager.self) private var connectivity

    var body: some View {
        VStack(spacing: 24) {
            Text("Saving Match Video")
                .font(.headline)

            ProgressView(value: connectivity.exportProgress)
                .progressViewStyle(.linear)
                .tint(.blue)

            Text("\(Int(connectivity.exportProgress * 100))%")
                .font(.title)
                .monospacedDigit()

            Text("Keep the app open until this finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .presentationDetents([.height(280)])
        .interactiveDismissDisabled()
    }
}
