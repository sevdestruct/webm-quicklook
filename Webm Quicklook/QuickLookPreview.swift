//
//  QuickLookPreview.swift
//  WebM Quick Look
//
//  SwiftUI wrapper around QLPreviewView. Currently unused by the host window
//  (which is a plain info card) but kept as a reusable helper.
//

import SwiftUI
import Quartz
import WebKit

struct QuickLookPreview: NSViewRepresentable {
    var url: URL
    var autostarts: Bool = true

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView()
        preview.autostarts = autostarts
        return preview
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
