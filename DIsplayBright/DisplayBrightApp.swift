//
//  DisplayBrightApp.swift
//  DisplayBright
//
//  Created by Josh Phillips on 4/9/26.
//

import SwiftUI

@main
struct DisplayBrightApp: App {
    @State private var displayManager = DisplayManager()

    var body: some Scene {
        MenuBarExtra("DisplayBright", systemImage: "sun.max.fill") {
            ContentView()
                .environment(displayManager)
        }
        .menuBarExtraStyle(.window)
    }
}
