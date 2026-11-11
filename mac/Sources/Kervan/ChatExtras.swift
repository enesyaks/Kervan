import AppKit
import KervanKit
import SwiftUI

/// Changed lines in a monospaced block: additions in green, removals in coral, folded stretches as "⋯".
struct DiffLinesView: View {
    let lines: [DiffLine]
    /// Longer diffs show this many lines and a "show all" button.
    var limit = 80
    @State private var expanded = false

    var body: some View {
        let shown = expanded ? lines : Array(lines.prefix(limit))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(Self.marker(line.kind))
                        .foregroundStyle(Self.tint(line.kind))
                        .frame(width: 10, alignment: .leading)
                    Text(line.kind == .gap ? "⋯" : line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(line.kind == .gap ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.tint(line.kind).opacity(line.kind == .added || line.kind == .removed ? 0.10 : 0))
            }
            if lines.count > limit && !expanded {
                Button(L("Show all (\(lines.count) lines)", "Tümünü göster (\(lines.count) satır)")) { expanded = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(8)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .background(Color.kervanWell.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.chip - 2, style: .continuous))
    }

    private static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context, .gap: " "
        }
    }

    static func tint(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .kervanOasis
        case .removed: .kervanCoral
        case .context, .gap: .secondary
        }
    }
}

/// "+12 −3" in the diff colours.
struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(Color.kervanOasis) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Color.kervanCoral) }
        }
        .font(.caption.monospacedDigit())
        .accessibilityLabel(L("\(added) lines added, \(removed) lines removed", "\(added) satır eklendi, \(removed) satır silindi"))
    }
}

/// The agent's to-do list for this turn, above the composer. Folds to one line.
struct PlanCard: View {
    let entries: [PlanEntry]
    @State private var open = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let done = entries.filter { $0.status == "completed" }.count
        let current = entries.first { $0.status == "in_progress" }
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Motion.pick(Motion.fast, reduce: reduceMotion)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Plan").font(.callout.weight(.semibold))
                    Text("\(done)/\(entries.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    // How far along, as a short stretch of the same road.
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 44, height: 3)
                        Capsule().fill(Color.kervanLapis)
                            .frame(width: 44 * (entries.isEmpty ? 0 : CGFloat(done) / CGFloat(entries.count)), height: 3)
                    }
                    .accessibilityHidden(true)
                    if !open, let current {
                        Text(current.content).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Plan, \(done) of \(entries.count) steps done", "Plan, \(entries.count) adımdan \(done) tamam"))
            .accessibilityHint(open ? L("Collapses", "Daraltır") : L("Expands", "Açar"))

            if open {
                // The plan is a route: stops behind you in lapis on a solid line, the caravan's saffron dot
                // on the step being done, the road ahead dotted.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        let done = entry.status == "completed"
                        let current = entry.status == "in_progress"
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                if current {
                                    Circle().fill(Color.kervanSaffron.opacity(0.25)).frame(width: 17, height: 17)
                                    Circle().fill(Color.kervanSaffron).frame(width: 9, height: 9)
                                } else if done {
                                    Circle().fill(Color.kervanLapis).frame(width: 13, height: 13)
                                    Image(systemName: "checkmark").font(.system(size: 7, weight: .black)).foregroundStyle(Color.kervanOnAccent)
                                } else {
                                    Circle().fill(Color.kervanSurface).frame(width: 11, height: 11)
                                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 9, height: 9)
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text(entry.content)
                                .font(.callout)
                                .foregroundStyle(done ? .secondary : .primary)
                                .fontWeight(current ? .semibold : .regular)
                                // No fixedSize here: a rigid plan card pushes the composer off the bottom of the window.
                                .padding(.top, 1)
                        }
                        .padding(.bottom, index == entries.count - 1 ? 0 : 9)
                        .background(alignment: .leading) {
                            if index < entries.count - 1 {
                                RouteSegment(travelled: done)
                                    .frame(width: 18)
                                    .padding(.top, 16)
                                    .padding(.bottom, -2)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.content), \(done ? L("done", "tamam") : current ? L("in progress", "sürüyor") : L("to do", "sırada"))")
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .softSurface(radius: Radius.card)
    }
}

/// One suggestion over the composer: a slash command, or a workspace file to mention.
struct Suggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    /// What replaces the word being typed.
    let insert: String
    /// A workspace file to attach to the message.
    var file: String?
}

/// The list that pops up while typing "/" or "@": arrows move, Return or Tab picks, Escape closes.
struct SuggestionList: View {
    let suggestions: [Suggestion]
    let selected: Int
    let pick: (Suggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        let on = index == selected
                        Button {
                            pick(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: suggestion.symbol)
                                    .foregroundStyle(on ? Color.white : .secondary)
                                    .frame(width: 16)
                                Text(suggestion.title)
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(suggestion.detail)
                                    .font(.caption)
                                    .foregroundStyle(on ? Color.white.opacity(0.85) : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(on ? Color.white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.chip - 3, style: .continuous)
                                    .fill(on ? Color.kervanLapis : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(suggestion.id)
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { _, index in
                if suggestions.indices.contains(index) { proxy.scrollTo(suggestions[index].id) }
            }
        }
        .softSurface(radius: Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Suggestions", "Öneriler"))
    }
}

/// What ⌘V brings in when the pasteboard holds a picture (a screenshot) rather than text.
enum PastedImage {
    /// Writes the picture as a PNG in a temporary folder, ready to upload; nil when there is none or there is text too.
    @MainActor
    static func take(from pasteboard: NSPasteboard = .general) -> URL? {
        // Text wins: copying from a web page often carries a picture of it as well.
        if pasteboard.string(forType: .string) != nil { return nil }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kervan-paste-\(UUID().uuidString)")
        let file = folder.appendingPathComponent(L("screenshot \(formatter.string(from: .now)).png", "ekran-goruntusu \(formatter.string(from: .now)).png"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
