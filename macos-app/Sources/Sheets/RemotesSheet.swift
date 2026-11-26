import SwiftUI

enum RemoteURLProtocol: String, CaseIterable, Equatable {
    case https = "HTTPS"
    case ssh = "SSH"

    static func detect(from url: String) -> RemoteURLProtocol? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            return .https
        }
        if trimmed.hasPrefix("ssh://") || isScpStyleSSH(trimmed) {
            return .ssh
        }
        return nil
    }

    private static func isScpStyleSSH(_ url: String) -> Bool {
        guard !url.contains("://"),
              let at = url.firstIndex(of: "@"),
              let colon = url[at...].firstIndex(of: ":")
        else { return false }
        return colon > url.index(after: at)
    }

    func convert(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .https:
            if trimmed.hasPrefix("https://") { return trimmed }
            if trimmed.hasPrefix("http://") {
                return "https://" + trimmed.dropFirst("http://".count)
            }
            if trimmed.hasPrefix("ssh://") {
                var rest = String(trimmed.dropFirst("ssh://".count))
                if let at = rest.firstIndex(of: "@") {
                    rest = String(rest[rest.index(after: at)...])
                }
                return "https://" + rest
            }
            if Self.isScpStyleSSH(trimmed),
               let at = trimmed.firstIndex(of: "@"),
               let colon = trimmed[at...].firstIndex(of: ":")
            {
                let host = trimmed[trimmed.index(after: at)..<colon]
                let path = trimmed[trimmed.index(after: colon)...]
                return "https://\(host)/\(path)"
            }
            return nil
        case .ssh:
            if trimmed.hasPrefix("ssh://") || Self.isScpStyleSSH(trimmed) {
                return trimmed
            }
            let withoutScheme: Substring
            if trimmed.hasPrefix("https://") {
                withoutScheme = trimmed.dropFirst("https://".count)
            } else if trimmed.hasPrefix("http://") {
                withoutScheme = trimmed.dropFirst("http://".count)
            } else {
                return nil
            }
            guard let slash = withoutScheme.firstIndex(of: "/") else { return nil }
            var host = withoutScheme[..<slash]
            if let at = host.firstIndex(of: "@") {
                host = host[host.index(after: at)...]
            }
            let path = withoutScheme[withoutScheme.index(after: slash)...]
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "git@\(host):\(path)"
        }
    }
}

struct RemotesSheet: View {
    private enum Field: Hashable {
        case name
        case url
    }

    private enum ConnectionTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @ObservedObject var tab: RepoTab
    let editing: RemoteInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var url: String
    @State private var connectionTest: ConnectionTestState = .idle
    @FocusState private var focusedField: Field?

    init(tab: RepoTab, editing: RemoteInfo?) {
        self.tab = tab
        self.editing = editing
        let defaultName = tab.remotes.contains(where: { $0.name == "origin" }) ? "" : "origin"
        _name = State(initialValue: editing?.name ?? defaultName)
        _url = State(initialValue: editing?.fetchUrl ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSeparatePushURL: Bool {
        guard let editing else { return false }
        return editing.pushUrl != editing.fetchUrl
    }

    private var isChanged: Bool {
        guard let editing else { return true }
        return trimmedName != editing.name || trimmedURL != editing.fetchUrl
    }

    private var confirmDisabled: Bool {
        trimmedName.isEmpty || trimmedURL.isEmpty || tab.isBusy || (editing != nil && !isChanged)
    }

    private var detectedProtocol: RemoteURLProtocol? {
        RemoteURLProtocol.detect(from: url)
    }

    var body: some View {
        ActionSheetLayout(
            title: "Remote",
            subtitle: editing == nil
                ? "Add new remote repository reference"
                : "Edit URL of the remote repository",
            confirmLabel: editing == nil ? "Add New Remote" : "Edit",
            confirmDisabled: confirmDisabled,
            onCancel: {
                tab.errorMessage = nil
                dismiss()
            },
            onConfirm: submit
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        SheetFieldLabel("Remote:")

                        SheetInputBox(isFocused: focusedField == .name) {
                            TextField("origin", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .focused($focusedField, equals: .name)
                        }
                        .frame(minWidth: 400, maxWidth: .infinity)
                    }

                    GridRow(alignment: .top) {
                        SheetFieldLabel("Repository URL:")
                            .padding(.top, 5)

                        VStack(alignment: .leading, spacing: 7) {
                            SheetInputBox(isFocused: focusedField == .url) {
                                Image(systemName: "link")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                TextField("Git Repository URL", text: $url)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .focused($focusedField, equals: .url)
                                    .onSubmit(submit)
                                    .onChange(of: url) { _, _ in
                                        if connectionTest != .idle {
                                            connectionTest = .idle
                                        }
                                    }

                                if let protocolKind = detectedProtocol {
                                    Menu {
                                        ForEach(RemoteURLProtocol.allCases, id: \.self) { kind in
                                            Button(kind.rawValue) {
                                                if let converted = kind.convert(url) {
                                                    url = converted
                                                }
                                            }
                                        }
                                    } label: {
                                        Text(protocolKind.rawValue)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
                            }
                            .frame(minWidth: 400, maxWidth: .infinity)

                            testConnectionRow
                        }
                    }
                }
                .padding(.top, 2)

                if let editing, hasSeparatePushURL {
                    Text("Push URL (\(editing.pushUrl)) is set separately; saving replaces both URLs.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 480, alignment: .leading)
                }

                if let error = tab.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 480, alignment: .leading)
                }
            }
        }
        .onAppear {
            tab.errorMessage = nil
            focusedField = .name
        }
    }

    @ViewBuilder
    private var testConnectionRow: some View {
        switch connectionTest {
        case .idle:
            Button(action: runConnectionTest) {
                Text("Test Connection")
                    .font(.system(size: 12.5))
                    .underline()
                    .foregroundStyle(trimmedURL.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(trimmedURL.isEmpty)
        case .testing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing connection…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Connection succeeded")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case let .failure(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 356, alignment: .leading)
            }
        }
    }

    private func runConnectionTest() {
        let targetURL = trimmedURL
        guard !targetURL.isEmpty else { return }
        connectionTest = .testing
        Task {
            do {
                try await tab.testRemoteConnection(url: targetURL)
                if trimmedURL == targetURL {
                    connectionTest = .success
                }
            } catch {
                if trimmedURL == targetURL {
                    connectionTest = .failure(error.displayMessage)
                }
            }
        }
    }

    private func submit() {
        guard !confirmDisabled else { return }
        if let editing {
            tab.updateRemote(editing, newName: trimmedName, newURL: trimmedURL)
            dismiss()
        } else {
            tab.addRemote(name: trimmedName, url: trimmedURL) {
                dismiss()
            }
        }
    }
}
