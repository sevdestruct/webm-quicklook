//
//  ContentView.swift
//  WebM Quick Look
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("WebM Quick Look")
                .font(.title2.bold())

            Text("Native thumbnails and previews for WebM (.webm) video\nin Finder, Spotlight, and Quick Look.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Keep this app in /Applications. macOS registers the Quick\nLook and Media extensions automatically once it has launched\nonce. Enable “WebM MediaReader” under System Settings →\nGeneral → Login Items & Extensions → Media Extensions for\nnative playback.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(width: 460)
    }
}

#Preview {
    ContentView()
}
