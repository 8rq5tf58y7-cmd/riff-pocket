import SwiftUI
import RiffCore

// MARK: - Markdown (headings, bullets, inline styles)

/// Lightweight block Markdown: `#` headings in serif, `-`/`*` bullets, numbered lists, inline bold/italic/code.
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var blocks: [String] {
        source.components(separatedBy: "\n").reduce(into: [String]()) { out, line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if out.last != "" { out.append("") }
            } else {
                out.append(line)
            }
        }
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Spacer().frame(height: 2)
        } else if t.hasPrefix("#") {
            let level = t.prefix { $0 == "#" }.count
            Text(inline(String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                .font(Theme.serif(level <= 1 ? 22 : level == 2 ? 19 : 17, .semibold))
                .padding(.top, 6)
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.accent)
                Text(inline(String(t.dropFirst(2))))
            }
        } else if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(t[...dot])).foregroundStyle(Theme.secondary).monospacedDigit()
                Text(inline(String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)))
            }
        } else {
            Text(inline(t))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Thinking indicator

struct ThinkingIndicator: View {
    var label: String = "Thinking"
    @State private var spin = false

    var body: some View {
        HStack(spacing: 8) {
            Text("✻")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.accent)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)
            Text("\(label)…").font(Theme.mono).foregroundStyle(Theme.secondary)
        }
        .onAppear { spin = true }
    }
}

// MARK: - Message list

struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let isThinking: Bool
    var thinkingLabel = "Thinking"
    var greeting = "What would you like to know?"
    var subtitle: String? = nil
    var suggestions: [String] = []
    var onSuggestion: (String) -> Void = { _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty && !isThinking {
                        emptyState.padding(.top, 48)
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                        MessageRow(message: m).id(i)
                    }
                    if isThinking {
                        ThinkingIndicator(label: thinkingLabel).id("thinking")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
            }
            .onChange(of: isThinking) { _, thinking in
                if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("✻").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.accent)
            Text(greeting).font(Theme.serif(26)).multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            if !suggestions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { onSuggestion(s) } label: {
                            Text(s).font(.subheadline).foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.surface, in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surface, in: .rect(cornerRadius: 18))
            }
        } else {
            MarkdownText(message.content)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                }
        }
    }
}

// MARK: - Composer

/// Large rounded input with the model chip underneath, like a modern chat app.
struct Composer<Accessory: View>: View {
    @Binding var text: String
    let placeholder: String
    let isBusy: Bool
    let isEnabled: Bool
    let onSend: () -> Void
    let accessory: () -> Accessory
    @FocusState private var focused: Bool

    init(text: Binding<String>, placeholder: String = "Reply…", isBusy: Bool = false, isEnabled: Bool = true,
         onSend: @escaping () -> Void, @ViewBuilder accessory: @escaping () -> Accessory) {
        _text = text
        self.placeholder = placeholder
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.onSend = onSend
        self.accessory = accessory
    }

    private var canSend: Bool {
        isEnabled && !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { if canSend { onSend() } }
            HStack(spacing: 8) {
                accessory()
                Spacer()
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Theme.accent : Theme.border, in: .circle)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(14)
        .background(Theme.raised, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Small pieces

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Theme.monoSmall).foregroundStyle(Theme.secondary).tracking(0.8)
    }
}

struct StatusPill: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(Theme.monoSmall)
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12), in: .capsule)
    }
}
