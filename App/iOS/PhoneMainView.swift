#if os(iOS)
import MyVaultKit
import SwiftUI

struct PhoneMainView: View {
    enum Tab { case vault, generator, security, settings }

    @Environment(AppModel.self) private var model
    @State private var tab = Tab.vault
    @State private var path: [UUID] = []

    var body: some View {
        Group {
            switch tab {
            case .vault: NavigationStack(path: $path) { PhoneHome() }
            case .generator: NavigationStack { GeneratorView() }
            case .security: NavigationStack { SecurityCenterView() }
            case .settings: NavigationStack { SettingsView() }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VaultTabBar(selection: $tab) { model.lock() }
        }
        .background(VT.background)
        .onChange(of: model.openItemRequest) { _, id in
            guard let id else { return }
            tab = .vault
            path = [id]
            model.openItemRequest = nil
        }
    }
}

struct VaultTabBar: View {
    @Binding var selection: PhoneMainView.Tab
    var onLock: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: 0) {
                item(.vault, "SafeVault", "lock.square")
                item(.generator, "Generator", "wand.and.stars")
                Spacer().frame(maxWidth: .infinity)
                item(.security, "Security", "checkmark.shield")
                item(.settings, "Settings", "gearshape")
            }
            .padding(.top, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)

            Button(action: onLock) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(VT.appGradient, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 5).padding(-5))
                    .shadow(color: VT.blue.opacity(0.45), radius: 12, y: 8)
            }
            .buttonStyle(.plain)
            .offset(y: -18)
            .accessibilityLabel("Lock vault")
        }
        .frame(height: 56)
        .background {
            Rectangle().fill(.regularMaterial)
                .overlay(alignment: .top) { Rectangle().fill(VT.line).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func item(_ tab: PhoneMainView.Tab, _ title: String, _ icon: String) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21)).frame(height: 26)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selection == tab ? VT.blue : VT.ink3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

struct PhoneHome: View {
    @Environment(AppModel.self) private var model
    @State private var editingNew: VaultItem?
    @FocusState private var searchFocused: Bool

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        @Bindable var model = model
        let visible = model.visibleItems
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 10) {
                        AppMark(size: 36)
                        Text("SafeVault").font(.system(size: 30, weight: .bold)).tracking(-0.9)
                    }
                    Spacer()
                    Menu {
                        ForEach(ItemKind.allCases, id: \.self) { kind in
                            Button(kind.title, systemImage: MacOrPhoneIcon.icon(kind)) { editingNew = model.newItem(kind: kind) }
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("New item")
                }
                .padding(.top, 4)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VT.ink3)
                    TextField("Search items…", text: $model.searchText)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if searching {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(VT.ink3) }
                            .accessibilityLabel("Clear search")
                    } else {
                        Image(systemName: "viewfinder").foregroundStyle(VT.blue).accessibilityHidden(true)
                    }
                }
                .font(.system(size: 15))
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(Color(hex: 0x767C8C, opacity: 0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.top, 8)

                if searching {
                    section("Results", items: visible)
                } else {
                    chips.padding(.top, 14)
                    let groups = Grouping.groups(nav: model.nav, items: visible, searching: false)
                    if groups.isEmpty {
                        VStack(spacing: 6) {
                            Text("Nothing here yet").font(.system(size: 15, weight: .semibold))
                            Text("Tap + to add your first item.").font(.system(size: 13)).foregroundStyle(VT.ink3)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                    // Lazy: only the sections on screen are built, however many items there are.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { g in section(g.title, items: g.items, seeAll: g.id == "fav" && model.nav == .all) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(VT.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: UUID.self) { id in
            if let item = model.items.first(where: { $0.id == id }) {
                ItemDetailView(item: item, showsHeaderActions: false).navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $editingNew) { EditItemView(item: $0, isNew: true) }
        .refreshable { await model.syncNow() }
    }

    private var chips: some View {
        let defs: [(Nav, String, String)] = [
            (.all, "All", "lock"), (.favorites, "Favorites", "star.fill"),
            (.category(.login), "Logins", "key"), (.category(.card), "Cards", "creditcard"),
        ]
        let counts = model.chipCounts
        func count(_ nav: Nav) -> Int {
            switch nav {
            case .all: counts.all
            case .favorites: counts.favorites
            case .category(.login): counts.logins
            default: counts.cards
            }
        }
        return HStack(spacing: 8) {
            ForEach(Array(defs.enumerated()), id: \.offset) { _, d in
                let active = model.nav == d.0
                Button { model.nav = d.0 } label: {
                    VStack(spacing: 1) {
                        Image(systemName: d.2).font(.system(size: 18)).frame(height: 22)
                            .foregroundStyle(active ? .white.opacity(0.9) : (d.0 == .favorites ? VT.star : VT.ink2))
                            .padding(.bottom, 2)
                        Text(d.1).font(.system(size: 11, weight: .semibold))
                        Text("\(count(d.0))").font(.system(size: 11)).foregroundStyle(active ? .white.opacity(0.85) : VT.ink3)
                    }
                    .foregroundStyle(active ? .white : VT.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                    .background(active ? VT.blue : VT.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .shadow(color: active ? VT.blue.opacity(0.4) : Color(hex: 0x16203F, opacity: 0.04), radius: active ? 7 : 1, y: active ? 4 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }

    private func section(_ title: String, items: [VaultItem], seeAll: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 19, weight: .bold)).tracking(-0.4)
                Spacer()
                if seeAll {
                    Button("See All ›") { model.nav = .favorites }.font(.system(size: 13.5)).foregroundStyle(VT.blue)
                }
            }
            VaultCard {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().overlay(VT.line).padding(.leading, 58) }
                        NavigationLink(value: item.id) {
                            HStack(spacing: 12) {
                                ServiceTile(name: item.name, kind: item.kind, icon: item.icon, symbol: item.tileSymbol, color: item.tileColor, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(VT.ink).lineLimit(1)
                                    Text(item.subtitle).font(.system(size: 12)).foregroundStyle(VT.ink3).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Button { model.toggleFavorite(item.id) } label: {
                                    Image(systemName: item.favorite ? "star.fill" : "star").font(.system(size: 15))
                                        .foregroundStyle(item.favorite ? VT.star : Color(hex: 0xC3CAD6))
                                        .frame(width: 36, height: 36).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(item.favorite ? "Remove from favorites" : "Add to favorites")
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 18)
    }
}

enum MacOrPhoneIcon {
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
#endif
