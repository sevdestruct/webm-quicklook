//
//  Webm_QuicklookApp.swift
//  WebM Quick Look
//
//  Host application for the WebM (.webm) Quick Look thumbnail + preview
//  extensions and the native WebM MediaReader (MEFormatReader). The app itself
//  does little — its job is to carry the exported `org.webmproject.webm` UTI
//  declaration and bundle the extensions so macOS registers them. Launch it
//  once to register the extensions.
//

import SwiftUI

@main
struct Webm_QuicklookApp: App {
    var body: some Scene {
        WindowGroup("WebM Quick Look") {
            ContentView()
        }
    }
}
