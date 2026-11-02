import SwiftUI

struct ChatView: View {
    let store: ChatStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.items) { item in
                            ChatItemRow(item: item)
                                .id(item.id)
                        }
                        if store.isRunning, store.isWaitingForText || store.isCheckingBuild {
                            WorkingIndicator(text: store.activity ?? "Working…")
                                .id("working")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: store.items) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: store.activity) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            Divider()
            inputBar
        }
        .background(.background)
        .onAppear { inputFocused = true }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                store.isRunning ? "Claude is working…" : "Describe a model or a change…",
                text: $draft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($inputFocused)
            .onSubmit(send)
            .disabled(store.workspace == nil)

            if store.isRunning {
                Button("Stop", systemImage: "stop.circle.fill") { store.stop() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop Claude (⌘.)")
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
    }

    private var canSend: Bool {
        !store.isRunning && store.workspace != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        if store.send(draft) { draft = "" }
    }
}

private struct ChatItemRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
        case .assistant(let text):
            Text(Self.markdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        case .tool(let activity):
            ToolRow(activity: activity)
        case .notice(let text, let isError):
            Label {
                Text(text).textSelection(.enabled)
            } icon: {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
            }
            .font(.callout)
            .foregroundStyle(isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: isError ? .leading : .center)
        }
    }

    /// Inline Markdown (bold, code, links) with line breaks preserved; plain text if it fails to parse.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

private struct ToolRow: View {
    let activity: ToolActivity

    var body: some View {
        HStack(spacing: 6) {
            statusIcon.frame(width: 14)
            Image(systemName: Self.icon(for: activity.name))
                .foregroundStyle(.secondary)
            Text(activity.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .failed(let reason) = activity.status {
                Text(reason)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help(helpText)
    }

    @ViewBuilder private var statusIcon: some View {
        switch activity.status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").foregroundStyle(.orange)
        }
    }

    private var helpText: String {
        if case .failed(let reason) = activity.status { "\(activity.title)\n\(reason)" } else { activity.title }
    }

    private static func icon(for tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text.magnifyingglass"
        case "Edit", "MultiEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Skill": "book"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct WorkingIndicator: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
