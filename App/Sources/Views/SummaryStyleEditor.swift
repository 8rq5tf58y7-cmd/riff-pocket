import SwiftUI
import RiffCore

/// Edit how a summary looks. Used per note (Summary tab) and for templates (Settings).
struct SummaryStyleEditor: View {
    @Binding var style: SummaryStyle
    var title = "Summary style"
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var newSection = ""
    @State private var showSaveAs = false
    @State private var saveName = ""
    @State private var toast: String?

    var body: some View {
        Form {
            Section {
                Menu {
                    ForEach(settings.settings.allStyles) { s in
                        Button { style = s } label: {
                            if s.id == style.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                        }
                    }
                } label: {
                    LabeledContent("Start from") { Text(style.name).foregroundStyle(Theme.accent) }
                }
            } header: { SectionLabel("Template") }

            Section {
                picker("Format", selection: $style.format, cases: SummaryStyle.Format.allCases) { $0.label }
                picker("Length", selection: $style.length, cases: SummaryStyle.Length.allCases) { $0.label }
                picker("Tone", selection: $style.tone, cases: SummaryStyle.Tone.allCases) { $0.label }
            } header: { SectionLabel("Shape") }

            Section {
                ForEach(Array(style.sections.enumerated()), id: \.offset) { i, _ in
                    TextField("Section", text: Binding(
                        get: { i < style.sections.count ? style.sections[i] : "" },
                        set: { if i < style.sections.count { style.sections[i] = $0 } }
                    ))
                }
                .onDelete { style.sections.remove(atOffsets: $0) }
                .onMove { style.sections.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("Add a section, e.g. Risks", text: $newSection)
                        .onSubmit(addSection)
                    Button("Add", action: addSection).disabled(newSection.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { SectionLabel("Sections") } footer: {
                Text(style.sections.isEmpty ? "No sections — the model picks headings that fit." : "Shown as headings, in this order. Swipe to delete; long-press to reorder.")
            }

            Section {
                TextField("What these recordings usually are, e.g. a team meeting", text: $style.context)
                Toggle("Include timestamps", isOn: $style.includeTimestamps)
                TextField("Language (blank = same as recording)", text: $style.language)
                TextField("Anything else? e.g. “Use plain language”, “Flag risks in bold”", text: $style.customInstructions, axis: .vertical)
                    .lineLimit(2...6)
            } header: { SectionLabel("Details") }

            Section {
                DisclosureGroup("Prompt the model receives") {
                    Text(style.instructions).font(Theme.monoSmall).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }

            Section {
                Button("Save as new template…", systemImage: "square.and.arrow.down") {
                    saveName = style.isBuiltIn ? "\(style.name) (mine)" : style.name
                    showSaveAs = true
                }
                if !style.isBuiltIn, settings.settings.customStyles.contains(where: { $0.id == style.id }) {
                    Button("Update template “\(style.name)”", systemImage: "arrow.triangle.2.circlepath") {
                        settings.settings.saveStyle(style)
                        toast = "Template updated."
                    }
                }
                Button(settings.settings.defaultStyleId == style.id ? "This is the default for new notes" : "Make this the default for new notes",
                       systemImage: "star") { makeDefault() }
                    .disabled(settings.settings.defaultStyleId == style.id && settings.settings.defaultStyle == style)
            } footer: {
                if let toast { Text(toast).foregroundStyle(Theme.success) }
            }
        }
        .themedList()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Save template", isPresented: $showSaveAs) {
            TextField("Name", text: $saveName)
            Button("Save") {
                let name = saveName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let saved = style.copy(named: name)
                settings.settings.saveStyle(saved)
                style = saved
                toast = "Saved “\(name)” to your templates."
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func picker<T: Hashable & Identifiable>(_ label: String, selection: Binding<T>, cases: [T],
                                                    title: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
            Picker(label, selection: selection) {
                ForEach(cases) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func addSection() {
        let s = newSection.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        style.sections.append(s)
        newSection = ""
    }

    private func makeDefault() {
        if let existing = settings.settings.style(id: style.id), existing == style {
            settings.settings.defaultStyleId = style.id
        } else {
            // Edited: keep the edits as a template so the default is exactly what's on screen.
            let saved = style.isBuiltIn ? style.copy(named: "\(style.name) (mine)") : style
            settings.settings.saveStyle(saved)
            settings.settings.defaultStyleId = saved.id
            style = saved
        }
        toast = "New notes will use “\(style.name)”."
    }
}

/// Settings → Summary templates.
struct SummaryTemplatesView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        List {
            Section {
                ForEach(SummaryStyle.builtIn) { s in row(s) }
            } header: { SectionLabel("Built in") }
            Section {
                ForEach(settings.settings.customStyles) { s in row(s) }
                    .onDelete { offsets in
                        offsets.map { settings.settings.customStyles[$0].id }.forEach { settings.settings.deleteStyle(id: $0) }
                    }
                NavigationLink {
                    NewTemplateView()
                } label: {
                    Label("New template", systemImage: "plus")
                }
            } header: { SectionLabel("Yours") } footer: {
                Text("Every note can also have its own style — open a note's Summary tab and tap the style chip.")
            }
        }
        .themedList()
        .navigationTitle("Summary templates")
    }

    private func row(_ s: SummaryStyle) -> some View {
        NavigationLink {
            TemplateEditorHost(original: s)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                    Text("\(s.format.label) · \(s.length.label) · \(s.sections.isEmpty ? "free-form" : "\(s.sections.count) sections")")
                        .font(Theme.monoSmall).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if settings.settings.defaultStyleId == s.id { StatusPill(text: "default", systemImage: "star.fill", color: Theme.accent) }
            }
        }
    }
}

/// Holds a working copy so built-in templates are never modified in place.
private struct TemplateEditorHost: View {
    let original: SummaryStyle
    @State private var working: SummaryStyle

    init(original: SummaryStyle) {
        self.original = original
        _working = State(initialValue: original)
    }

    var body: some View {
        SummaryStyleEditor(style: $working, title: original.name)
    }
}

private struct NewTemplateView: View {
    @State private var working = SummaryStyle.meeting.copy(named: "My template")
    var body: some View {
        SummaryStyleEditor(style: $working, title: "New template")
    }
}
