/*
 *  PROJECT ToooT (ToooT_UI)
 *  Undo history browser panel.
 *
 *  PlaybackState maintains a 50-level undoStack of event-slab copies, but the
 *  traditional Cmd+Z workflow only lets you step back one at a time. This panel
 *  surfaces the full stack — users can see every recent edit by label and jump
 *  directly to any point (the way Photoshop / Logic let you).
 *
 *  Entries are labeled at their `snapshotForUndo` call site via a parallel
 *  `undoLabels` array on PlaybackState. Legacy callers get the generic label
 *  "Edit" — opt-in labeling upgrades them over time.
 */

import SwiftUI

public struct UndoHistoryBrowserView: View {
    let state: PlaybackState
    let onDismiss: () -> Void

    public init(state: PlaybackState, onDismiss: @escaping () -> Void = {}) {
        self.state = state
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Undo History")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { onDismiss() }
                    .controlSize(.small)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let labels = state.undoLabels
                    if labels.isEmpty {
                        Text("Nothing to undo.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(16)
                    } else {
                        ForEach(Array(labels.enumerated().reversed()), id: \.offset) { idx, label in
                            row(label: label, stepsBack: labels.count - 1 - idx)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(label: String, stepsBack: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                Text(stepsBack == 0 ? "Current" : "\(stepsBack) step\(stepsBack == 1 ? "" : "s") back")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if stepsBack > 0 {
                Button("Jump") {
                    for _ in 0..<stepsBack { state.undo() }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
