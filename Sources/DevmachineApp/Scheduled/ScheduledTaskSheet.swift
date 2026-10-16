import SwiftUI
import DevmachineCore

/// New task and Edit task. The agent pickers come from
/// `devmachine scheduled harnesses`, so a new agent needs no app release.
struct ScheduledTaskSheet: View {
    @Environment(\.dmMetrics) private var m
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ScheduledStore.shared
    @EnvironmentObject private var model: AppModel
    let request: ScheduledSheetRequest
    let onSaved: (String) -> Void

    @State private var draft: ScheduledDraft
    @State private var allowDangerous = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmSetup = false

    /// `draft` starts a new task already filled in, as the demo walk shows it.
    init(request: ScheduledSheetRequest, draft: ScheduledDraft? = nil, onSaved: @escaping (String) -> Void) {
        self.request = request
        self.onSaved = onSaved
        switch request {
        case .new:
            let first = ScheduledStore.shared.workspaces.first { $0.installed && $0.error == nil }
                ?? ScheduledStore.shared.workspaces.first
            _draft = State(initialValue: draft ?? ScheduledDraft(workspace: first?.name ?? ""))
        case .edit(let row):
            _draft = State(initialValue: ScheduledDraft(task: row.task, workspace: row.workspace.name))
            let saved = row.task.action
            let alreadyDangerous = saved.isPrompt && ScheduledStore.shared.harness(saved.harness ?? "")?
                .isDangerous(saved.permissionMode ?? "") == true
            _allowDangerous = State(initialValue: alreadyDangerous)
        }
    }

    private var editingID: String? {
        if case .edit(let row) = request { return row.task.id }
        return nil
    }

    private var workspace: ScheduledWorkspace? { store.workspaces.first { $0.name == draft.workspace } }
    private var needsSetup: Bool { editingID == nil && workspace?.installed == false }
    private var harness: ScheduledHarness? { store.harness(draft.harness) }
    private var isDangerous: Bool { draft.kind == .prompt && (harness?.isDangerous(draft.permissionMode) ?? false) }
    private var problem: String? {
        if draft.workspace.isEmpty { return "Pick a workspace." }
        if let problem = draft.problem { return problem }
        if isDangerous && !allowDangerous { return "Confirm the mode with no approvals, or pick another." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editingID == nil ? "New scheduled task" : "Edit scheduled task")
                .font(.dm(17, weight: .semibold))
                .padding([.horizontal, .top], m.pt(18))
                .padding(.bottom, m.space.md)
            ScrollView {
                VStack(alignment: .leading, spacing: m.space.lg) {
                    field("Name") {
                        TextField("Daily briefing", text: $draft.name).dmField()
                    }
                    HStack(alignment: .top, spacing: m.space.md) {
                        field("Workspace") {
                            DMDropdown(
                                label: "",
                                options: store.workspaces.map {
                                    .init(value: $0.name, title: $0.installed ? $0.name : "\($0.name) · not set up")
                                },
                                selection: $draft.workspace)
                            .disabled(editingID != nil)
                        }
                        field("Folder") {
                            TextField("~/dev/app", text: $draft.folder).dmField()
                        }
                    }
                    actionBox
                    if isDangerous { dangerBanner }
                    if draft.kind == .prompt { promptNote }
                    triggerRow
                    field("Stops after") {
                        TextField("30m", text: $draft.timeout).dmField().frame(width: m.pt(120))
                    }
                }
                .padding(.horizontal, m.pt(18))
                .padding(.bottom, m.space.md)
            }
            footer
        }
        .frame(width: m.pt(600), height: m.pt(680))
        .background(Color.dmContentBg)
        .onAppear { if store.harnesses.isEmpty { store.refresh() } }
        .onChange(of: draft.harness) { _, name in
            guard let h = store.harness(name), !h.permissionModes.contains(draft.permissionMode) else { return }
            draft.permissionMode = ""
            draft.model = ""
        }
        .confirmationDialog(
            "Scheduled isn't set up on \(draft.workspace) yet",
            isPresented: $confirmSetup, titleVisibility: .visible
        ) {
            Button("Set up and create") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "This adds the scheduled package to \(draft.workspace) and syncs \(workspace?.machine ?? "its machine"). It takes a minute or two.")
        }
    }

    private var actionBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            DMTabStrip(
                tabs: ScheduledDraft.Kind.allCases, selection: $draft.kind,
                title: { $0 == .prompt ? "Prompt" : "Command" },
                systemImage: { $0 == .prompt ? "sparkles" : "terminal" },
                fontSize: 12, grouped: true)
            .fixedSize()
            .padding(m.space.md)

            if draft.kind == .prompt {
                editor($draft.prompt, placeholder: "Give instructions for how you want this task to go", monospaced: false)
                agentBar
            } else {
                editor($draft.command, placeholder: "make report && git push", monospaced: true)
            }
        }
        .dmSurface(Color.dmBand, radius: DMRadius.tile)
    }

    private func editor(_ text: Binding<String>, placeholder: String, monospaced: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(verbatim: placeholder)
                    .font(.dm(12))
                    .foregroundStyle(Color.dmMuted)
                    .padding(.horizontal, m.space.md + 5)
                    .padding(.vertical, m.space.sm)
            }
            TextEditor(text: text)
                .font(monospaced ? .dm(12, design: .monospaced) : .dm(12))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, m.space.md)
                .padding(.vertical, m.space.sm)
        }
        .frame(height: m.pt(150))
    }

    private var agentBar: some View {
        HStack(spacing: m.space.sm) {
            DMDropdown(
                label: "",
                options: harnessOptions,
                selection: $draft.harness)
            .help("Coding agent")
            DMDropdown(
                label: "",
                options: [.init(value: "", title: "Agent default")] + (harness?.permissionModes ?? []).map {
                    .init(value: $0, title: harness?.isDangerous($0) == true ? "\($0) · no approvals" : $0)
                },
                selection: $draft.permissionMode)
            .help("Permission mode")
            Spacer()
            if let models = harness?.models, !models.isEmpty {
                DMDropdown(label: "", options: modelOptions(models), selection: $draft.model)
                    .help("Model")
            } else {
                TextField("Default model", text: $draft.model)
                    .dmField()
                    .frame(width: m.pt(140))
            }
        }
        .padding(m.space.md)
        .overlay(alignment: .top) { DMHairline() }
    }

    private var harnessOptions: [DMDropdown<String>.Option] {
        var options = store.harnesses.map { DMDropdown<String>.Option(value: $0.name, title: $0.name.capitalized) }
        if store.harness(draft.harness) == nil {
            options.append(.init(value: draft.harness, title: draft.harness.capitalized))
        }
        return options
    }

    private func modelOptions(_ models: [String]) -> [DMDropdown<String>.Option] {
        var options = [DMDropdown<String>.Option(value: "", title: "Default model")]
            + models.map { .init(value: $0, title: $0.capitalized) }
        if !draft.model.isEmpty, !models.contains(draft.model) {
            options.append(.init(value: draft.model, title: draft.model))
        }
        return options
    }

    private var dangerBanner: some View {
        DMBanner(
            message: "\(draft.permissionMode) never asks before it acts: the agent can change or delete anything this account can.",
            systemImage: "exclamationmark.octagon.fill", tint: .red, lineLimit: 3
        ) {
            Toggle("I understand", isOn: $allowDangerous).toggleStyle(.checkbox)
        }
    }

    private var promptNote: some View {
        Text(verbatim: "Runs as \(draft.workspace)'s account, with its own \(draft.harness) login and connectors. Nobody is there to approve a tool: acceptEdits approves file edits only, so a connector such as Linear or email needs auto.")
            .font(.dm(11))
            .foregroundStyle(Color.dmMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var triggerRow: some View {
        VStack(alignment: .leading, spacing: m.space.xs) {
            HStack(spacing: m.space.md) {
                Label("Schedule", systemImage: "clock").font(.dm(12, weight: .semibold))
                DMDropdown(
                    label: "",
                    options: ScheduledDraft.everyChoices.map { .init(value: $0.value, title: $0.title) },
                    selection: $draft.every)
                whenFields
                Spacer()
            }
            Text(verbatim: "Times are in \(draft.timezone).")
                .font(.dm(11))
                .foregroundStyle(Color.dmMuted)
        }
        .padding(m.space.md)
        .dmSurface(Color.dmBand, radius: DMRadius.tile)
    }

    @ViewBuilder
    private var whenFields: some View {
        switch draft.every {
        case "hourly":
            Text("at minute").font(.dm(12)).foregroundStyle(Color.dmMuted)
            DMDropdown(
                label: "",
                options: stride(from: 0, to: 60, by: 5).map { .init(value: $0, title: String(format: ":%02d", $0)) }
                    + (draft.minute % 5 == 0 ? [] : [.init(value: draft.minute, title: String(format: ":%02d", draft.minute))]),
                selection: $draft.minute)
        case "weekly":
            DMDropdown(
                label: "",
                options: ScheduledDraft.weekdays.map { .init(value: $0, title: ScheduledSchedule.weekdayNames[$0] ?? $0) },
                selection: $draft.weekday)
            timeField
        case "monthly":
            Text("on day").font(.dm(12)).foregroundStyle(Color.dmMuted)
            DMDropdown(
                label: "",
                options: (1...31).map { .init(value: $0, title: String($0)) },
                selection: $draft.day)
            timeField
        case "once":
            DatePicker("", selection: dateBinding, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
            timeField
        default:
            timeField
        }
    }

    private var timeField: some View {
        HStack(spacing: m.space.xxs) {
            Text("at").font(.dm(12)).foregroundStyle(Color.dmMuted)
            DMDropdown(
                label: "",
                options: (0..<24).map { .init(value: $0, title: String(format: "%02d", $0)) },
                selection: clockPart(0))
            Text(verbatim: ":").font(.dm(12, weight: .semibold)).foregroundStyle(Color.dmMuted)
            DMDropdown(
                label: "",
                options: minuteChoices.map { .init(value: $0, title: String(format: "%02d", $0)) },
                selection: clockPart(1))
        }
    }

    /// Every five minutes, plus the minute the task already has.
    private var minuteChoices: [Int] {
        let current = clock.minute
        let steps = Array(stride(from: 0, to: 60, by: 5))
        return steps.contains(current) ? steps : (steps + [current]).sorted()
    }

    private var clock: (hour: Int, minute: Int) {
        let parts = draft.at.split(separator: ":").compactMap { Int($0) }
        return (parts.first ?? 9, parts.count > 1 ? parts[1] : 0)
    }

    private func clockPart(_ index: Int) -> Binding<Int> {
        Binding(
            get: { index == 0 ? clock.hour : clock.minute },
            set: { value in
                let (hour, minute) = index == 0 ? (value, clock.minute) : (clock.hour, value)
                draft.at = String(format: "%02d:%02d", hour, minute)
            })
    }

    private var zone: TimeZone { TimeZone(identifier: draft.timezone) ?? .current }

    private var dateBinding: Binding<Date> {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = zone
        return Binding(
            get: { f.date(from: draft.date) ?? Date() },
            set: { draft.date = f.string(from: $0) })
    }

    private var footer: some View {
        HStack(spacing: m.space.md) {
            if let saveError {
                Text(verbatim: saveError)
                    .font(.dm(11))
                    .foregroundStyle(Color.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let problem {
                Text(verbatim: problem).font(.dm(11)).foregroundStyle(Color.dmMuted)
            }
            Spacer()
            DMButton("Cancel", variant: .outline) { dismiss() }
            DMButton(editingID == nil ? "Create" : "Save", isLoading: isSaving) {
                if needsSetup { confirmSetup = true } else { save() }
            }
            .disabled(problem != nil || isSaving)
        }
        .padding(m.pt(18))
    }

    private func save() {
        isSaving = true
        saveError = nil
        let job = needsSetup
            ? model.beginTask(label: "Setting up scheduled on \(draft.workspace)", total: 0, showsCount: false)
            : nil
        Task {
            defer { isSaving = false }
            do {
                let task = try await store.save(draft, editing: editingID, allowDangerous: isDangerous && allowDangerous)
                if let job { model.finishTask(job) }
                onSaved("\(draft.workspace)/\(task.id)")
                dismiss()
            } catch {
                if let job { model.dropTask(job) }
                saveError = error.localizedDescription
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.space.xxs) {
            Text(verbatim: label).font(.dm(11, weight: .semibold))
            content()
        }
    }
}
