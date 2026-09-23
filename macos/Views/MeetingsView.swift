import SwiftUI
import UniformTypeIdentifiers

/// The state a meeting's list row surfaces as a chip. Pure mapping from
/// `MeetingDisplayState`, kept separate from the row view so it is testable
/// without instantiating SwiftUI.
enum MeetingRowChip: Equatable {
    case none
    case transcribing
    case transcriptFailed
    case notesFailed

    init(state: MeetingDisplayState) {
        switch state {
        case .transcribing, .generatingNotes:
            self = .transcribing
        case .transcriptFailed:
            self = .transcriptFailed
        case .notesFailed:
            self = .notesFailed
        case .captured, .transcriptReady, .complete:
            self = .none
        }
    }
}

/// The single "Meetings" workspace: a fixed sidebar (record/import actions,
/// search, the meeting list) and a detail pane for the selected meeting.
/// Below ~700pt wide the sidebar collapses and the detail gets a back button.
struct MeetingsView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @EnvironmentObject private var coordinator: MeetingOperationCoordinator
    @State private var searchText = ""
    @State private var showImporter = false
    @State private var importError: String?
    @State private var isFileDropTargeted = false

    private static let narrowThreshold: CGFloat = 700

    private var presenter: MeetingHistoryMetadataPresenter { MeetingHistoryMetadataPresenter() }
    private var filteredRecords: [MeetingRecord] { presenter.filter(coordinator.records, query: searchText) }
    private var selectedRecord: MeetingRecord? {
        coordinator.records.first { $0.id == appViewModel.selectedMeetingID }
    }

    var body: some View {
        GeometryReader { geometry in
            let isNarrow = geometry.size.width < Self.narrowThreshold
            HStack(spacing: 0) {
                if isNarrow == false || selectedRecord == nil {
                    sidebar
                        .frame(width: isNarrow ? geometry.size.width : 300)
                }
                if isNarrow == false || selectedRecord != nil {
                    detail(isNarrow: isNarrow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Theme.Color.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appViewModel.isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $appViewModel.isSettingsPresented) {
            SettingsView()
        }
        .task {
            await Task.yield()
            reconcileSelection()
        }
        .onChange(of: searchText) { _, _ in reconcileSelection() }
        .onChange(of: coordinator.records.map(\.id)) { _, _ in reconcileSelection() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: RecordingController.supportedAudioFileExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
        ) { result in
            switch result {
            case .success(let url):
                importError = nil
                Task { await appViewModel.importDroppedAudioFiles([url]) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard coordinator.bootstrapState == .ready else { return false }
            let fileURLs = urls.filter(\.isFileURL)
            guard fileURLs.isEmpty == false else { return false }
            Task { await appViewModel.importDroppedAudioFiles(fileURLs) }
            return true
        } isTargeted: { isFileDropTargeted = $0 }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                // While a recording runs this is the only stop control the app
                // window offers, so it must stay reachable even when the
                // recording overlay is switched off in Settings.
                Button {
                    Task {
                        isRecordingInProgress
                            ? await appViewModel.stopRecording()
                            : await appViewModel.startRecording()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isRecordingInProgress {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(.white)
                                .frame(width: 9, height: 9)
                            Text("Stop & save")
                        } else {
                            Circle().fill(.white).frame(width: 9, height: 9)
                            Text("Record meeting")
                        }
                        Text(appViewModel.shortcut.symbolText).foregroundStyle(.white.opacity(0.82))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(isRecordingInProgress ? false : recordingDisabled)
                .accessibilityIdentifier("sidebar.record")

                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import audio")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.textBody)
                .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.Color.controlBorder)
                }
                .disabled(recordingDisabled)
                .accessibilityIdentifier("sidebar.import")
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))

            if coordinator.records.isEmpty == false {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.Color.textTertiary)
                            .imageScale(.small)
                        TextField("Search titles and dates", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .accessibilityIdentifier("sidebar.search")
                        if searchText.isEmpty == false {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.Color.textTertiary)
                                    .imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear Search")
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.Color.controlBorder)
                    }
                    .accessibilityLabel("Search meetings")

                    Text("Searches meeting titles and dates only — not transcript text.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 10, trailing: 14))
            }

            Text("RECENT")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textTertiary)
                .padding(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))

            if coordinator.records.isEmpty {
                Text("No meetings yet. The first one you record or import appears here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 14, trailing: 20))
            } else if filteredRecords.isEmpty {
                Text("No meetings match “\(searchText)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 14, trailing: 20))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredRecords) { record in
                            MeetingListRow(
                                record: record,
                                isSelected: appViewModel.selectedMeetingID == record.id,
                                dateText: presenter.dateText(for: record)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { appViewModel.selectedMeetingID = record.id }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("meeting.row")
                            .contextMenu {
                                Button("Rename") { appViewModel.requestMeetingRename(id: record.id) }
                                    .disabled(coordinator.activeMeetingID == record.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.dangerText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if let recoveryMessage = coordinator.recoveryMessage {
                Text(recoveryMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Color.dangerText)
                    .padding(EdgeInsets(top: 8, leading: 14, bottom: 10, trailing: 14))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.chrome)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Color.border).frame(width: 1)
        }
        .overlay {
            if isFileDropTargeted {
                Theme.Color.accentSoft.opacity(0.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var isRecordingInProgress: Bool {
        switch appViewModel.activity {
        case .recording, .startingRecording, .restartingRecording:
            return true
        default:
            return false
        }
    }

    private var recordingDisabled: Bool {
        coordinator.bootstrapState != .ready
            || appViewModel.isProcessing
            || appViewModel.isUpdateInstallPending
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(isNarrow: Bool) -> some View {
        if coordinator.bootstrapState == .preparing {
            ProgressView("Preparing your meetings…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Color.canvas)
        } else if case .failed(let message) = coordinator.bootstrapState {
            VStack(spacing: 14) {
                ContentUnavailableView(
                    "Meetings Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(message)
                )
                HStack {
                    Button("Try Again") { Task { await appViewModel.retryMeetingBootstrap() } }
                    Button("Reveal Storage") { appViewModel.revealMeetingStorage() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Color.canvas)
        } else if let record = selectedRecord {
            // Keyed by meeting so drafts, tabs and loaded artifacts don't
            // carry over to the next selection.
            MeetingDetailView(record: record, showsBackButton: isNarrow)
                .id(record.id)
        } else {
            welcomePane
        }
    }

    private var welcomePane: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Text("Leave a meeting knowing what was decided\nand where it was said.")
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Record a conversation on this Mac, or import a file you already have. Wisper writes a note you can check against the exact words behind it.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await appViewModel.startRecording() }
                } label: {
                    HStack(spacing: 9) {
                        Circle().fill(.white).frame(width: 10, height: 10)
                        Text("Record meeting")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(recordingDisabled)

                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import audio")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.textBody)
                .background(Theme.Color.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.Color.controlBorder)
                }
                .disabled(recordingDisabled)
            }

            VStack(spacing: 10) {
                Text("WHAT YOU GET AFTERWARDS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Color.textTertiary)

                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 20) {
                        samplePlaceholder(title: "Decisions", secondBarWidth: 0.78)
                        samplePlaceholder(title: "Next steps", secondBarWidth: 0.62)
                        samplePlaceholder(title: "Open questions", secondBarWidth: 0.70)
                    }

                    Rectangle()
                        .fill(Theme.Color.border)
                        .frame(height: 1)

                    HStack(spacing: 10) {
                        Text("From transcript")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Color.textBody)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Theme.Color.segmentTrack, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("Every line opens to the exact words it came from.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
                .background(Theme.Color.quoteBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.Color.border)
                }
            }

            Text("Audio and transcript text are sent to OpenAI for transcription and note writing. The recording, transcript and notes are stored on this Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Color.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.canvas)
    }

    /// One column of the welcome pane's sample note: a heading over two
    /// placeholder bars standing in for a written line.
    private func samplePlaceholder(title: String, secondBarWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.textBody)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.Color.skeleton)
                .frame(height: 8)
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Color.skeleton)
                    .frame(width: proxy.size.width * secondBarWidth, height: 8)
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func reconcileSelection() {
        if let selected = appViewModel.selectedMeetingID,
           coordinator.records.contains(where: { $0.id == selected }) {
            return
        }
        appViewModel.selectedMeetingID = nil
    }
}

/// One row in the meeting list: plain, selected, transcribing or notes-failed.
private struct MeetingListRow: View {
    let record: MeetingRecord
    let isSelected: Bool
    let dateText: String

    private var chip: MeetingRowChip { MeetingRowChip(state: record.displayState) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.Color.accentSoftText : Theme.Color.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(dateText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isSelected ? Theme.Color.accentSoftText.opacity(0.75) : Theme.Color.textTertiary)
            }

            switch chip {
            case .none:
                Text(record.displayState.statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? Theme.Color.accentSoftText.opacity(0.75) : Theme.Color.textTertiary)
                    .lineLimit(1)
            case .transcribing:
                chipLabel("Transcribing", icon: ProgressView().controlSize(.mini), tint: Theme.Color.accentSoftText, fill: .white)
            case .transcriptFailed:
                chipLabel("Transcription failed", icon: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)), tint: Theme.Color.dangerText, fill: Theme.Color.dangerSoft)
            case .notesFailed:
                chipLabel("Notes failed — transcript ready", icon: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)), tint: Theme.Color.dangerText, fill: Theme.Color.dangerSoft)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.Color.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.Color.accent)
                    .frame(width: 3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func chipLabel(_ text: String, icon: some View, tint: Color, fill: Color) -> some View {
        HStack(spacing: 5) {
            icon
            Text(text)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}
