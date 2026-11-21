import SwiftUI
import AppKit
import SentinelCore

/// A small "what is this?" button next to a process name. Clicking it shows what the process
/// is for, where it lives, and a ChatGPT button for a fuller answer.
struct WhatIsIt: View {
    @ObservedObject var model: Model
    let name: String
    let path: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What is \(name)?")
        .tip("What is \(name)?")
        .popover(isPresented: $open, arrowEdge: .bottom) { card }
    }

    private var card: some View {
        let real = path.hasPrefix("/")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconView(icon: IconCache.shared.icon(for: ProcessSample(pid: 0, uid: 501, cpu: 0, path: path)), size: 28)
                Text(name).font(.headline).lineLimit(2)
            }
            Text(ProcessGuide.about(name: name, path: path))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if real {
                Text(Model.scrub(path))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    open = false
                    model.whatIs(name: name, path: path)
                } label: { Label("Ask ChatGPT", systemImage: "sparkles") }
                .tip("Copies a prompt about this process and opens ChatGPT. Nothing is sent until you paste it and press Enter.")
                if real {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: { Label("Show in Finder", systemImage: "folder") }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}
