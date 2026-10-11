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
                    TextField("Player 1", text: $player1Name, prompt: Text("Player 1"))
                        .focused($focusedField, equals: .player1)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .player2 }
                    TextField("Player 2", text: $player2Name, prompt: Text("Player 2"))
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
                    Text("Names are remembered for your next match.")
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

#Preview {
    @Previewable @State var player1 = "Alex"
    @Previewable @State var player2 = ""
    Text(verbatim: "Home")
        .sheet(isPresented: .constant(true)) {
            MatchNameSheet(player1Name: $player1, player2Name: $player2, onStart: {})
        }
}
