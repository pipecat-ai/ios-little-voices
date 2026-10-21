import SwiftUI

/// The conversations kept on the device, newest first and grouped by day. Each opens as a chat;
/// they can be deleted one at a time, by swiping or from the chat.
struct HistoryView: View {
    let archive: ConversationArchive
    /// New conversations are being kept, from Settings.
    let keeping: Bool
    let palette: StagePalette
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if archive.conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(keeping ? "Your conversations with the angel and the devil appear here."
                                     : "Keep conversations is off in Settings, so conversations aren’t saved.")
                    }
                } else {
                    List {
                        ForEach(days, id: \.start) { day in
                            Section(day.title) {
                                ForEach(day.conversations) { conversation in
                                    NavigationLink(value: conversation.id) { HistoryRow(conversation: conversation) }
                                }
                                .onDelete { offsets in archive.delete(offsets.map { day.conversations[$0].id }) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let conversation = archive.conversation(id) {
                    TranscriptView(conversation: conversation, palette: palette) {
                        path.removeAll { $0 == id }
                        archive.delete([id])
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private struct Day {
        let start: Date
        let title: String
        let conversations: [SavedConversation]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: archive.conversations) { calendar.startOfDay(for: $0.started) }
        return byDay.keys.sorted(by: >).map { start in
            Day(start: start, title: Self.title(for: start, calendar: calendar),
                conversations: (byDay[start] ?? []).sorted { $0.started > $1.started })
        }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return sameYear ? day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : day.formatted(.dateTime.day().month(.wide).year())
    }
}

/// A conversation in the list: what the human first said, its time, and how it was answered.
private struct HistoryRow: View {
    let conversation: SavedConversation

    var body: some View {
        let reply = conversation.entries.first { $0.speaker != .human }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.opening ?? "Conversation")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(conversation.started, format: .dateTime.hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let reply, let character = reply.speaker.character {
                Text("\(character.title): \(reply.text)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A saved conversation as a chat: the human's words on the right, the angel's and the devil's
/// lines on the left in their own colours, each named where the speaker changes.
struct TranscriptView: View {
    let conversation: SavedConversation
    let palette: StagePalette
    let delete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Text(conversation.started.formatted(date: .complete, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                ForEach(Array(conversation.entries.enumerated()), id: \.element.id) { index, entry in
                    let named = index == 0 || conversation.entries[index - 1].speaker != entry.speaker
                    ChatBubble(entry: entry, named: named, palette: palette)
                        .padding(.top, named && index > 0 ? 8 : 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(ChatColors.background.ignoresSafeArea())
        .navigationTitle(conversation.opening ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive, action: delete)
        }
    }
}

/// The chat's colours: the characters' bubbles are their halves, softened toward white.
private enum ChatColors {
    static let background = Color(red: 1, green: 0.973, blue: 0.93)

    static func bubble(_ speaker: SavedConversation.Speaker, palette: StagePalette) -> Color {
        let colors = palette.colors
        switch speaker {
        case .human: return .white
        case .angel: return palette.color(RGBA.mix(StageColors.sample(colors.angelHalf, at: 0.4), RGBA(0xFFFFFF), 0.35))
        case .devil: return palette.color(RGBA.mix(StageColors.sample(colors.devilHalf, at: 0.3), RGBA(0xFFFFFF), 0.62))
        }
    }

    static func ink(_ speaker: SavedConversation.Speaker, palette: StagePalette) -> Color {
        speaker.character.map { palette.color(palette.colors.bubbleText[$0]) } ?? Color(red: 0.16, green: 0.1, blue: 0.06)
    }

    static func accent(_ character: DuoCharacter, palette: StagePalette) -> Color {
        let colors = palette.colors
        return palette.color(character == .angel ? StageColors.sample(colors.angelHalf, at: 1)
                                                 : StageColors.sample(colors.devilHalf, at: 0.5))
    }
}

private struct ChatBubble: View {
    let entry: SavedConversation.Entry
    /// The first of a run of the speaker's lines, which names them.
    let named: Bool
    let palette: StagePalette

    var body: some View {
        let human = entry.speaker == .human
        let corners = human
            ? RectangleCornerRadii(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20)
            : RectangleCornerRadii(topLeading: named ? 6 : 20, bottomLeading: 20, bottomTrailing: 20, topTrailing: 20)
        HStack(alignment: .top, spacing: 8) {
            if human { Spacer(minLength: 48) }
            if let character = entry.speaker.character {
                avatar(character).opacity(named ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                if named, let character = entry.speaker.character {
                    Text(character.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ChatColors.accent(character, palette: palette))
                }
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(ChatColors.ink(entry.speaker, palette: palette))
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ChatColors.bubble(entry.speaker, palette: palette), in: UnevenRoundedRectangle(cornerRadii: corners))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            if !human { Spacer(minLength: 48) }
        }
        .fontDesign(.rounded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.speaker.character?.title ?? "You"): \(entry.text)")
    }

    /// The character's face, already cropped to a circle.
    private func avatar(_ character: DuoCharacter) -> some View {
        Image(character == .angel ? "AngelAvatar" : "DevilAvatar")
            .resizable()
            .frame(width: 34, height: 34)
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}
