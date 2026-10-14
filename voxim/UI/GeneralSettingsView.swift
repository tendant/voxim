//
//  GeneralSettingsView.swift
//  voxim
//
//  All preferences, grouped. The menu-bar menu only keeps status, setup problems, and the
//  language picker.
//

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var controller: AppController
    let selection: SettingsSelection
    @AppStorage(AppController.smartFormattingKey) private var smartFormatting = true
    @AppStorage(AppController.preRollKey) private var preRoll = true
    @AppStorage(AppController.livePreviewKey) private var livePreview = true
    @AppStorage(AppController.typeAsYouSpeakKey) private var typeAsYouSpeak = true
    @AppStorage(AppController.handsFreeKey) private var handsFree = true
    @AppStorage(AppController.handsFreeSilenceKey) private var handsFreeSilence = AppController.defaultHandsFreeSilence
    @AppStorage(AppController.handsFreeMaximumKey) private var handsFreeMaximum = AppController.defaultHandsFreeMaximum
    @AppStorage(AppController.chineseScriptKey) private var chineseScript = ChineseScript.simplified
    @AppStorage(AppController.cjkSpacingKey) private var cjkSpacing = true
    @State private var launchAtLoginEnabled = false

    var body: some View {
        Form {
            Section("Setup") {
                SetupSection(
                    modelStatus: controller.modelStatus,
                    chineseModelStatus: controller.languageMode.needsChineseModel ? controller.chineseModelStatus : nil
                )
            }

            Section("Dictation") {
                LabeledContent("Shortcut") {
                    Text("Hold fn · double-tap fn for hands-free").foregroundStyle(.secondary)
                }
                setting("Double-tap fn for hands-free", $handsFree,
                        "Keeps listening without holding fn, idling quietly between sentences. Tap fn to finish, Esc to cancel.")
                if handsFree {
                    Picker("Finish after silence", selection: $handsFreeSilence) {
                        Text("30 seconds").tag(30.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("Never").tag(0.0)
                    }
                    Picker("Maximum length", selection: $handsFreeMaximum) {
                        Text("10 minutes").tag(600.0)
                        Text("30 minutes").tag(1800.0)
                        Text("1 hour").tag(3600.0)
                        Text("No limit").tag(0.0)
                    }
                }
                setting("Type as you speak", $typeAsYouSpeak,
                        "Each sentence is typed as soon as you pause. Esc stops the rest; ⌘Z removes what was typed. Terminals type when you finish.")
                setting("Live preview", $livePreview,
                        "Shows the words recognized so far while you speak.")
                setting("Capture from fn press", $preRoll,
                        "Starts the mic as soon as fn goes down so the first word isn't cut off. The mic indicator flashes on every fn press; Bluetooth headsets may briefly switch to call quality.")
            }

            Section("Text") {
                setting("Smart formatting", $smartFormatting,
                        "Adds a space and lowercases mid-sentence; no trailing period in terminals. voxim never presses Return.")
                LabeledContent(vocabularySummary) {
                    Button("Edit Vocabulary…") { selection.tab = .vocabulary }
                }
            }

            Section("Language") {
                Picker("Language", selection: $controller.languageMode) {
                    ForEach(LanguageMode.allCases) { Text($0.label).tag($0) }
                }
                Text(languageHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.languageMode.needsChineseModel {
                    Picker("Chinese text", selection: $chineseScript) {
                        ForEach(ChineseScript.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Space between 中文 and English", isOn: $cjkSpacing)
                }
            }

            Section("Startup") {
                if LoginItem.isInstalledCopy {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { enabled in
                            LoginItem.setEnabled(enabled)
                            launchAtLoginEnabled = LoginItem.isEnabled
                        }
                    ))
                    .onAppear { launchAtLoginEnabled = LoginItem.isEnabled }
                    if LoginItem.needsApproval {
                        Button("Allow in Login Items settings…") { LoginItem.openSettings() }
                    }
                } else {
                    Text("Launch at login is available once voxim is installed in /Applications.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
    }

    private func setting(_ title: String, _ isOn: Binding<Bool>, _ detail: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }

    private var languageHint: String {
        switch controller.languageMode {
        case .english: "English only, using Parakeet."
        case .auto: "Detects the language each time you speak: English uses Parakeet, Chinese and mixed speech use SenseVoice."
        case .chinese: "Always Chinese (Mandarin), including English terms inside Chinese sentences."
        }
    }

    private var vocabularySummary: String {
        switch controller.replacements.rules.count {
        case 0: "No custom words"
        case 1: "1 custom word"
        case let n: "\(n) custom words"
        }
    }
}
