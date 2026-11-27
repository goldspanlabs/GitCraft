import SwiftUI

/// The bottom pane while several commits are selected: what they are.
struct MultiCommitInspectorView: View {
    @ObservedObject var tab: RepoTab

    private static let commitRowHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(tab.selectedCommits.count) commits selected")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tab.selectedCommits, id: \.oidHex) { commit in
                        HStack(spacing: 8) {
                            Text(commit.shortOid)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(commit.summary)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        .frame(height: Self.commitRowHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // No taller than its rows, so what follows stays close; a long list scrolls.
            .frame(maxHeight: Self.commitRowHeight * CGFloat(tab.selectedCommits.count))

            // Squash is in the selection's context menu; say here why it is off.
            if case let .refused(reason) = tab.squashCheck {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
