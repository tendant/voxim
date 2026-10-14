//
//  VocabularySettingsView.swift
//  voxim
//

import SwiftUI

struct VocabularySettingsView: View {
    @Bindable var store: ReplacementStore
    @State private var selection: Set<Replacement.ID> = []
    @State private var sample = "open the T mux config"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When the transcript contains the first phrase, voxim types the second instead. Matching ignores case and only replaces whole words.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table($store.rules, selection: $selection) {
                TableColumn("When I say") { $rule in
                    TextField("e.g. T mux", text: $rule.spoken)
                }
                TableColumn("Type") { $rule in
                    TextField("e.g. tmux", text: $rule.written)
                }
            }
            .frame(minHeight: 180)

            HStack {
                Button {
                    store.rules.append(Replacement(spoken: "", written: ""))
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    store.rules.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                Spacer()
            }

            GroupBox("Try it") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Type a sample transcript", text: $sample)
                    Text(store.apply(to: sample))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Text("Words that sound identical (pain / pane) can't be told apart; add a rule only for words that are consistently misheard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: SettingsView.size.width, height: SettingsView.size.height, alignment: .top)
    }
}
