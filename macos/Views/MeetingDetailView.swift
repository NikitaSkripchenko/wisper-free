import AppKit
import SwiftUI

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case transcript = "Raw transcript"
    case audio = "Audio"

    var id: String { rawValue }
}

/// The detail pane for a selected meeting: header, Notes / Raw transcript /
/// Audio segmented control, and the note sections underneath.
struct MeetingDetailView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @EnvironmentObject private var coordinator: MeetingOperationCoordinator
    let record: MeetingRecord
    var showsBackButton: Bool = false

    @State private var transcript: String?
    @State private var notes: MeetingNotes?
    @State private var loadError: String?
    @State private var confirmRemoval = false
    @State private var selectedTab: MeetingDetailTab = .notes
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var titleError: String?
    @State private var lastRenameAttempt: String?
    @State private var showEarlierNotes = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBackButton {
                Button {
                    appViewModel.selectedMeetingID = nil
                } label: {
                    Label("Meetings", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))
            }

            header
                .padding(EdgeInsets(top: 22, leading: 34, bottom: 0, trailing: 34))

            if let titleError {
                Text(titleError)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.dangerText)
                    .padding(.horizontal, 34)
            }

            if let feedback = appViewModel.meetingActionFeedback, feedback.meetingID == record.id {
                inlineMessage(feedback.message, retryable: feedback.isRetryable) { retry(feedback.action) }
                    .padding(EdgeInsets(top: 10, leading: 34, bottom: 0, trailing: 34))
            }

            segmentedControl
                .padding(EdgeInsets(top: 12, leading: 34, bottom: 12, trailing: 34))

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 6, leading: 34, bottom: 24, trailing: 34))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.canvas)
        .task(id: record.transcriptArtifact) {
            do {
                transcript = try await coordinator.loadTranscript(for: record)
                loadError = nil
            } catch {
                loadError = "Some meeting files could not be loaded."
            }
        }
        .task(id: record.lastValidNotesArtifact) {
            do {
                notes = try await coordinator.loadNotes(for: record)
                loadError = nil
            } catch {
                loadError = "Some meeting files could not be loaded."
            }
        }
        .onAppear { handleRenameRequest() }
        .onChange(of: appViewModel.renameRequestedMeetingID) { _, _ in handleRenameRequest() }
        .confirmationDialog(
            "Remove this meeting and all of its owned audio, transcript, and notes?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Meeting", role: .destructive) {
                Task { await appViewModel.removeMeeting(record) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    if isEditingTitle {
                        TextField("Meeting title", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 21, weight: .semibold))
                            .focused($titleFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                            .accessibilityIdentifier("meeting.rename.field")
                    } else {
                        Button {
                            beginRename()
                        } label: {
                            Text(record.title)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(Theme.Color.text)
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.activeMeetingID == record.id)
                        .help("Rename meeting")
                        .accessibilityIdentifier("meeting.title")
                    }

                    HStack(spacing: 10) {
                        Text(subtitleText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.textTertiary)
                        statusChip
                            .accessibilityIdentifier("meeting.status")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Button {
                        Task { await appViewModel.copyMeetingNotes(record) }
                    } label: {
                        Label("Copy notes", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .foregroundStyle(.white)
                    .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .disabled(notes == nil)

                    Menu {
                        Button("Rename") { beginRename() }
                            .disabled(coordinator.activeMeetingID == record.id)
                        Button("Copy Notes") { Task { await appViewModel.copyMeetingNotes(record) } }
                            .disabled(notes == nil)
                        Button("Copy Raw Transcript") { Task { await appViewModel.copyMeetingTranscript(record) } }
                            .disabled(transcript == nil)
                        if record.transcription.status == .failed {
                            Button("Retry Transcription") { Task { await appViewModel.retryTranscription(for: record) } }
                                .disabled(record.transcription.failure?.isRetryable == false)
                        } else if record.transcription.status == .completed,
                                  record.notes.status == .failed || record.lastValidNotesArtifact != nil {
                            Button(record.lastValidNotesArtifact == nil ? "Retry Notes" : "Regenerate Notes") {
                                Task { await appViewModel.retryNotes(for: record) }
                            }
                            .disabled(record.notes.failure?.isRetryable == false)
                        }
                        Button("Play or Pause Audio") { Task { await appViewModel.playMeetingAudio(record) } }
                        Button("Reveal Audio in Finder") { Task { await appViewModel.revealMeetingAudio(record) } }
                        Divider()
                        Button("Remove Meeting", role: .destructive) { confirmRemoval = true }
                            .disabled(coordinator.activeMeetingID == record.id)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30, height: 30)
                    .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.Color.controlBorder)
                    }
                    .accessibilityLabel("More actions for this meeting")
                    .accessibilityIdentifier("meeting.more")
                }
            }

            if coordinator.activeMeetingID == record.id {
                Button("Cancel", role: .destructive) { coordinator.cancelProcessing() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.dangerText)
            }
        }
    }

    private var subtitleText: String {
        var parts: [String] = [record.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year())]
        if let duration = Self.durationText(record.durationSeconds) {
            parts.append(duration)
        }
        parts.append(record.captureMode.displayName)
        return parts.joined(separator: " · ")
    }

    private static func durationText(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) h \(String(format: "%02d", minutes)) min" : "\(minutes) min"
    }

    private var statusChip: some View {
        let (tint, fill) = statusColors
        return Label(record.displayState.statusText, systemImage: statusIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var statusIcon: String {
        switch record.displayState {
        case .complete: "checkmark"
        case .transcribing, .generatingNotes: "clock"
        case .transcriptFailed, .notesFailed: "exclamationmark.triangle.fill"
        case .captured, .transcriptReady: "circle"
        }
    }

    private var statusColors: (Color, Color) {
        switch record.displayState {
        case .complete: (Theme.Color.successText, Theme.Color.successSoft)
        case .transcribing, .generatingNotes: (Theme.Color.accentSoftText, Theme.Color.accentSoft)
        case .transcriptFailed, .notesFailed: (Theme.Color.dangerText, Theme.Color.dangerSoft)
        case .captured, .transcriptReady: (Theme.Color.textSecondary, Theme.Color.segmentTrack)
        }
    }

    // MARK: - Segmented control

    private var segmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(MeetingDetailTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                        .foregroundStyle(selectedTab == tab ? Theme.Color.text : Theme.Color.textSecondary)
                        .frame(maxWidth: showsBackButton ? .infinity : nil)
                        .padding(.horizontal, showsBackButton ? 0 : 16)
                        .frame(height: 26)
                        .background(selectedTab == tab ? Theme.Color.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Theme.Color.segmentBorder)
                            }
                        }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: showsBackButton ? .infinity : nil)
            }
        }
        .padding(3)
        .background(Theme.Color.segmentTrack, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("meeting.tabs")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .notes:
            notesContent
        case .transcript:
            transcriptContent
        case .audio:
            MeetingAudioPlayerView(player: appViewModel.audioPlayer, record: record)
                .accessibilityIdentifier("meeting.audio")
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        if let failure = record.notes.failure {
            VStack(alignment: .leading, spacing: 20) {
                failureBanner(failure)
                if record.lastValidNotesArtifact != nil {
                    earlierNotesBanner
                    if showEarlierNotes, let notes {
                        NotesSectionsView(notes: notes, isNarrow: showsBackButton, openRawTranscript: openRawTranscript)
                    }
                }
                transcriptCard
            }
        } else if record.lastValidNotesArtifact == nil {
            ProcessingStagesView(record: record, openRawTranscript: openRawTranscript)
        } else if let notes {
            NotesSectionsView(notes: notes, isNarrow: showsBackButton, openRawTranscript: openRawTranscript)
        } else {
            Text("Loading notes…")
                .foregroundStyle(Theme.Color.textTertiary)
        }
    }

    private func openRawTranscript() {
        selectedTab = .transcript
    }

    private var transcriptContent: some View {
        Text(transcript ?? "No transcript is available yet.")
            .font(.system(size: 13))
            .foregroundStyle(transcript == nil ? Theme.Color.textTertiary : Theme.Color.textBody)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("meeting.transcript")
    }

    private func failureBanner(_ failure: MeetingFailure) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Color.dangerText)
            VStack(alignment: .leading, spacing: 10) {
                Text("Notes could not be written")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.dangerText)
                Text(failure.message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Color.textBody)
                HStack(spacing: 9) {
                    Button("Retry notes") { Task { await appViewModel.retryNotes(for: record) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .foregroundStyle(.white)
                        .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .disabled(failure.isRetryable == false)
                    Button("Copy transcript") { Task { await appViewModel.copyMeetingTranscript(record) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .foregroundStyle(Theme.Color.textBody)
                        .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.Color.controlBorder)
                        }
                    Text("Transcription does not run again; the audio is not re-uploaded.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Color.dangerText.opacity(0.75))
                }
            }
        }
        .padding(16)
        .background(Theme.Color.dangerSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var earlierNotesText: String {
        guard let generatedAt = record.notesProvenance?.generatedAt else {
            return "An earlier set of notes is still here. Retrying writes a new set and keeps this one until it succeeds."
        }
        let date = generatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return "An earlier set of notes from \(date) is still here. Retrying writes a new set and keeps this one until it succeeds."
    }

    private var earlierNotesBanner: some View {
        HStack {
            Text(earlierNotesText)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Button(showEarlierNotes ? "Hide them" : "Show them") { showEarlierNotes.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.Color.controlBorder) }
        }
        .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 15))
        .background(Theme.Color.quoteBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Transcript").font(.system(size: 15, weight: .semibold))
            Text(transcript ?? "No transcript is available yet.")
                .font(.system(size: 13))
                .foregroundStyle(transcript == nil ? Theme.Color.textTertiary : Theme.Color.textBody)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Color.border) }
    }

    // MARK: - Actions

    @ViewBuilder
    private func inlineMessage(_ message: String, retryable: Bool, retry: (() -> Void)? = nil) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
            Spacer()
            if retryable, let retry {
                Button("Retry", action: retry)
            }
        }
        .foregroundStyle(Theme.Color.dangerText)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.dangerSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func beginRename() {
        guard coordinator.activeMeetingID != record.id else { return }
        titleDraft = record.title
        titleError = nil
        isEditingTitle = true
        titleFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func cancelRename() {
        titleDraft = record.title
        titleError = nil
        isEditingTitle = false
        titleFocused = false
    }

    private func commitRename() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            titleError = "Enter a meeting title."
            return
        }
        lastRenameAttempt = trimmed
        Task {
            if await appViewModel.renameMeeting(record, title: trimmed) {
                isEditingTitle = false
                titleFocused = false
                titleError = nil
            }
        }
    }

    private func handleRenameRequest() {
        guard appViewModel.renameRequestedMeetingID == record.id else { return }
        appViewModel.renameRequestedMeetingID = nil
        beginRename()
    }

    private func retry(_ action: MeetingAction) {
        switch action {
        case .rename:
            if let lastRenameAttempt {
                titleDraft = lastRenameAttempt
                commitRename()
            }
        case .retryTranscription:
            Task { await appViewModel.retryTranscription(for: record) }
        case .retryNotes:
            Task { await appViewModel.retryNotes(for: record) }
        case .remove:
            confirmRemoval = true
        case .copyTranscript:
            Task { await appViewModel.copyMeetingTranscript(record) }
        case .copyNotes:
            Task { await appViewModel.copyMeetingNotes(record) }
        case .playAudio:
            Task { await appViewModel.playMeetingAudio(record) }
        case .revealAudio:
            Task { await appViewModel.revealMeetingAudio(record) }
        }
    }
}

// MARK: - Notes sections

private struct NotesSectionsView: View {
    let notes: MeetingNotes
    let isNarrow: Bool
    let openRawTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SUMMARY")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Color.textTertiary)
                Text(summaryText)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Color.textBody)
            }

            NoteItemSection(
                title: "Decisions",
                items: notes.decisions,
                showsEvidence: true,
                emptyText: "No decision was found in this transcript.",
                emptyDetail: "That does not mean none was made — only that nothing in the recording stated one plainly. The raw transcript is the place to check.",
                openRawTranscript: openRawTranscript
            )

            ActionItemSection(items: notes.actionItems, showsEvidence: isNarrow == false, openRawTranscript: openRawTranscript)

            NoteQuoteSection(
                title: "Open questions",
                items: notes.openQuestions,
                emptyText: "No open questions were found in this transcript."
            )
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var summaryText: String {
        let joined = notes.summaryPoints.map(\.text).joined(separator: " ")
        return joined.isEmpty ? "No summary was found in this transcript." : joined
    }
}

private struct NoteItemSection: View {
    let title: String
    let items: [GroundedMeetingNote]
    let showsEvidence: Bool
    let emptyText: String
    let emptyDetail: String
    let openRawTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12)).foregroundStyle(Theme.Color.textTertiary)
            }
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyText).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Color.textBody)
                    Text(emptyDetail).font(.system(size: 12.5)).foregroundStyle(Theme.Color.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Theme.Color.controlBorder)
                }
                .accessibilityIdentifier("notes.empty")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.text).font(.system(size: 13.5)).foregroundStyle(Theme.Color.text)
                        if showsEvidence {
                            EvidenceDisclosure(evidence: item.evidence, openRawTranscript: openRawTranscript)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Color.border) }
                    .accessibilityIdentifier("notes.item")
                }
            }
        }
    }
}

private struct ActionItemSection: View {
    let items: [MeetingActionItem]
    let showsEvidence: Bool
    let openRawTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Next steps").font(.system(size: 15, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12)).foregroundStyle(Theme.Color.textTertiary)
            }
            if items.isEmpty {
                Text("No next steps were found in this transcript.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                    .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Theme.Color.controlBorder)
                    }
                    .accessibilityIdentifier("notes.empty")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ActionItemRow(item: item, showsEvidence: showsEvidence, openRawTranscript: openRawTranscript)
                }
            }
        }
    }
}

private struct ActionItemRow: View {
    let item: MeetingActionItem
    let showsEvidence: Bool
    let openRawTranscript: () -> Void
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.text).font(.system(size: 13.5)).foregroundStyle(Theme.Color.text)
            HStack(spacing: 12) {
                Text(item.owner.map { "Owner: \($0)" } ?? "Owner not stated")
                    .foregroundStyle(item.owner == nil ? Theme.Color.textTertiary : Theme.Color.textBody)
                Text(item.dueDate.map { "By \($0)" } ?? "Date not stated")
                    .foregroundStyle(item.dueDate == nil ? Theme.Color.textTertiary : Theme.Color.textBody)
                if showsEvidence {
                    Spacer()
                    EvidenceDisclosureButton(evidence: item.evidence, isOpen: $isOpen)
                }
            }
            .font(.system(size: 11.5))
            if showsEvidence, isOpen {
                EvidenceQuote(evidence: item.evidence, openRawTranscript: openRawTranscript)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(Theme.Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Color.border) }
    }
}

private struct NoteQuoteSection: View {
    let title: String
    let items: [GroundedMeetingNote]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text("\(items.count)").font(.system(size: 12)).foregroundStyle(Theme.Color.textTertiary)
            }
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .background(Theme.Color.quoteBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("notes.empty")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.Color.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                        .background(Theme.Color.quoteBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

/// The "From transcript" disclosure: reveals the exact source quote beneath
/// the line it belongs to. The one place besides stage-completion that
/// animates — `Theme.Motion.quoteReveal`, height and opacity.
private struct EvidenceDisclosure: View {
    let evidence: String
    let openRawTranscript: () -> Void
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EvidenceDisclosureButton(evidence: evidence, isOpen: $isOpen)
            if isOpen {
                EvidenceQuote(evidence: evidence, openRawTranscript: openRawTranscript)
                    .padding(.top, 10)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                        removal: .opacity
                    ))
            }
        }
    }
}

private struct EvidenceDisclosureButton: View {
    let evidence: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isOpen: Binding<Bool>?

    init(evidence: String, isOpen: Binding<Bool>? = nil) {
        self.evidence = evidence
        self.isOpen = isOpen
    }

    var body: some View {
        Button {
            let animation = reduceMotion ? nil : Theme.Motion.quoteReveal
            if let isOpen {
                withAnimation(animation) { isOpen.wrappedValue.toggle() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen?.wrappedValue == true ? 90 : 0))
                Text("From transcript")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.Color.textBody)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("From transcript")
        .accessibilityValue(isOpen?.wrappedValue == true ? "Expanded" : "Collapsed")
    }
}

private struct EvidenceQuote: View {
    let evidence: String
    let openRawTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(evidence)”")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Color.textBody)
            HStack(spacing: 14) {
                Text("Exact words from the transcript, unedited.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textTertiary)
                Button("Open in raw transcript", action: openRawTranscript)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Color.accent)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.quoteBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.Color.quoteRule).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Processing stages

/// Prefixes the Transcribing stage's detail text with "Part N of M sent." when
/// chunk-upload progress is available. Pure mapping, kept separate so it's testable
/// without a view host — including the no-progress case, which returns `base` untouched.
func transcribingStageDetail(base: String, progress: TranscriptionChunkProgress?) -> String {
    guard let progress else { return base }
    return "\(progress.statusText) \(base)"
}

private struct ProcessingStagesView: View {
    let record: MeetingRecord
    let openRawTranscript: () -> Void
    @EnvironmentObject private var appViewModel: AppViewModel
    @EnvironmentObject private var coordinator: MeetingOperationCoordinator

    private var isActiveMeeting: Bool { coordinator.activeMeetingID == record.id }

    private var chunkProgress: TranscriptionChunkProgress? {
        guard isActiveMeeting, record.transcription.status == .processing else { return nil }
        return coordinator.chunkProgress
    }

    /// Only reachable while a completed transcript from an earlier attempt is still on
    /// disk (the retry case) — chunk text isn't stitched or persisted until the whole
    /// transcription finishes, so there is nothing to show for a first-time attempt.
    private var canReadTranscriptSoFar: Bool {
        record.transcription.status == .processing && record.transcriptArtifact != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StageRow(
                title: "Capture saved",
                detail: "Audio written to this Mac.",
                complete: true,
                active: false,
                failed: false,
                isLast: false,
                action: StageAction(label: "Reveal in Finder") {
                    Task { await appViewModel.revealMeetingAudio(record) }
                }
            )
            StageRow(
                title: "Transcribing",
                detail: record.transcription.failure?.message
                    ?? transcribingStageDetail(
                        base: "Audio is uploaded to OpenAI in parts; the text comes back here.",
                        progress: chunkProgress
                    ),
                complete: record.transcription.status == .completed,
                active: record.transcription.status == .processing,
                failed: record.transcription.status == .failed,
                isLast: false,
                progress: chunkProgress,
                action: canReadTranscriptSoFar
                    ? StageAction(label: "Read the transcript so far", action: openRawTranscript)
                    : nil
            )
            StageRow(
                title: "Preparing notes",
                detail: "Starts once the full transcript is in. Decisions, next steps and open questions are written from it.",
                complete: record.lastValidNotesArtifact != nil,
                active: record.notes.status == .processing,
                failed: false,
                isLast: true
            )

            if isActiveMeeting, record.transcription.status == .processing || record.notes.status == .processing {
                stopProcessingBanner
                    .padding(.top, 22)
            }
        }
    }

    private var stopProcessingBanner: some View {
        HStack(spacing: 16) {
            Text("Stopping now keeps the recording and every part already transcribed. You can retry the rest later.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop processing") { appViewModel.stopProcessing(for: record) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(Theme.Color.textBody)
                .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.Color.controlBorder) }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(Theme.Color.quoteBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.Color.border) }
    }
}

private struct StageAction {
    let label: String
    let action: () -> Void
}

private struct StageRow: View {
    let title: String
    let detail: String
    let complete: Bool
    let active: Bool
    let failed: Bool
    let isLast: Bool
    var progress: TranscriptionChunkProgress?
    var action: StageAction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                icon
                if isLast == false {
                    Rectangle().fill(Theme.Color.border).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(title).font(.system(size: 13.5, weight: .semibold))
                        if active {
                            Text("In progress").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.Color.accentSoftText)
                        } else if complete == false && failed == false {
                            Text("Waiting").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.Color.textTertiary)
                        }
                    }
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.Color.textSecondary)
                }
                if let progress {
                    ChunkProgressBar(progress: progress)
                        .frame(width: 340, height: 6)
                }
                if let action {
                    Button(action.label, action: action.action)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .foregroundStyle(Theme.Color.textBody)
                        .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.Color.controlBorder) }
                }
            }
            .padding(.bottom, isLast ? 0 : 20)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if complete {
            Circle()
                .fill(Theme.Color.successSoft)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.successText)
                }
                .transition(reduceMotion ? .identity : .scale(scale: 0.72).combined(with: .opacity))
                .animation(reduceMotion ? nil : Theme.Motion.stageComplete, value: complete)
        } else if failed {
            Circle()
                .fill(Theme.Color.dangerSoft)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.Color.dangerText)
                }
        } else if active {
            Circle()
                .fill(Theme.Color.accentSoft)
                .frame(width: 22, height: 22)
                .overlay {
                    ProgressView().controlSize(.small)
                }
        } else {
            Circle()
                .strokeBorder(Theme.Color.controlBorder, lineWidth: 2)
                .frame(width: 22, height: 22)
        }
    }
}

/// A determinate progress bar; its filled width updates with `progress` but never animates.
private struct ChunkProgressBar: View {
    let progress: TranscriptionChunkProgress

    private var fraction: CGFloat {
        guard progress.total > 0 else { return 0 }
        return CGFloat(progress.current) / CGFloat(progress.total)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Color.segmentTrack)
                Capsule().fill(Theme.Color.accent).frame(width: geometry.size.width * fraction)
            }
        }
    }
}

// MARK: - Audio player

private struct MeetingAudioPlayerView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @ObservedObject var player: AudioPlaybackController
    let record: MeetingRecord

    @State private var audioURL: URL?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Meeting audio", systemImage: "waveform")
                .font(.headline)

            if isLoading {
                ProgressView("Loading audio…")
            } else if let audioURL, player.loadedURL == audioURL {
                VStack(spacing: 10) {
                    Slider(
                        value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                        in: 0...max(player.duration, 0.1)
                    )
                    .disabled(player.duration <= 0)

                    HStack {
                        Text(player.elapsedText)
                        Spacer()
                        Text(player.durationText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Color.textTertiary)
                }

                HStack(spacing: 14) {
                    Button { player.skip(by: -15) } label: {
                        Label("Back 15 seconds", systemImage: "gobackward.15")
                    }
                    .disabled(player.currentTime <= 0)

                    Button { try? player.togglePlayback() } label: {
                        Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button { player.skip(by: 15) } label: {
                        Label("Forward 15 seconds", systemImage: "goforward.15")
                    }
                    .disabled(player.currentTime >= player.duration)

                    Button("Stop") { player.stop() }
                        .disabled(player.currentTime == 0 && player.isPlaying == false)
                }
            } else {
                ContentUnavailableView(
                    "Audio Unavailable",
                    systemImage: "speaker.slash"
                )
            }

            Button("Reveal in Finder") { Task { await appViewModel.revealMeetingAudio(record) } }
        }
        .task(id: record.id) {
            isLoading = true
            audioURL = await appViewModel.prepareMeetingAudio(record)
            isLoading = false
        }
    }
}
