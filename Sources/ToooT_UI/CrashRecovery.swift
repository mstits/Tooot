/*
 *  PROJECT ToooT (ToooT_UI)
 *  Crash-recovery prompt — runs once at launch, shown when recent autosaves exist.
 *
 *  The autosave loop (AudioHost.autosave) writes every 60 s to
 *  `~/Library/Application Support/ToooT/autosave/`. On launch, if any autosave
 *  file is < 24 h old, we surface a sheet letting the user restore the latest or
 *  browse the list. Dismissing is always safe — the files stay on disk and are
 *  also reachable via the Command Palette ("Restore Last Autosave").
 */

import SwiftUI
import Foundation

public struct CrashRecoveryPromptView: View {
    @Binding var isPresented: Bool
    public let autosaves: [URL]
    public let onRestore: (URL) -> Void
    public let onDismiss: () -> Void

    public init(isPresented: Binding<Bool>,
                autosaves: [URL],
                onRestore: @escaping (URL) -> Void,
                onDismiss: @escaping () -> Void = {}) {
        self._isPresented = isPresented
        self.autosaves    = autosaves
        self.onRestore    = onRestore
        self.onDismiss    = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unsaved Projects Found")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(autosaves.count) autosave\(autosaves.count == 1 ? "" : "s") from the last 24 hours. Restore the latest or dismiss.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if autosaves.isEmpty {
                Text("No recent autosaves.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(autosaves.prefix(10), id: \.path) { url in
                            row(for: url)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 220)
            }

            Divider()

            HStack {
                Button("Dismiss") {
                    isPresented = false
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore Latest") {
                    if let latest = autosaves.first {
                        isPresented = false
                        onRestore(latest)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(autosaves.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(for url: URL) -> some View {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                           .contentModificationDate) ?? .distantPast
        let title = url.deletingPathExtension().lastPathComponent
        let relative = RelativeDateTimeFormatter().localizedString(for: mod, relativeTo: Date())
        return HStack(spacing: 10) {
            Image(systemName: "doc.badge.clock")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12))
                Text(relative).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Restore") {
                isPresented = false
                onRestore(url)
            }.controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
