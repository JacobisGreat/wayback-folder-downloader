import Foundation

struct FolderItem: Sendable {
    let path: [String]
    let isDirectory: Bool
}

struct FolderPage: Sendable {
    let ref: [String]
    let path: [String]
    let commit: String?
    let items: [FolderItem]
    let hasListing: Bool
    let listingTruncated: Bool
}

struct BlobPage: Sendable {
    let lines: [String]?
    let rawLink: URL?
    let commit: String?
    let expectedSize: Int?
}

struct GitHubPage {
    let html: String
    let original: URL

    func folder(repo: GitHubRepo, tail: [String], knownRef: [String]? = nil) -> FolderPage? {
        let routes = payloads()
        let command = Self.matches(#"<input\b[^>]*\bid\s*=\s*["']js-command-bar-field["'][^>]*>"#, html).first?.first
        let attributes = command.map(Self.attributes) ?? [:]
        let legacyRef = attributes["data-repo"]?.caseInsensitiveCompare(repo.parts.joined(separator: "/")) == .orderedSame
            ? attributes["data-branch"].flatMap(repoPath) : nil
        let legacyCommit = legacyRef == nil ? nil : attributes["data-sha"].flatMap { isCommit($0) ? $0 : nil }
        let pin = permalink(repo: repo, type: "tree", tail: tail)
        let links = repoLinks(repo)

        for route in routes {
            guard let info = route["refInfo"] as? [String: Any],
                  let name = info["name"] as? String, let ref = repoPath(name), !ref.isEmpty,
                  let path = self.routePath(route),
                  (tail.isEmpty && path.isEmpty) || tail == ref + path
            else { continue }

            let tree = route["tree"] as? [String: Any]
            let listed = tree?["items"] as? [[String: Any]]
            let items = listed?.compactMap { item -> FolderItem? in
                guard let value = item["path"] as? String, let parts = repoPath(value),
                      parts.starts(with: path), parts.count > path.count
                else { return nil }
                let kind = item["contentType"] as? String
                return FolderItem(path: parts, isDirectory: kind == "directory" || kind == "tree")
            }
            let fallback = legacyItems(links, ref: ref, path: path)
            return FolderPage(
                ref: ref, path: path, commit: verifiedOID(info) ?? pin?.commit, items: items ?? fallback,
                hasListing: listed != nil || !fallback.isEmpty,
                listingTruncated: listed.map { listed in
                    (tree?["totalCount"] as? Int ?? 0) > listed.count || items?.count != listed.count
                } ?? false
            )
        }

        let pinnedRef = pin.map { Array(tail.dropLast($0.path.count)) }.flatMap { $0.isEmpty ? nil : $0 }
        let explicitRef = knownRef ?? pinnedRef ?? legacyRef
        let ref: [String]
        if let explicitRef, tail.isEmpty || tail.starts(with: explicitRef) {
            ref = explicitRef
        } else if let first = tail.first {
            ref = [first]
        } else {
            let counts = Dictionary(grouping: links.filter { $0.0 == "blob" && $0.1.count == 2 }, by: { $0.1[0] })
            let branch = counts.sorted {
                $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
            }.first?.key
            guard let inferred = branch ?? pin?.commit else { return nil }
            ref = [inferred]
        }
        let path = Array(tail.dropFirst(ref.count))
        let items = legacyItems(links, ref: ref, path: path)
        return FolderPage(ref: ref, path: path, commit: pin?.commit ?? (legacyRef == ref ? legacyCommit : nil),
                          items: items, hasListing: !items.isEmpty, listingTruncated: false)
    }

    func blob(repo: GitHubRepo, tail: [String]) -> BlobPage {
        let routes = payloads()
        var lines: [String]?
        var rawLink: URL?
        var commit = permalink(repo: repo, type: "blob", tail: tail)?.commit
        var expectedSize: Int?
        var expectedLines: Int?
        var truncated = false

        for route in routes {
            if let info = route["refInfo"] as? [String: Any], let name = info["name"] as? String,
               let ref = repoPath(name), let path = routePath(route), ref + path == tail {
                commit = commit ?? verifiedOID(info)
            }
            let blob = (route["blob"] as? [String: Any]) ?? route
            lines = lines ?? blob["rawLines"] as? [String]
            truncated = truncated || (blob["truncated"] as? Bool == true) || (blob["large"] as? Bool == true)
            if let value = blob["rawBlobUrl"] as? String {
                rawLink = rawLink ?? resolveLink(value)
            }
            if let info = blob["headerInfo"] as? [String: Any] {
                expectedLines = expectedLines ?? info["lineInfo"] as? Int
                expectedSize = expectedSize ?? info["byteSize"] as? Int
            }
        }

        for anchor in Self.matches(#"<a\b[^>]*\bhref\s*=\s*["'][^"']+["'][^>]*>"#, html) {
            guard let tag = anchor.first else { continue }
            let attributes = Self.attributes(tag)
            guard attributes["id"] == "raw-url" || attributes["data-testid"] == "raw-button",
                  let href = attributes["href"], let resolved = resolveLink(href)
            else { continue }
            rawLink = rawLink ?? resolved
        }

        if lines == nil {
            let cells = Self.matches(#"<td\b[^>]*\bid\s*=\s*["']LC([0-9]+)["'][^>]*>(.*?)</td\s*>"#, html)
            if !cells.isEmpty && cells.enumerated().allSatisfy({ Int($0.element[1]) == $0.offset + 1 }) {
                lines = cells.map {
                    Self.decodeEntities($0[2].replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression))
                }
            }
        }
        if truncated || (expectedLines.map { $0 > (lines?.count ?? 0) } ?? false) {
            lines = nil
        }
        if let url = rawLink, !rawLinkMatches(url, repo: repo, tail: tail, commit: commit) {
            rawLink = nil
        }
        return BlobPage(lines: lines, rawLink: rawLink, commit: commit, expectedSize: expectedSize)
    }

    private func routePath(_ route: [String: Any]) -> [String]? {
        (route["path"] as? String).flatMap(repoPath)
    }

    private func verifiedOID(_ info: [String: Any]) -> String? {
        (info["currentOid"] as? String).flatMap { isCommit($0) ? $0.lowercased() : nil }
    }

    private func permalink(repo: GitHubRepo, type: String, tail: [String]) -> (commit: String, path: [String])? {
        let anchors = Self.matches(#"<a\b[^>]*\b(?:js-permalink-shortcut|data-hotkey\s*=\s*["']y["'])[^>]*>"#, html)
        for anchor in anchors {
            guard let href = Self.attributes(anchor[0])["href"], let url = resolveLink(href),
                  ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""),
                  let parts = urlPath(url), repo.owns(parts), parts.count >= 4,
                  parts[2] == type, isCommit(parts[3])
            else { continue }
            let path = Array(parts.dropFirst(4))
            if tail.isEmpty ? path.isEmpty : tail.count > path.count && tail.suffix(path.count).elementsEqual(path) {
                return (parts[3].lowercased(), path)
            }
        }
        return nil
    }

    private func payloads() -> [[String: Any]] {
        let scripts = Self.matches(#"<script\b[^>]*\bdata-target\s*=\s*["']react-(?:app|partial)\.embeddedData["'][^>]*>(.*?)</script\s*>"#, html)
        return scripts.flatMap { match -> [[String: Any]] in
            guard let json = (try? JSONSerialization.jsonObject(with: Data(match[1].utf8))) as? [String: Any]
            else { return [] }
            let props = json["props"] as? [String: Any]
            guard let payload = (json["payload"] ?? props?["initialPayload"]) as? [String: Any] else {
                return []
            }
            let keys = ["codeViewRepoRoute", "codeViewTreeRoute", "codeViewBlobLayoutRoute", "codeViewBlobRoute",
                        "codeViewBlobLayoutRoute.StyledBlob", "codeViewLayoutRoute"]
            return [payload] + keys.compactMap { payload[$0] as? [String: Any] }
        }
    }

    private func repoLinks(_ repo: GitHubRepo) -> [(String, [String])] {
        let anchors = Self.matches(#"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>"#, html)
        return anchors.compactMap { anchor in
            guard anchor[1].contains("/tree/") || anchor[1].contains("/blob/"),
                  let url = resolveLink(Self.decodeEntities(anchor[1])),
                  ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? ""),
                  let parts = urlPath(url), repo.owns(parts), parts.count >= 4,
                  parts[2] == "tree" || parts[2] == "blob"
            else { return nil }
            return (parts[2], Array(parts.dropFirst(3)))
        }
    }

    private func resolveLink(_ link: String) -> URL? {
        if link.hasPrefix("/web/"), let replay = URL(string: "https://web.archive.org\(link)") {
            return Capture(url: replay)?.original
        }
        guard let url = URL(string: link, relativeTo: original)?.absoluteURL else { return nil }
        if url.host?.lowercased() == "web.archive.org" { return Capture(url: url)?.original }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }

    private func legacyItems(_ links: [(String, [String])], ref: [String], path: [String]) -> [FolderItem] {
        let prefix = ref + path
        var found = [String: FolderItem]()
        for (type, parts) in links where parts.starts(with: prefix) && parts.count == prefix.count + 1 {
            let item = FolderItem(path: path + [parts.last!], isDirectory: type == "tree")
            found[parts.last!] = item
        }
        return found.values.sorted { $0.path.last! < $1.path.last! }
    }

    static func attributes(_ tag: String) -> [String: String] {
        var result = [String: String]()
        for match in matches(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, tag) {
            result[match[1].lowercased()] = decodeEntities(match[2].isEmpty ? match[3] : match[2])
        }
        return result
    }

    static func matches(_ pattern: String, _ value: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { match in
            (0..<match.numberOfRanges).map {
                Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? ""
            }
        }
    }

    static func decodeEntities(_ value: String) -> String {
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}"]
        guard value.contains("&"), let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
        else { return value }
        var decoded = value as NSString
        for match in regex.matches(in: value, range: NSRange(location: 0, length: decoded.length)).reversed() {
            let token = decoded.substring(with: match.range(at: 1))
            var replacement = entities[token]
            if token.hasPrefix("#") {
                let hex = token.hasPrefix("#x")
                if let number = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(number) {
                    replacement = String(scalar)
                }
            }
            if let replacement {
                decoded = decoded.replacingCharacters(in: match.range, with: replacement) as NSString
            }
        }
        return decoded as String
    }
}

func rawLinks(repo: GitHubRepo, tail: [String]) -> [URL] {
    guard !tail.isEmpty else { return [] }
    return [
        webURL("raw.githubusercontent.com", repo.parts + tail),
        repo.github(["raw"] + tail),
        webURL("raw.github.com", repo.parts + tail)
    ]
}

func rawLinkMatches(_ url: URL, repo: GitHubRepo, tail: [String], commit: String?) -> Bool {
    guard let parts = urlPath(url), repo.owns(parts), let host = url.host?.lowercased() else { return false }
    var suffix = Array(parts.dropFirst(2))
    if host == "github.com" || host == "www.github.com" {
        guard suffix.first == "raw" else { return false }
        suffix.removeFirst()
    } else if host != "raw.githubusercontent.com" && host != "raw.github.com" {
        return false
    }
    if suffix.starts(with: ["refs", "heads"]) || suffix.starts(with: ["refs", "tags"]) {
        suffix.removeFirst(2)
    }
    if suffix == tail { return true }
    return commit != nil && suffix.first == commit && !suffix.dropFirst().isEmpty
        && tail.suffix(suffix.count - 1).elementsEqual(suffix.dropFirst())
}
