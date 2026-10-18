import MyVaultKit
import SwiftUI

struct ItemGroup: Identifiable {
    var id: String
    var title: String
    var items: [VaultItem]
}

enum Grouping {
    /// Favorites first (in "All Items"), then A-Z, the way the design groups them.
    static func groups(nav: Nav, items: [VaultItem], searching: Bool) -> [ItemGroup] {
        if searching { return items.isEmpty ? [] : [ItemGroup(id: "results", title: "Results", items: items)] }
        switch nav {
        case .favorites: return items.isEmpty ? [] : [ItemGroup(id: "fav", title: "Favorites", items: items)]
        case .recent: return items.isEmpty ? [] : [ItemGroup(id: "recent", title: "Recently Used", items: items)]
        default: break
        }
        var result = [ItemGroup]()
        var rest = items
        if nav == .all || nav == .settings || nav == .security {
            let favs = items.filter(\.favorite)
            if !favs.isEmpty { result.append(ItemGroup(id: "fav", title: "Favorites", items: favs)) }
            rest = items.filter { !$0.favorite }
        }
        let byLetter = Dictionary(grouping: rest) { item -> String in
            let first = item.name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
            return first.first?.isLetter == true ? first : "#"
        }
        for key in byLetter.keys.sorted() {
            result.append(ItemGroup(id: "l-\(key)", title: key, items: byLetter[key]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
        }
        return result
    }
}
