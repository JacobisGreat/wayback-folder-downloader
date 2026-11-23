import Foundation

struct DownloadError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct GitHubRepo: Sendable {
    let owner: String
    let name: String

    var parts: [String] { [owner, name] }

    func owns(_ parts: [String]) -> Bool {
        parts.count >= 2
            && parts[0].caseInsensitiveCompare(owner) == .orderedSame
            && parts[1].caseInsensitiveCompare(name) == .orderedSame
    }

    func github(_ suffix: [String] = []) -> URL {
        webURL("github.com", parts + suffix)
    }
}

struct Capture: Sendable {
    let stamp: String
    let original: URL

    init?(url: URL) {
        guard url.host?.lowercased() == "web.archive.org",
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let range = url.absoluteString.range(of: "/web/"),
              let split = url.absoluteString[range.upperBound...].firstIndex(of: "/")
        else { return nil }

        let token = url.absoluteString[range.upperBound..<split]
        let date = token.prefix(while: { $0.isASCII && $0.isNumber })
        let modifier = token.dropFirst(date.count)
        guard [4, 6, 8, 10, 12, 14].contains(date.count),
              modifier.isEmpty || modifier.range(of: #"^[a-z]+_$"#, options: .regularExpression) != nil
        else { return nil }

        var address = String(url.absoluteString[url.absoluteString.index(after: split)...])
        if address.lowercased().hasPrefix("https%3a") || address.lowercased().hasPrefix("http%3a") {
            address = address.removingPercentEncoding ?? address
        }
        guard let original = URL(string: address), let scheme = original.scheme?.lowercased(),
              ["http", "https"].contains(scheme), original.host != nil,
              original.user == nil, original.password == nil, original.port == nil
        else { return nil }

        self.stamp = String(date)
        self.original = original
    }

    static func replay(_ original: URL, at stamp: String) -> URL {
        URL(string: "https://web.archive.org/web/\(stamp)id_/\(original.absoluteString)")!
    }
}

struct FolderLink: Sendable {
    let capture: Capture
    let repo: GitHubRepo
    let tail: [String]

    init(_ input: String) throws {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("web.archive.org/") {
            input = "https://" + input
        }
        guard let url = URL(string: input), let capture = Capture(url: url) else {
            throw DownloadError("Paste a dated Wayback Machine snapshot link. Open a capture on the Wayback calendar first.")
        }
        let parts = urlPath(capture.original)
        guard ["github.com", "www.github.com"].contains(capture.original.host?.lowercased() ?? ""),
              let parts, parts.count >= 2,
              parts.prefix(2).allSatisfy({ $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil })
        else {
            throw DownloadError("The snapshot needs to point to a GitHub repository or folder.")
        }
        guard parts.count == 2 || (parts.count >= 4 && parts[2] == "tree") else {
            throw DownloadError("Open the folder in the Wayback capture and copy its GitHub /tree/ link.")
        }
        self.capture = capture
        self.repo = GitHubRepo(owner: parts[0], name: parts[1])
        self.tail = Array(parts.dropFirst(3))
    }
}

func safePart(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
}

func repoPath(_ value: String) -> [String]? {
    if value == "/" || value.isEmpty { return [] }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    return parts.allSatisfy(safePart) ? parts : nil
}

func urlPath(_ url: URL) -> [String]? {
    guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
        return nil
    }
    let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.first == "" else { return nil }
    let trimmed = pieces.last == "" ? pieces.dropFirst().dropLast() : pieces.dropFirst()
    var parts = [String]()
    for piece in trimmed {
        guard let decoded = String(piece).removingPercentEncoding,
              let segments = repoPath(decoded), !segments.isEmpty
        else { return nil }
        parts.append(contentsOf: segments)
    }
    return parts
}

func webURL(_ host: String, _ pieces: [String], query: [URLQueryItem] = []) -> URL {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.percentEncodedPath = "/" + pieces.map {
        $0.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }.joined(separator: "/")
    if !query.isEmpty {
        components.queryItems = query
    }
    return components.url!
}

func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
    let leftHost = lhs.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    let rightHost = rhs.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    guard leftHost == rightHost, let left = urlPath(lhs), let right = urlPath(rhs) else { return false }
    let repoStart = leftHost == "raw.githubusercontent.com" || leftHost == "raw.github.com" || leftHost == "github.com"
    if repoStart, left.count >= 2, right.count >= 2 {
        return left[0].caseInsensitiveCompare(right[0]) == .orderedSame
            && left[1].caseInsensitiveCompare(right[1]) == .orderedSame
            && left.dropFirst(2).elementsEqual(right.dropFirst(2))
    }
    return left == right
}

func isCommit(_ value: String) -> Bool {
    value.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil
}
