import AppKit
import SwiftUI

extension View {
    /// A small caps-style section title, such as "CHANGED FILES (3)".
    func sectionTitleStyle(_ font: Font = .caption) -> some View {
        self.font(font.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// The bordered, rounded box behind the commit composer's text fields.
    func inputFieldBox() -> some View {
        background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
    }

    /// The 30pt title strip along the top of a list or diff pane.
    func paneHeaderBar() -> some View {
        padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    /// The up and down arrow keys call `move` with -1 and 1.
    func arrowKeySelection(_ move: @escaping (Int) -> Void) -> some View {
        onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
    }
}

/// A name that may not fit: one line, cut in the middle so the start and end stay visible,
/// with the full text in a tooltip. Use `tooltip` when the full name differs from what is shown,
/// for example a branch row that shows only the last path segment.
struct MiddleTruncatedText: View {
    private let text: String
    private let tooltip: String

    init(_ text: String, tooltip: String? = nil) {
        self.text = text
        self.tooltip = tooltip ?? text
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(tooltip)
    }
}
