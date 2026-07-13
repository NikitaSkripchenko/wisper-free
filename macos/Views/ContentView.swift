import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        Group {
            if appViewModel.onboardingCompleted {
                NavigationSplitView(columnVisibility: $splitViewVisibility) {
                    List(SidebarSection.allCases, selection: $appViewModel.selectedSection) { section in
                        Label(section.rawValue, systemImage: section.systemImage)
                            .tag(section)
                    }
                    .navigationTitle("Wisper")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                } detail: {
                    switch appViewModel.selectedSection ?? .record {
                    case .record:
                        RecordView()
                    case .history:
                        HistoryView()
                    case .settings:
                        SettingsView()
                    }
                }
            } else {
                OnboardingView()
            }
        }
        .alert("Wisper", isPresented: errorBinding) {
            Button("OK") {
                appViewModel.errorMessage = nil
            }
        } message: {
            Text(appViewModel.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appViewModel.errorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    appViewModel.errorMessage = nil
                }
            }
        )
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up Wisper")
                        .font(.title2.weight(.semibold))
                    Text("Finish local permissions and connect your OpenAI key before the first transcription.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy before processing") {
                LabeledContent {
                    Text("Recordings, transcripts, notes, settings, and meeting history")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Stays on your Mac", systemImage: "lock.macwindow")
                }

                LabeledContent {
                    Text("Selected meeting audio and transcript content needed for transcription and notes")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Sent to OpenAI when processing", systemImage: "arrow.up.forward.app")
                }

                Text("Wisper adds no meeting bot. Record only with everyone’s consent; recording laws vary by location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI") {
                LabeledContent("API key", value: appViewModel.apiKeyStatus)

                HStack {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        appViewModel.saveAPIKey(apiKey)
                        apiKey = ""
                    } label: {
                        Label("Save", systemImage: "key")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Permissions") {
                PermissionSetupRow(
                    title: "Microphone",
                    status: appViewModel.microphonePermissionStatus,
                    requestTitle: "Request",
                    onRequest: { Task { await appViewModel.requestMicrophonePermission() } },
                    onOpenSettings: { appViewModel.openMicrophoneSettings() }
                )

                PermissionSetupRow(
                    title: "Screen & System Audio",
                    status: appViewModel.screenAudioPermissionStatus,
                    requestTitle: "Request",
                    onRequest: { appViewModel.requestScreenAudioPermission() },
                    onOpenSettings: { appViewModel.openScreenAudioSettings() }
                )
            }

            Section {
                Button {
                    appViewModel.completeOnboarding()
                } label: {
                    Label("Finish Setup", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appViewModel.canCompleteOnboarding == false)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Onboarding")
        .onAppear {
            appViewModel.refreshPermissionStatuses()
        }
    }

    private var captureModeBinding: Binding<RecordingCaptureMode> {
        Binding(
            get: { appViewModel.captureMode },
            set: { appViewModel.saveCaptureMode($0) }
        )
    }
}

private struct PermissionSetupRow: View {
    let title: String
    let status: PermissionReadiness
    let requestTitle: String
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                PermissionStatusBadge(status: status)
            }

            Spacer()

            Button(requestTitle, action: onRequest)
                .disabled(status == .granted || status == .unsupported)

            Button("Settings", action: onOpenSettings)
                .disabled(status == .unsupported)
        }
    }
}

private struct PermissionStatusBadge: View {
    let status: PermissionReadiness

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .granted:
            "Ready"
        case .notDetermined:
            "Needs Approval"
        case .denied:
            "Blocked"
        case .unsupported:
            "Unsupported"
        }
    }

    private var tint: Color {
        switch status {
        case .granted:
            .green
        case .notDetermined:
            .orange
        case .denied:
            .red
        case .unsupported:
            .secondary
        }
    }
}

private struct RecordView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @EnvironmentObject private var coordinator: MeetingOperationCoordinator
    @State private var isFileDropTargeted = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 28) {
                Text("Record")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 18) {
                    Image(systemName: recordIconName)
                        .font(.system(size: 72, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(recordIconColor)

                    Text(appViewModel.recorder.isRecording || appViewModel.isProcessing ? appViewModel.recorder.elapsedDisplay : "Ready")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()

                    Text(appViewModel.statusMessage)
                        .foregroundStyle(.secondary)

                    Text("Capture: \(appViewModel.captureModeDescription) • Source: \(appViewModel.activeAudioSourceName)")
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    if appViewModel.recorder.isRecording {
                        Label("Recording in progress", systemImage: "record.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("recording.indicator")
                    }

                    Text("Record only with everyone’s consent. Recording laws vary by location.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if appViewModel.captureMode == .microphoneAndSystemAudio {
                        Text("For the clearest separate sources, use AirPods or headphones during the call.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Picker("Capture Mode", selection: captureModeBinding) {
                            ForEach(RecordingCaptureMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260)
                        .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)

                        Picker("Microphone", selection: audioSourceBinding) {
                            Text("System Default").tag("")
                            ForEach(appViewModel.recorder.audioSources) { source in
                                Text(source.name).tag(source.id)
                            }
                            if let selectedAudioSourceID = appViewModel.selectedAudioSourceID,
                               appViewModel.recorder.audioSources.contains(where: { $0.id == selectedAudioSourceID }) == false {
                                Text("Unavailable Source").tag(selectedAudioSourceID)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)
                        .disabled(appViewModel.captureMode.usesMicrophone == false || appViewModel.recorder.isRecording || appViewModel.isProcessing)

                        Button("Refresh") {
                            appViewModel.refreshAudioSources()
                        }
                        .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if appViewModel.recorder.phase == .recording || appViewModel.recorder.phase == .paused {
                                Task { await appViewModel.stopRecording() }
                            } else {
                                Task { await appViewModel.startRecording() }
                            }
                        } label: {
                            Label(primaryRecordLabel, systemImage: appViewModel.recorder.isRecording ? "stop.fill" : "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(appViewModel.isProcessing || coordinator.bootstrapState != .ready)

                        Button {
                            if appViewModel.recorder.isPaused {
                                appViewModel.resumeRecording()
                            } else {
                                appViewModel.pauseRecording()
                            }
                        } label: {
                            Label(appViewModel.recorder.isPaused ? "Resume" : "Pause", systemImage: appViewModel.recorder.isPaused ? "play.fill" : "pause.fill")
                        }
                        .controlSize(.large)
                        .disabled(appViewModel.recorder.canPause == false || appViewModel.isProcessing)

                        Button(role: .destructive) {
                            Task { await appViewModel.discardRecording() }
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .controlSize(.large)
                        .disabled(appViewModel.recorder.isRecording == false || appViewModel.isProcessing)

                    }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.quaternary)
                }

                Spacer()
            }
            .padding(32)

            if isFileDropTargeted {
                AudioFileDropOverlay(
                    isBusy: appViewModel.recorder.isRecording
                        || appViewModel.isProcessing
                        || coordinator.bootstrapState != .ready
                )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard coordinator.bootstrapState == .ready else { return false }
            let fileURLs = urls.filter(\.isFileURL)
            guard fileURLs.isEmpty == false else { return false }
            Task { await appViewModel.importDroppedAudioFiles(fileURLs) }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.16)) {
                isFileDropTargeted = isTargeted
            }
        }
    }

    private var primaryRecordLabel: String {
        if appViewModel.recorder.phase == .paused { return "Stop and Transcribe" }
        if appViewModel.recorder.phase == .recording { return "Stop and Transcribe" }
        return "Start Recording"
    }

    private var recordIconName: String {
        if appViewModel.isProcessing { return "waveform.badge.magnifyingglass" }
        if appViewModel.recorder.isPaused { return "pause.circle.fill" }
        if appViewModel.recorder.isRecording { return "waveform.circle.fill" }
        return "mic.circle"
    }

    private var recordIconColor: Color {
        if appViewModel.isProcessing { return .blue }
        if appViewModel.recorder.isPaused { return .orange }
        if appViewModel.recorder.isRecording { return .red }
        return .blue
    }

    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appViewModel.selectedAudioSourceID ?? "" },
            set: { appViewModel.saveAudioSource($0.isEmpty ? nil : $0) }
        )
    }

    private var captureModeBinding: Binding<RecordingCaptureMode> {
        Binding(
            get: { appViewModel.captureMode },
            set: { appViewModel.saveCaptureMode($0) }
        )
    }
}

private struct AudioFileDropOverlay: View {
    let isBusy: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: isBusy ? "hourglass" : "waveform.badge.plus")
                    .font(.system(size: 58, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isBusy ? .orange : .blue)

                Text(isBusy ? "Wisper is busy" : "Drop audio to upload")
                    .font(.title2.weight(.semibold))

                Text(isBusy ? "Finish the current recording or transcription before uploading a file." : "Supported: \(RecordingController.supportedAudioFileTypesDescription).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(34)
            .frame(maxWidth: 480)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(isBusy ? .orange.opacity(0.6) : .blue.opacity(0.65), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        }
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @EnvironmentObject private var coordinator: MeetingOperationCoordinator
    @State private var searchText = ""
    @State private var selectionBeforeSearch: UUID?
    @State private var showImporter = false
    @State private var importError: String?

    private var presenter: MeetingHistoryMetadataPresenter {
        MeetingHistoryMetadataPresenter()
    }

    private var filteredRecords: [MeetingRecord] {
        presenter.filter(coordinator.records, query: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("History")
                .font(.title2.weight(.semibold))

            if let recoveryMessage = coordinator.recoveryMessage {
                HStack {
                    Label(recoveryMessage, systemImage: "externaldrive.badge.exclamationmark")
                    Spacer()
                    Button("Reveal Storage") { appViewModel.revealMeetingStorage() }
                }
                .foregroundStyle(.orange)
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }

            if coordinator.bootstrapState == .preparing {
                ProgressView("Preparing history…")
                    .accessibilityIdentifier("history.bootstrap")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .failed(let message) = coordinator.bootstrapState {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "History Unavailable",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(message)
                    )
                    HStack {
                        Button("Try Again") { Task { await appViewModel.retryMeetingBootstrap() } }
                        Button("Reveal Storage") { appViewModel.revealMeetingStorage() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if coordinator.records.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "No Meetings Yet",
                        systemImage: "person.2.wave.2",
                        description: Text("Record or import audio to create your first transcript and grounded notes.")
                    )
                    HStack {
                        Button("Record a meeting") {
                            appViewModel.selectedSection = .record
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("history.record")

                        Button("Import audio…") {
                            showImporter = true
                        }
                        .accessibilityIdentifier("history.import")
                    }
                    .disabled(historyActionsDisabled)

                    if let importError {
                        Label(importError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRecords.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        Button("Clear Search") { searchText = "" }
                            .padding(.bottom, 28)
                    }
            } else {
                HSplitView {
                    List(filteredRecords, selection: $appViewModel.selectedMeetingID) { record in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(record.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Spacer()
                                MeetingStatusPill(state: record.displayState)
                            }
                            Text(presenter.dateText(for: record))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.displayState.statusText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        .tag(record.id)
                        .contextMenu {
                            Button("Rename") {
                                appViewModel.requestMeetingRename(id: record.id)
                            }
                            .disabled(coordinator.activeMeetingID == record.id)
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 320)

                    if let selectedMeetingID = appViewModel.selectedMeetingID,
                       let record = coordinator.records.first(where: { $0.id == selectedMeetingID }) {
                        MeetingDetailView(record: record)
                            .id(record.id)
                    } else {
                        ContentUnavailableView(
                            "Select a Meeting",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Choose a meeting to view notes, the raw transcript, and retained audio.")
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(32)
        .searchable(text: $searchText, prompt: "Search titles and dates")
        .task {
            await Task.yield()
            reconcileSelection()
        }
        .onChange(of: searchText) { oldValue, newValue in
            if oldValue.isEmpty, newValue.isEmpty == false {
                selectionBeforeSearch = appViewModel.selectedMeetingID
            }
            reconcileSelection()
        }
        .onChange(of: coordinator.records.map(\.id)) { _, _ in
            reconcileSelection()
        }
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
    }

    private var historyActionsDisabled: Bool {
        coordinator.bootstrapState != .ready || appViewModel.isProcessing || appViewModel.isUpdateInstallPending
    }

    private func reconcileSelection() {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let selectionBeforeSearch,
           coordinator.records.contains(where: { $0.id == selectionBeforeSearch }) {
            appViewModel.selectedMeetingID = selectionBeforeSearch
            self.selectionBeforeSearch = nil
            return
        }
        if let selected = appViewModel.selectedMeetingID,
           filteredRecords.contains(where: { $0.id == selected }) {
            return
        }
        appViewModel.selectedMeetingID = filteredRecords.first?.id
    }
}

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case transcript = "Raw Transcript"
    case audio = "Audio"

    var id: String { rawValue }
}

private struct MeetingDetailView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @EnvironmentObject private var coordinator: MeetingOperationCoordinator
    let record: MeetingRecord

    @State private var transcript: String?
    @State private var notes: MeetingNotes?
    @State private var loadError: String?
    @State private var confirmRemoval = false
    @State private var selectedTab: MeetingDetailTab = .notes
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var titleError: String?
    @State private var lastRenameAttempt: String?
    @FocusState private var titleFocused: Bool
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if isEditingTitle {
                        TextField("Meeting title", text: $titleDraft)
                            .font(.title2.weight(.semibold))
                            .focused($titleFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                            .accessibilityIdentifier("meeting.rename.field")
                    } else {
                        Button {
                            beginRename()
                        } label: {
                            Text(record.title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.activeMeetingID == record.id)
                        .help("Rename meeting")
                        .accessibilityIdentifier("meeting.title")
                    }
                    Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MeetingStatusPill(state: record.displayState)
                    .accessibilityFocused($statusFocused)
                    .accessibilityIdentifier("meeting.status")
            }

            if let titleError {
                Text(titleError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            stageProgress

            if let failure = activeFailure {
                inlineMessage(failure.message, retryable: failure.isRetryable)
            }

            if let feedback = appViewModel.meetingActionFeedback,
               feedback.meetingID == record.id {
                inlineMessage(feedback.message, retryable: feedback.isRetryable) {
                    retry(feedback.action)
                }
            }

            HStack {
                if record.transcription.status == .failed {
                    Button("Retry Transcription") {
                        Task { await appViewModel.retryTranscription(for: record) }
                    }
                    .disabled(activeFailure?.isRetryable == false)
                } else if record.transcription.status == .completed,
                          record.notes.status == .failed || record.lastValidNotesArtifact != nil {
                    Button(record.lastValidNotesArtifact == nil ? "Retry Notes" : "Regenerate Notes") {
                        Task { await appViewModel.retryNotes(for: record) }
                    }
                    .disabled(activeFailure?.isRetryable == false)
                }
                if coordinator.activeMeetingID == record.id {
                    Button("Cancel", role: .destructive) { coordinator.cancelProcessing() }
                }
                Spacer()
                Menu("More") {
                    Button("Rename") { beginRename() }
                        .disabled(coordinator.activeMeetingID == record.id)
                    Button("Copy Notes") { Task { await appViewModel.copyMeetingNotes(record) } }
                        .disabled(notes == nil)
                    Button("Copy Raw Transcript") { Task { await appViewModel.copyMeetingTranscript(record) } }
                        .disabled(transcript == nil)
                    Button("Play or Stop Audio") { Task { await appViewModel.playMeetingAudio(record) } }
                    Button("Reveal Audio in Finder") { Task { await appViewModel.revealMeetingAudio(record) } }
                    Divider()
                    Button("Remove Meeting", role: .destructive) { confirmRemoval = true }
                        .disabled(coordinator.activeMeetingID == record.id)
                }
                .accessibilityIdentifier("meeting.more")
            }

            Picker("Meeting content", selection: $selectedTab) {
                ForEach(MeetingDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("meeting.tabs")

            ZStack {
                ScrollView {
                    if let notes {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("AI-generated — verify against the transcript")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MeetingNotesSection(title: "Summary", items: notes.summaryPoints)
                            MeetingNotesSection(title: "Decisions", items: notes.decisions)
                            MeetingActionItemsSection(items: notes.actionItems)
                            MeetingNotesSection(title: "Open Questions", items: notes.openQuestions)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    } else {
                        Text(record.notes.status == .processing ? "Generating grounded notes…" : "No valid notes are available yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
                .accessibilityIdentifier("meeting.notes")
                .opacity(selectedTab == .notes ? 1 : 0)
                .allowsHitTesting(selectedTab == .notes)
                .accessibilityHidden(selectedTab != .notes)

                ScrollView {
                    Text(transcript ?? "No transcript is available yet.")
                        .foregroundStyle(transcript == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .accessibilityIdentifier("meeting.transcript")
                .opacity(selectedTab == .transcript ? 1 : 0)
                .allowsHitTesting(selectedTab == .transcript)
                .accessibilityHidden(selectedTab != .transcript)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(record.captureMode.displayName, systemImage: "waveform")
                        if let duration = record.durationSeconds {
                            LabeledContent(
                                "Duration",
                                value: String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
                            )
                        }
                        HStack {
                            Button("Play or Stop") { Task { await appViewModel.playMeetingAudio(record) } }
                            Button("Reveal in Finder") { Task { await appViewModel.revealMeetingAudio(record) } }
                        }
                    }
                    .padding(20)
                }
                .accessibilityIdentifier("meeting.audio")
                .opacity(selectedTab == .audio ? 1 : 0)
                .allowsHitTesting(selectedTab == .audio)
                .accessibilityHidden(selectedTab != .audio)

                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
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
        .onAppear {
            if appViewModel.selectedMeetingID == record.id {
                statusFocused = true
            }
            handleRenameRequest()
        }
        .onChange(of: appViewModel.renameRequestedMeetingID) { _, _ in
            handleRenameRequest()
        }
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

    private var activeFailure: MeetingFailure? {
        record.notes.failure ?? record.transcription.failure
    }

    @ViewBuilder
    private func inlineMessage(
        _ message: String,
        retryable: Bool,
        retry: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle.fill")
            Spacer()
            if retryable, let retry {
                Button("Retry", action: retry)
            }
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
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

    private var stageProgress: some View {
        HStack(spacing: 10) {
            stage("Capture saved", complete: true, active: false)
            Divider().frame(width: 22)
            stage(
                "Transcribing",
                complete: record.transcription.status == .completed,
                active: record.transcription.status == .processing
            )
            Divider().frame(width: 22)
            stage(
                "Generating notes",
                complete: record.lastValidNotesArtifact != nil,
                active: record.notes.status == .processing
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting status: \(record.displayState.statusText)")
    }

    private func stage(_ title: String, complete: Bool, active: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : active ? "clock.fill" : "circle")
            .font(.caption)
            .foregroundStyle(complete ? .green : active ? .blue : .secondary)
    }
}

private struct MeetingNotesSection: View {
    let title: String
    let items: [GroundedMeetingNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text("None captured")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notes.empty")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• \(item.text)")
                        Text("Evidence: “\(item.evidence)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("notes.item")
                }
            }
        }
    }
}

private struct MeetingActionItemsSection: View {
    let items: [MeetingActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Action Items").font(.headline)
            if items.isEmpty {
                Text("None captured")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notes.empty")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• \(item.text)")
                        Text([item.owner, item.dueDate].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Evidence: “\(item.evidence)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct MeetingStatusPill: View {
    let state: MeetingDisplayState

    var body: some View {
        Text(state.statusText)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch state {
        case .complete: .green
        case .transcribing, .generatingNotes: .blue
        case .transcriptFailed, .notesFailed: .red
        case .captured, .transcriptReady: .secondary
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appViewModel: AppViewModel
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                LabeledContent("API key", value: appViewModel.apiKeyStatus)

                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Key") {
                        appViewModel.saveAPIKey(apiKey)
                        apiKey = ""
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Delete Key", role: .destructive) {
                        appViewModel.deleteAPIKey()
                    }
                    .disabled(appViewModel.hasAPIKey == false)
                }
            }

            Section("Audio Capture") {
                Picker("Capture mode", selection: captureModeBinding) {
                    ForEach(RecordingCaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)

                Text("System Audio and Microphone + System Audio capture what you hear, including headset output. These modes require macOS 15 or later in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Microphone", selection: audioSourceBinding) {
                    Text("System Default").tag("")
                    ForEach(appViewModel.recorder.audioSources) { source in
                        Text(source.name).tag(source.id)
                    }
                    if let selectedAudioSourceID = appViewModel.selectedAudioSourceID,
                       appViewModel.recorder.audioSources.contains(where: { $0.id == selectedAudioSourceID }) == false {
                        Text("Unavailable Source").tag(selectedAudioSourceID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appViewModel.captureMode.usesMicrophone == false || appViewModel.recorder.isRecording || appViewModel.isProcessing)

                HStack {
                    LabeledContent("Selected", value: appViewModel.selectedAudioSourceName)
                    Spacer()
                    Button("Refresh") {
                        appViewModel.refreshAudioSources()
                    }
                    .disabled(appViewModel.recorder.isRecording || appViewModel.isProcessing)
                }

                Text("Choose the microphone Wisper should use when the capture mode includes microphone audio. Existing recordings keep their original source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                PermissionSetupRow(
                    title: "Microphone",
                    status: appViewModel.microphonePermissionStatus,
                    requestTitle: "Request",
                    onRequest: { Task { await appViewModel.requestMicrophonePermission() } },
                    onOpenSettings: { appViewModel.openMicrophoneSettings() }
                )

                PermissionSetupRow(
                    title: "Screen & System Audio",
                    status: appViewModel.screenAudioPermissionStatus,
                    requestTitle: "Request",
                    onRequest: { appViewModel.requestScreenAudioPermission() },
                    onOpenSettings: { appViewModel.openScreenAudioSettings() }
                )
            }

            Section("Appearance") {
                Toggle("Show in menu bar only", isOn: Binding(
                    get: { appViewModel.showInMenuBarOnly },
                    set: { appViewModel.saveShowInMenuBarOnly($0) }
                ))

                Text("When enabled, Wisper hides from the Dock and lives in the menu bar. When disabled, Wisper opens as a normal app window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global Shortcut") {
                LabeledContent("Current", value: appViewModel.shortcut.displayText)

                ShortcutCaptureField(shortcut: $appViewModel.shortcut) { shortcut in
                    appViewModel.saveShortcut(shortcut)
                } onInvalid: {
                    appViewModel.shortcutCaptureMessage = "Press at least one modifier plus a key."
                }
                .frame(height: 28)

                Text(appViewModel.shortcutCaptureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset to Command Shift Space") {
                    appViewModel.saveShortcut(.default)
                }
            }

            Section("Chunking") {
                Toggle("Chunk long recordings", isOn: Binding(
                    get: { appViewModel.chunkingEnabled },
                    set: { appViewModel.saveChunkingSettings(enabled: $0) }
                ))

                Stepper(value: Binding(
                    get: { appViewModel.chunkSeconds },
                    set: { appViewModel.saveChunkingSettings(seconds: $0) }
                ), in: 60...3_600, step: 60) {
                    LabeledContent("Chunk length", value: "\(appViewModel.chunkSeconds) seconds")
                }
                .disabled(appViewModel.chunkingEnabled == false)

                Text("When a recording is longer than this, Wisper splits it into local .m4a chunks, transcribes each chunk, then stitches the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                LabeledContent("Stays on your Mac") {
                    Text("Recordings, transcripts, notes, settings, and history")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Sent to OpenAI when processing") {
                    Text("Selected meeting audio and transcript content")
                        .foregroundStyle(.secondary)
                }
                Text("Your API key stays in Keychain. Wisper adds no meeting bot; recording consent remains your responsibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Local log", value: appViewModel.localLogFileURL.path)

                Button {
                    appViewModel.revealLocalLogFile()
                } label: {
                    Label("Reveal Log File", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("Settings")
        .onAppear {
            appViewModel.refreshPermissionStatuses()
        }
    }

    private var audioSourceBinding: Binding<String> {
        Binding(
            get: { appViewModel.selectedAudioSourceID ?? "" },
            set: { appViewModel.saveAudioSource($0.isEmpty ? nil : $0) }
        )
    }

    private var captureModeBinding: Binding<RecordingCaptureMode> {
        Binding(
            get: { appViewModel.captureMode },
            set: { appViewModel.saveCaptureMode($0) }
        )
    }
}
