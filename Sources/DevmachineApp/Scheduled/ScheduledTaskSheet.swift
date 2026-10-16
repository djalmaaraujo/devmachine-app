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

    init(request: ScheduledSheetRequest, onSaved: @escaping (String) -> Void) {
        self.request = request
        self.onSaved = onSaved
        switch request {
        case .new:
            let first = ScheduledStore.shared.workspaces.first { $0.installed && $0.error == nil }
                ?? ScheduledStore.shared.workspaces.first
            _draft = State(initialValue: ScheduledDraft(workspace: first?.name ?? ""))
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
                .font(.dm(15, weight: .semibold))
                .padding([.horizontal, .top], m.pt(18))
                .padding(.bottom, m.space.md)
            ScrollView {
                VStack(alignment: .leading, spacing: m.space.lg) {
                    field("Name") {
                        TextField("Daily briefing", text: $draft.name).dmField()
                    }
                    HStack(alignment: .top, spacing: m.space.md) {
                        field("Workspace") {
                            Picker(selection: $draft.workspace) {
                                ForEach(store.workspaces) { w in
                                    Text(verbatim: w.installed ? w.name : "\(w.name) (not set up)").tag(w.name)
                                }
                            } label: { EmptyView() }
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
            Picker(selection: $draft.kind) {
                Text("Prompt").tag(ScheduledDraft.Kind.prompt)
                Text("Command").tag(ScheduledDraft.Kind.command)
            } label: { EmptyView() }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(m.space.md)

            if draft.kind == .prompt {
                editor($draft.prompt, placeholder: "Give instructions for how you want this task to go", monospaced: false)
                agentBar
            } else {
                editor($draft.command, placeholder: "make report && git push", monospaced: true)
            }
        }
        .background(Color.dmBand, in: RoundedRectangle(cornerRadius: m.radius.card, style: .continuous))
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
        HStack(spacing: m.space.md) {
            Picker(selection: $draft.harness) {
                ForEach(store.harnesses) { Text(verbatim: $0.name.capitalized).tag($0.name) }
                if store.harness(draft.harness) == nil { Text(verbatim: draft.harness).tag(draft.harness) }
            } label: { EmptyView() }
            .fixedSize()
            .help("Coding agent")

            Picker(selection: $draft.permissionMode) {
                Text("Agent default").tag("")
                ForEach(harness?.permissionModes ?? [], id: \.self) { mode in
                    Text(verbatim: harness?.isDangerous(mode) == true ? "\(mode) (no approvals)" : mode).tag(mode)
                }
            } label: { EmptyView() }
            .fixedSize()
            .help("Permission mode")

            Spacer()

            TextField("Default model", text: $draft.model)
                .dmField()
                .frame(width: m.pt(130))
            if let models = harness?.models, !models.isEmpty {
                Menu {
                    Button("Default model") { draft.model = "" }
                    ForEach(models, id: \.self) { model in
                        Button(model.capitalized) { draft.model = model }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Models")
            }
        }
        .padding(m.space.md)
        .background(Color.dmContentBg.opacity(0.6))
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
                Picker(selection: $draft.every) {
                    ForEach(ScheduledDraft.everyChoices, id: \.value) { Text(verbatim: $0.title).tag($0.value) }
                } label: { EmptyView() }
                .fixedSize()
                whenFields
                Spacer()
            }
            Text(verbatim: "Times are in \(draft.timezone).")
                .font(.dm(11))
                .foregroundStyle(Color.dmMuted)
        }
        .padding(m.space.md)
        .background(Color.dmBand, in: RoundedRectangle(cornerRadius: m.radius.card, style: .continuous))
    }

    @ViewBuilder
    private var whenFields: some View {
        switch draft.every {
        case "hourly":
            Text("at minute").font(.dm(12)).foregroundStyle(Color.dmMuted)
            Picker(selection: $draft.minute) {
                ForEach(0..<60, id: \.self) { Text(verbatim: String(format: ":%02d", $0)).tag($0) }
            } label: { EmptyView() }
            .fixedSize()
        case "weekly":
            Picker(selection: $draft.weekday) {
                ForEach(ScheduledDraft.weekdays, id: \.self) {
                    Text(verbatim: ScheduledSchedule.weekdayNames[$0] ?? $0).tag($0)
                }
            } label: { EmptyView() }
            .fixedSize()
            timeField
        case "monthly":
            Text("on day").font(.dm(12)).foregroundStyle(Color.dmMuted)
            Picker(selection: $draft.day) {
                ForEach(1...31, id: \.self) { Text(verbatim: String($0)).tag($0) }
            } label: { EmptyView() }
            .fixedSize()
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
        DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
    }

    private var zone: TimeZone { TimeZone(identifier: draft.timezone) ?? .current }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let parts = draft.at.split(separator: ":").compactMap { Int($0) }
                var c = Calendar.current
                c.timeZone = zone
                let minute = parts.count > 1 ? parts[1] : 0
                return c.date(bySettingHour: parts.first ?? 9, minute: minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                var c = Calendar.current
                c.timeZone = zone
                let parts = c.dateComponents([.hour, .minute], from: date)
                draft.at = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
            })
    }

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
            DMButton("Cancel", variant: .outline, size: .small) { dismiss() }
            DMButton(editingID == nil ? "Create" : "Save", size: .small, isLoading: isSaving) {
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
