//
//  voximApp.swift
//  voxim
//
//  Created by Lei Wang on 10/12/26.
//

import SwiftUI

@main
struct voximApp: App {
    @State private var debugModel = ASRDebugModel()

    var body: some Scene {
        MenuBarExtra {
            ASRDebugView(model: debugModel)
        } label: {
            Image(systemName: debugModel.phase == .recording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.window)
    }
}
