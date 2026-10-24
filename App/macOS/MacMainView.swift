#if os(macOS)
import MyVaultKit
import SwiftUI

struct MacMainView: View {
    @Environment(AppModel.self) private var model
    @State private var editingNew: VaultItem?

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } content: {
            ItemListColumn()
                .navigationSplitViewColumnWidth(min: 290, ideal: 316, max: 400)
        } detail: {
            DetailColumn()
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    AppMark(size: 26)
                    Text("SafeVault").font(.system(size: 16, weight: .bold)).tracking(-0.3)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(ItemKind.allCases, id: \.self) { kind in
                        Button(kind.title, systemImage: Self.icon(kind)) { editingNew = model.newItem(kind: kind) }
                    }
                } label: {
                    Label("New Item", systemImage: "plus")
                }
                .help("New item (⌘N)")
                Button { model.lock() } label: { Label("Lock", systemImage: "lock") }
                    .help("Lock vault (⌘L)")
            }
        }
        .sheet(item: $editingNew) { EditItemView(item: $0, isNew: true) }
        .overlay(alignment: .bottomTrailing) { ExtensionPrompt() }
        .onChange(of: model.newItemRequest) { _, kind in
            guard let kind else { return }
            editingNew = model.newItem(kind: kind)
            model.newItemRequest = nil
        }
    }

    static func icon(_ kind: ItemKind) -> String {
        switch kind {
        case .login: "key"
        case .card: "creditcard"
        case .note: "note.text"
        case .identity: "person.text.rectangle"
        case .wifi: "wifi"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding<Nav?>(get: { model.nav }, set: { if let v = $0 { model.nav = v } })) {
            Section {
                row(.all, "All Items", "list.bullet")
                row(.favorites, "Favorites", "star")
                row(.recent, "Recently Used", "clock")
            }
            Section("Vaults") {
                ForEach(model.vaultNames, id: \.self) { name in
                    row(.vault(name), name, name == "Work" ? "briefcase" : "person.fill")
                }
            }
            Section("Categories") {
                ForEach(ItemKind.allCases, id: \.self) { kind in
                    row(.category(kind), Self.title(kind), MacMainView.icon(kind))
                }
            }
            Section {
                row(.security, "Security Center", "checkmark.shield", count: false)
                row(.archived, "Archived", "archivebox")
                row(.settings, "Settings", "gearshape", count: false)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncCard().padding(12) }
    }

    static func title(_ kind: ItemKind) -> String {
        switch kind {
        case .login: "Logins"
        case .card: "Credit Cards"
        case .note: "Secure Notes"
        case .identity: "Identities"
        case .wifi: "Wi-Fi"
        }
    }

    private func row(_ nav: Nav, _ title: String, _ icon: String, count: Bool = true) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count {
                    let n = model.count(for: nav)
                    if n > 0 { Text("\(n)").font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit() }
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(nav)
    }
}

struct SyncCard: View {
    @Environment(AppModel.self) private var model

    private var statusColor: Color {
        if model.syncPaused { return VT.ink3 }
        return switch model.syncStatus {
        case .idle: VT.green
        case .syncing: VT.amber
        case .offline: VT.ink3
        case .quotaExceeded: VT.amber
        case .failed: VT.red
        case .notConfigured: VT.ink3
        }
    }

    private var detail: String {
        if model.syncPaused { return "Tap to resume" }
        switch model.syncStatus {
        case .notConfigured: return "Tap to connect"
        case .syncing: return "Encrypting changes"
        case .offline: return "Will sync when online"
        case .quotaExceeded: return "Free space to sync"
        case .failed(let m): return m
        case .idle:
            guard let t = model.lastSync else { return "Not synced yet" }
            return Calendar.current.isDateInToday(t) ? "Today at \(t.formatted(date: .omitted, time: .shortened))" : t.formatted(date: .abbreviated, time: .shortened)
        }
    }

    var body: some View {
        Button {
            if model.syncLinked { Task { await model.syncNow() } } else { model.nav = .settings }
        } label: {
            HStack(spacing: 10) {
                ServiceTile(name: model.provider.title, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                            .shadow(color: statusColor.opacity(0.3), radius: 3)
                        Text(model.syncDescription).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(VT.ink).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(VT.ink3).padding(.leading, 13).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(VT.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(VT.line))
            .shadow(color: Color(hex: 0x16203F, opacity: 0.04), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.syncDescription). \(detail)")
    }
}

// MARK: - List column

struct ItemListColumn: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var groups: [ItemGroup] { Grouping.groups(nav: model.nav, items: model.visibleItems, searching: searching) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VT.ink3)
                    TextField("Search in Personal Vault…", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { model.searchText = ""; searchFocused = false }
                    Text("⌘K").font(.system(size: 11.5)).foregroundStyle(VT.ink3)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(searchFocused ? VT.surface : Color(hex: 0xEFF2F7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(searchFocused ? VT.blue : .clear, lineWidth: 1.5))
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .medium)).foregroundStyle(VT.ink2)
                    .frame(width: 32, height: 32).accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if groups.isEmpty {
                EmptyList(searching: searching, query: model.searchText)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                Text(group.title)
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(VT.ink2)
                                    .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
                                ForEach(group.items) { item in
                                    Button { select(item) } label: {
                                        ItemRow(item: item, selected: item.id == model.selectedID && model.nav != .security && model.nav != .settings) {
                                            model.toggleFavorite(item.id)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                    .contextMenu {
                                        Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(item.id) }
                                        Button(item.archived ? "Restore" : "Archive") { model.setArchived(item.id, !item.archived) }
                                        Divider()
                                        Button("Delete", role: .destructive) { model.delete(item.id) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 16)
                    }
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
        .background(VT.surface)
        .onChange(of: model.focusSearchTick) { searchFocused = true }
    }

    private func select(_ item: VaultItem) {
        if model.nav == .security || model.nav == .settings { model.nav = .all }
        model.selectedID = item.id
        listFocused = true
    }

    private func move(_ delta: Int) {
        let flat = groups.flatMap(\.items)
        guard !flat.isEmpty else { return }
        let idx = flat.firstIndex { $0.id == model.selectedID } ?? (delta > 0 ? -1 : flat.count)
        model.selectedID = flat[min(flat.count - 1, max(0, idx + delta))].id
    }
}

struct EmptyList: View {
    let searching: Bool
    let query: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: searching ? "magnifyingglass" : "tray")
                .font(.system(size: 20)).foregroundStyle(VT.ink3)
                .frame(width: 48, height: 48).background(Color(hex: 0xEEF1F7), in: Circle())
                .padding(.bottom, 6)
            Text(searching ? "No results" : "Nothing here yet").font(.system(size: 14.5, weight: .semibold))
            Text(searching ? "Nothing matches “\(query)”." : "Items you add to this section will appear here.")
                .font(.system(size: 13)).foregroundStyle(VT.ink3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.horizontal, 24)
        Spacer()
    }
}

// MARK: - Detail column

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.nav {
        case .security:
            SecurityCenterView()
        case .settings:
            SettingsView()
        default:
            if let item = model.selectedItem, model.visibleItems.contains(where: { $0.id == item.id }) {
                ItemDetailView(item: item).id(item.id)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "lock")
                        .font(.system(size: 20)).foregroundStyle(VT.ink3)
                        .frame(width: 48, height: 48).background(Color(hex: 0xEEF1F7), in: Circle())
                        .padding(.bottom, 6)
                    Text("Select an item").font(.system(size: 14.5, weight: .semibold))
                    Text("Choose something from the list to see its details.").font(.system(size: 13)).foregroundStyle(VT.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VT.detailBackground)
            }
        }
    }
}
#endif
