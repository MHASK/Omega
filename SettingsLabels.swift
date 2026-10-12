import SwiftUI

struct SettingsLabelsView: View {
    @ObservedObject var notebook: Notebook
    @State private var labels: [ManagedTaskLabel] = []
    @State private var query = ""
    @State private var editing: String?
    @State private var draft = ""
    @State private var colorMenu: String?
    @State private var removing: ManagedTaskLabel?
    @State private var busy = false
    @State private var message = ""
    @State private var failure = false
    @FocusState private var nameFocused: Bool
    private var scale: CGFloat { CGFloat(notebook.zoom) }
    private var muted: Color { Color(nsColor: Ink.muted) }
    private var filtered: [ManagedTaskLabel] { labels.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        SettingsCard("Task labels", subtitle: "Shared across tasks and subtasks in every open notebook, including archived pages.", scale: scale) {
            if labels.isEmpty && message.isEmpty {
                VStack(spacing: 9 * scale) {
                    OpusIcon(glyph: "\u{f02b}", size: 18 * scale).foregroundStyle(muted)
                    Text("No labels yet").fontWeight(.medium)
                    Text("Add a label from any task or subtask. It will appear here.").font(.system(size: 10 * scale)).foregroundStyle(muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24 * scale)
            } else {
                HStack(spacing: 8 * scale) {
                    OpusIcon(glyph: "\u{f002}", size: 10 * scale).foregroundStyle(muted)
                    TextField("Find a label…", text: $query).textFieldStyle(.plain).font(.system(size: 11 * scale)).accessibilityLabel("Find labels")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark").font(.system(size: 9 * scale)) }.buttonStyle(.plain).accessibilityLabel("Clear label search") }
                }.padding(.bottom, 4 * scale)
                if filtered.isEmpty { Text("No matching labels.").foregroundStyle(muted).padding(.vertical, 14 * scale) }
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { label in
                        labelRow(label)
                        if label.id != filtered.last?.id { Rectangle().fill(Color(nsColor: Ink.separator).opacity(0.5)).frame(height: 1) }
                    }
                }
            }
        } footer: {
            HStack(alignment: .center, spacing: 10 * scale) {
                Text(message.isEmpty ? "\(labels.count) labels · Click a color to change it" : message).foregroundStyle(failure ? Color.red : muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(muted).help("Refresh labels").accessibilityLabel("Refresh labels")
            }
        }
        .disabled(busy)
        .onAppear { reload() }
        .alert("Remove \(removing?.name.uppercased() ?? "label")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove label", role: .destructive) { if let label = removing { change(label, to: nil) }; removing = nil }
        } message: {
            Text("This removes the label from \(removing?.uses ?? 0) tasks and subtasks across your open notebooks. The tasks and their contents stay intact. Previous versions remain in note history.")
        }
    }
    private func labelRow(_ label: ManagedTaskLabel) -> some View {
        let color = Color(nsColor: notebook.labelPastel(label.name).ink)
        return HStack(spacing: 10 * scale) {
            Button { colorMenu = label.id } label: {
                Circle().fill(color).frame(width: 11 * scale, height: 11 * scale).padding(6 * scale)
                    .overlay(Circle().stroke(color.opacity(0.2), lineWidth: 1).padding(2 * scale))
            }.buttonStyle(.plain).accessibilityLabel("Color for \(label.name)").help("Change color")
                .popover(isPresented: Binding(get: { colorMenu == label.id }, set: { if !$0 { colorMenu = nil } })) {
                    VStack(alignment: .leading, spacing: 12 * scale) {
                        Text("Label color").font(.system(size: 11 * scale, weight: .medium)).foregroundStyle(muted)
                        HStack(spacing: 8 * scale) {
                            ForEach(LabelPastel.allCases) { pastel in
                                Button {
                                    do { try notebook.setLabelColor(label.name, pastel); message = "Color saved."; failure = false; colorMenu = nil }
                                    catch { message = error.localizedDescription; failure = true }
                                } label: {
                                    Circle().fill(Color(nsColor: pastel.ink)).frame(width: 21 * scale, height: 21 * scale)
                                        .overlay { if notebook.labelPastel(label.name) == pastel { Image(systemName: "checkmark").font(.system(size: 9 * scale, weight: .semibold)).foregroundStyle(Color(nsColor: Ink.paper)) } }
                                }.buttonStyle(.plain).help(pastel.name).accessibilityLabel("\(pastel.name) label color").accessibilityAddTraits(notebook.labelPastel(label.name) == pastel ? [.isSelected] : [])
                            }
                        }
                    }.padding(14 * scale)
                }
            if editing == label.id {
                TextField("Label name", text: $draft).textFieldStyle(.plain).focused($nameFocused).onSubmit { change(label, to: draft) }.onExitCommand { editing = nil }
                    .padding(5 * scale).background(Color(nsColor: Ink.paper), in: RoundedRectangle(cornerRadius: 3 * scale)).accessibilityLabel("Rename label")
                Button { change(label, to: draft) } label: { Image(systemName: "checkmark") }.buttonStyle(.plain).accessibilityLabel("Save label name")
                Button { editing = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(muted).accessibilityLabel("Cancel label rename")
            } else {
                Button { editing = label.id; draft = label.name; nameFocused = true } label: {
                    Text(label.name.uppercased()).font(.system(size: 9 * scale, weight: .medium)).tracking(0.4).foregroundStyle(color)
                        .padding(.horizontal, 7 * scale).padding(.vertical, 4 * scale).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4 * scale)).lineLimit(1)
                }.buttonStyle(.plain).help("Rename label").accessibilityLabel("Rename \(label.name)")
                Spacer(minLength: 0)
                Text("\(label.uses)").font(.system(size: 10 * scale)).monospacedDigit().foregroundStyle(muted).help("\(label.uses) tasks and subtasks")
                Menu {
                    Button("Rename") { editing = label.id; draft = label.name; nameFocused = true }
                    Button("Remove label…", role: .destructive) { removing = label }
                } label: { Image(systemName: "ellipsis").foregroundStyle(muted).frame(width: 20 * scale) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(label.name)")
            }
        }.font(.system(size: 11 * scale)).padding(.vertical, 9 * scale)
    }
    private func reload() {
        do { labels = TaskLabelCatalog.labels(in: try TaskLabelCatalog.pages(in: notebook.roots)); message = ""; failure = false }
        catch { message = error.localizedDescription; failure = true }
    }
    private func change(_ label: ManagedTaskLabel, to name: String?) {
        busy = true
        notebook.changeLabel(label.name, to: name) { error in
            busy = false
            if let error { reload(); message = error; failure = true }
            else { editing = nil; reload(); message = name == nil ? "Label removed. Tasks kept intact." : "Label renamed across your notebooks." }
        }
    }
}
