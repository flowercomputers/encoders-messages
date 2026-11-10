import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !model.filter.isEmpty {
                Label(model.filter, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(.background)
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search your messages by meaning", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($searchFocused)
                .onSubmit { model.openSelection() }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.escape) { model.query = ""; return .handled }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .needsAccess(let reason):
            AccessView(reason: reason) { model.openPrivacySettings() }
        case .loading where model.hits.isEmpty:
            VStack(spacing: 10) {
                ProgressView()
                Text(model.indexed > 0 ? "Indexing… \(model.indexed.formatted()) messages" : "Reading messages…")
                    .foregroundStyle(.secondary)
            }
        default:
            if model.hits.isEmpty {
                Text(model.query.isEmpty ? "Describe what you remember. It doesn't have to be the exact words." : "No matches")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                results
            }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                        HitRow(hit: hit, selected: index == model.selection)
                            .id(hit.id)
                            .onAppear { model.loadMoreIfNeeded(near: index) }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                model.open(hit)
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selection) { _, selection in
                if model.hits.indices.contains(selection) {
                    proxy.scrollTo(model.hits[selection].id)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.phase == .ready {
                Text("\(model.indexed.formatted()) messages · read in \(seconds(model.stats.readSeconds)) · embedded in \(seconds(model.stats.embedSeconds))")
            }
            Spacer()
            if !model.hits.isEmpty {
                Text("\(model.hits.count.formatted())\(model.canLoadMore ? "+" : "") results · searched in \(seconds(model.searchSeconds)) · ↩ opens in Messages")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func seconds(_ s: Double) -> String {
        s < 1 ? String(format: "%.1f ms", s * 1000) : String(format: "%.2f s", s)
    }
}

private struct HitRow: View {
    let hit: Hit
    let selected: Bool

    var body: some View {
        let dim = selected ? Color.white.opacity(0.75) : Color.secondary
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(hit.chat).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.format(hit.date)).foregroundStyle(dim).monospacedDigit()
            }
            .font(.subheadline)
            // The exchange: the matched message at full strength, its neighbours dimmed.
            ForEach(hit.lines) { line in
                HStack(alignment: .top, spacing: 0) {
                    Text(line.sender + "  ").font(.subheadline.weight(.medium)).foregroundStyle(dim)
                    VStack(alignment: .leading, spacing: 4) {
                        if !line.text.isEmpty {
                            Text(line.text)
                                .foregroundStyle(line.isMatch ? (selected ? Color.white : Color.primary) : dim)
                                .lineLimit(line.isMatch ? 4 : 2)
                        }
                        if !line.attachments.isEmpty {
                            AttachmentStrip(attachments: line.attachments, dimmed: !line.isMatch, onAccent: selected)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
    }

    private static let thisYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        return f
    }()
    private static let otherYears: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return f
    }()

    private static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: .now)
        return (sameYear ? thisYear : otherYears).string(from: date)
    }
}

private struct AccessView: View {
    let reason: String
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Message Search needs Full Disk Access")
                .font(.title3.weight(.semibold))
            Text("Your messages live in a protected folder. Turn on Message Search under Privacy & Security → Full Disk Access, then come back. Everything stays on this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Button("Open Full Disk Access Settings", action: openSettings)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("If nothing changes after you turn it on, quit and reopen the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
    }
}
