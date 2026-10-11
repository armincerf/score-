//
//  MatchNameSheet.swift
//  score
//
//  New Match sheet: the two players' names, then Start.
//

import SwiftUI

struct MatchNameSheet: View {
    @Binding var player1Name: String
    @Binding var player2Name: String
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field {
        case player1, player2
    }

    private var canStart: Bool {
        !player1Name.trimmingCharacters(in: .whitespaces).isEmpty
            && !player2Name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PlayerNameField(number: 1, tint: .blue, name: $player1Name)
                        .focused($focusedField, equals: .player1)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .player2 }
                    PlayerNameField(number: 2, tint: .red, name: $player2Name)
                        .focused($focusedField, equals: .player2)
                        .submitLabel(.done)
                        .onSubmit {
                            if canStart {
                                onStart()
                            }
                        }
                } header: {
                    Text("Players")
                } footer: {
                    Text("Player 1 serves first. Names are remembered for your next match.")
                }
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            }
            .navigationTitle("New Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", role: .confirm, action: onStart)
                        .disabled(!canStart)
                }
            }
            .onAppear {
                // Auto-focus the first field when there is no remembered name
                if player1Name.isEmpty {
                    focusedField = .player1
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A name field with the player's number in the colour the app uses for them, so the order stays clear once
/// both names are filled in.
struct PlayerNameField: View {
    let number: Int
    let tint: Color
    @Binding var name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            TextField("Player \(number)", text: $name, prompt: Text("Player \(number)"))
        }
    }
}

#Preview {
    @Previewable @State var player1 = "Alex"
    @Previewable @State var player2 = ""
    Text(verbatim: "Home")
        .sheet(isPresented: .constant(true)) {
            MatchNameSheet(player1Name: $player1, player2Name: $player2, onStart: {})
        }
}
