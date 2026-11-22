import Foundation

enum CatalogStore: String, CaseIterable, Identifiable, Sendable {
    case steam = "Steam"
    case gog = "GOG"

    var id: String { rawValue }
}

struct CatalogGame: Identifiable, Sendable {
    let id: String
    let name: String
    let store: CatalogStore
    let imageURL: URL?
    let productURL: URL
    let price: String?
    let priceAmount: Double?
    let platforms: String
    let steamAppID: Int?
    let supportsMac: Bool
    let supportsWindows: Bool
    let popularityRank: Int
}

enum StoreCatalog {
    struct SearchResult: Sendable {
        let games: [CatalogGame]
        let unavailableStores: Set<CatalogStore>
    }

    static func games(matching query: String) async -> SearchResult {
        await withTaskGroup(of: (CatalogStore, [CatalogGame]?).self) { group in
            group.addTask { (.steam, try? await steamGames(matching: query)) }
            group.addTask { (.gog, try? await gogGames(matching: query)) }
            var games: [CatalogGame] = []
            var unavailable = Set<CatalogStore>()
            for await (store, result) in group {
                if let result { games.append(contentsOf: result) }
                else { unavailable.insert(store) }
            }
            return SearchResult(games: games.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }, unavailableStores: unavailable)
        }
    }

    private static func steamGames(matching query: String) async throws -> [CatalogGame] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: trimmed.isEmpty
            ? "https://store.steampowered.com/api/featuredcategories/"
            : "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = trimmed.isEmpty
            ? [URLQueryItem(name: "cc", value: regionCode), URLQueryItem(name: "l", value: "en")]
            : [URLQueryItem(name: "term", value: trimmed), URLQueryItem(name: "cc", value: regionCode),
               URLQueryItem(name: "l", value: "en")]
        let root = try await object(at: components.url!)
        let freeGames = (try? await steamFreeGames(matching: trimmed)) ?? []
        let items: [[String: Any]]
        if trimmed.isEmpty {
            let sellers = (root["top_sellers"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            items = Array(sellers.prefix(12))
        } else {
            items = root["items"] as? [[String: Any]] ?? []
        }
        var seen = Set<Int>()
        let regularGames: [CatalogGame] = items.enumerated().compactMap { rank, item in
            guard let id = item["id"] as? Int, id > 0,
                  let name = item["name"] as? String, !name.isEmpty,
                  seen.insert(id).inserted,
                  let productURL = URL(string: "https://store.steampowered.com/app/\(id)/") else { return nil }
            let flags = item["platforms"] as? [String: Any]
            let mac = (flags?["mac"] as? Bool) ?? (item["mac_available"] as? Bool) ?? false
            let windows = (flags?["windows"] as? Bool) ?? (item["windows_available"] as? Bool) ?? false
            let image = (item["tiny_image"] ?? item["small_capsule_image"] ?? item["header_image"]) as? String
            let price = item["price"] as? [String: Any]
            let minor = price?["final"] as? Int ?? item["final_price"] as? Int
            let currency = price?["currency"] as? String ?? item["currency"] as? String
            let priceText = minor.map { $0 == 0 ? "Free" : String(format: "%.2f %@", Double($0) / 100, currency ?? "") }
            return CatalogGame(id: "steam-\(id)", name: name, store: .steam,
                               imageURL: image.flatMap(httpsURL), productURL: productURL,
                               price: priceText, priceAmount: minor.map { Double($0) / 100 },
                               platforms: platformLabel(mac: mac, windows: windows),
                               steamAppID: id, supportsMac: mac, supportsWindows: windows,
                               popularityRank: rank)
        }
        // The free search page marks real free titles explicitly; the compact
        // storesearch API often omits their price and cannot distinguish them
        // from unreleased games.
        let freeIDs = Set(freeGames.map(\.id))
        return Array(freeGames.prefix(trimmed.isEmpty ? 12 : 30)) +
            regularGames.filter { !freeIDs.contains($0.id) }
    }

    private static func gogGames(matching query: String) async throws -> [CatalogGame] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://catalog.gog.com/v1/catalog")!
        components.queryItems = trimmed.isEmpty
            ? [URLQueryItem(name: "limit", value: "24")]
            : [URLQueryItem(name: "query", value: trimmed), URLQueryItem(name: "limit", value: "24")]
        let root = try await object(at: components.url!)
        let products = root["products"] as? [[String: Any]] ?? []
        return products.prefix(24).enumerated().compactMap { rank, product in
            guard let id = product["id"] as? String,
                  let name = product["title"] as? String, !name.isEmpty,
                  let link = (product["storeLink"] as? String).flatMap(httpsURL),
                  link.host?.hasSuffix("gog.com") == true,
                  product["productType"] as? String != "dlc" else { return nil }
            let systems = product["operatingSystems"] as? [String] ?? []
            let price = (product["price"] as? [String: Any])?["final"] as? String
            let amount = ((product["price"] as? [String: Any])?["finalMoney"] as? [String: Any])?["amount"] as? String
            let image = (product["coverHorizontal"] as? String).flatMap(httpsURL)
            return CatalogGame(id: "gog-\(id)", name: name, store: .gog,
                               imageURL: image, productURL: link, price: price,
                               priceAmount: amount.flatMap(Double.init),
                               platforms: platformLabel(mac: systems.contains("osx"),
                                                        windows: systems.contains("windows")),
                               steamAppID: nil, supportsMac: systems.contains("osx"),
                               supportsWindows: systems.contains("windows"), popularityRank: rank)
        }
    }

    private static func steamFreeGames(matching query: String) async throws -> [CatalogGame] {
        var components = URLComponents(string: "https://store.steampowered.com/search/results/")!
        components.queryItems = [URLQueryItem(name: "query", value: ""),
                                 URLQueryItem(name: "start", value: "0"),
                                 URLQueryItem(name: "count", value: "30"),
                                 URLQueryItem(name: "maxprice", value: "free"),
                                 URLQueryItem(name: "infinite", value: "1")]
        if !query.isEmpty { components.queryItems?.append(URLQueryItem(name: "term", value: query)) }
        let root = try await object(at: components.url!)
        guard let html = root["results_html"] as? String else { return [] }
        return parseSteamFreeHTML(html)
    }

    static func parseSteamFreeHTML(_ html: String) -> [CatalogGame] {
        let rowPattern = #"<a href="https://store\.steampowered\.com/app/[^\"]+"[\s\S]*?</a>"#
        guard let rows = try? NSRegularExpression(pattern: rowPattern) else { return [] }
        let nsHTML = html as NSString
        let matches = rows.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        return matches.enumerated().compactMap { rank, match in
            let row = nsHTML.substring(with: match.range)
            guard row.contains("discount_final_price free"),
                  let idText = capture(#"data-ds-appid="([0-9]+)""#, in: row),
                  let id = Int(idText),
                  let rawTitle = capture(#"<span class="title">([\s\S]*?)</span>"#, in: row),
                  let productURL = URL(string: "https://store.steampowered.com/app/\(id)/") else { return nil }
            let title = rawTitle.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            let image = capture(#"<img src="([^"]+)""#, in: row).flatMap(httpsURL)
            let mac = row.contains("platform_img mac")
            let windows = row.contains("platform_img win")
            return CatalogGame(id: "steam-\(id)", name: title, store: .steam,
                               imageURL: image, productURL: productURL, price: "Free",
                               priceAmount: 0, platforms: platformLabel(mac: mac, windows: windows),
                               steamAppID: id, supportsMac: mac, supportsWindows: windows,
                               popularityRank: rank + 12)
        }
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func object(at url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 5_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return root
    }

    private static var regionCode: String {
        Locale.current.region?.identifier.lowercased() ?? "fi"
    }

    private static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }

    private static func platformLabel(mac: Bool, windows: Bool) -> String {
        if mac && windows { return String(localized: "Mac · Windows") }
        if mac { return String(localized: "Mac") }
        if windows { return String(localized: "Windows") }
        return String(localized: "Check store page")
    }
}
