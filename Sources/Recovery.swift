import CryptoKit
import Foundation

struct RecoveryProgress: Sendable {
    let message: String
    let fraction: Double?
}

struct RecoveryResult: Sendable {
    let folder: URL
    let partial: Bool
    let summary: String
    let details: [String]
}

private struct GitTree: Decodable {
    let tree: [GitEntry]
    let truncated: Bool
}

private struct GitEntry: Decodable, Sendable {
    let path: String
    let mode: String
    let type: String
    let sha: String
    let size: Int?
}

private struct GitBlob: Decodable {
    let encoding: String
    let content: String
}

private struct PlannedFile: Sendable {
    let path: [String]
    let entry: GitEntry?
}

private struct RecoveredFile: Sendable {
    let bytes: Data
    let stamp: String?
    let rebuiltText: Bool
}

private struct Plan {
    var files = [PlannedFile]()
    var notes = [String]()
    var unknown = false
}

private struct ArchiveContext: Sendable {
    let repo: GitHubRepo
    let ref: [String]
    let stamp: String
    let commit: String?
}

struct Recovery: Sendable {
    private let network = Network()

    func download(_ link: FolderLink, into destination: URL,
                  progress: @escaping @Sendable (RecoveryProgress) async -> Void) async throws -> RecoveryResult {
        await progress(RecoveryProgress(message: "Opening the Wayback snapshot…", fraction: nil))
        let root = link.capture.original
        let replay = try? await network.get(Capture.replay(root, at: link.capture.stamp))
        try Task.checkCancellation()
        let playback = replay?.capture.flatMap { samePage($0.original, root) ? $0 : nil }
        let stamp = playback?.stamp ?? link.capture.stamp
        let page = playback.flatMap { archive in
            replay.map { GitHubPage(html: String(decoding: $0.data, as: UTF8.self), original: archive.original) }
        }
        let listing = page?.folder(repo: link.repo, tail: link.tail)
        let explicitCommit = link.tail.first.flatMap { isCommit($0) ? $0.lowercased() : nil }
        let commit = listing?.commit ?? explicitCommit
        let ref = listing?.ref ?? Array(link.tail.prefix(1))
        let path = listing?.path ?? Array(link.tail.dropFirst(ref.count))
        let context = ArchiveContext(repo: link.repo, ref: ref, stamp: stamp, commit: commit)
        var notes = ["Requested Wayback date: \(link.capture.stamp) UTC"]
        if let playback, playback.stamp != link.capture.stamp {
            notes.append("Wayback opened the folder capture from \(playback.stamp) UTC.")
        }
        if playback == nil {
            notes.append("Wayback did not return the requested folder page.")
        }

        var plan: Plan
        var exact = false
        if let commit {
            await progress(RecoveryProgress(message: "Checking GitHub for the captured commit…", fraction: nil))
            if let verified = try? await exactPlan(repo: link.repo, commit: commit, path: path) {
                exact = true
                plan = verified
                notes.append("Git commit: \(commit)")
            } else {
                notes.append("GitHub could not serve the full tree for captured commit \(commit).")
                plan = try await archivedPlan(context, initial: listing, root: path, progress: progress)
            }
        } else {
            plan = try await archivedPlan(context, initial: listing, root: path, progress: progress)
        }
        try Task.checkCancellation()
        guard !plan.files.isEmpty || (exact && !plan.unknown) else {
            let message = playback == nil
                ? "Wayback did not return the folder page or a usable file index. Check the link or try another capture date."
                : "This capture did not yield a downloadable file list. Try another capture date for this folder."
            throw DownloadError(message)
        }
        notes.append(contentsOf: plan.notes)
        if !exact { notes.append("Archived copies may come from different captures. Git file hashes were unavailable.") }

        let fs = FileManager.default
        let stage = destination.appendingPathComponent(".wayback-download-\(UUID().uuidString)", isDirectory: true)
        // Publish the folder only after all download and cancellation checks finish.
        try fs.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fs.removeItem(at: stage) }

        let files = plan.files.sorted { $0.path.joined(separator: "/") < $1.path.joined(separator: "/") }
        var saved = 0
        var missing = 0
        var reconstructed = 0
        var otherDates = [String: Int]()
        var failures = [String]()
        var createdDirectories = Set<[Data]>()

        try await withThrowingTaskGroup(of: (PlannedFile, RecoveredFile?).self) { workers in
            var remaining = files.makeIterator()
            for _ in 0..<min(5, files.count) {
                if let file = remaining.next() {
                    workers.addTask { (file, try await recover(file, context: context)) }
                }
            }
            await progress(RecoveryProgress(message: "Downloading \(files.count) files…", fraction: 0))

            while let (file, recovered) = try await workers.next() {
                try Task.checkCancellation()
                var problem: String?
                let displayPath = file.path.joined(separator: "/")
                if file.entry?.type == "commit" {
                    problem = "Git submodule"
                } else if let recovered {
                    do {
                        try save(recovered.bytes, file: file, root: path, into: stage,
                                 createdDirectories: &createdDirectories)
                        saved += 1
                        if recovered.rebuiltText { reconstructed += 1 }
                        if let date = recovered.stamp, date.prefix(8) != stamp.prefix(8) {
                            otherDates[String(date.prefix(8)), default: 0] += 1
                        }
                    } catch {
                        problem = error.localizedDescription
                    }
                } else {
                    problem = "A usable copy of this file was unavailable"
                }
                if let problem {
                    missing += 1
                    failures.append("\(displayPath) — \(problem)")
                }
                if let next = remaining.next() {
                    workers.addTask { (next, try await recover(next, context: context)) }
                }
                let processed = saved + missing
                if processed == files.count || processed < 20 || processed.isMultiple(of: 10) {
                    await progress(RecoveryProgress(message: "Checked \(processed) of \(files.count) files",
                                                    fraction: Double(processed) / Double(files.count)))
                }
            }
        }
        try Task.checkCancellation()

        guard saved > 0 || (exact && files.isEmpty) else {
            if failures.allSatisfy({ !$0.contains("usable copy") }), let first = failures.first {
                throw DownloadError("No files were saved. \(first)")
            }
            throw DownloadError("The folder listed \(files.count) files, but usable copies could not be downloaded. Try another capture date.")
        }
        let folder = try publish(stage, into: destination, name: path.last ?? link.repo.name)
        if files.contains(where: { $0.entry?.mode == "120000" }) {
            notes.append("Git symbolic links were saved as text files containing their link targets.")
        }
        if reconstructed > 0 {
            notes.append("Reconstructed text from \(reconstructed) GitHub file pages. Original line endings and final newlines may differ.")
        }
        for (date, count) in otherDates.sorted(by: { $0.key < $1.key }) {
            notes.append("\(count) archived files captured on \(date) UTC.")
        }
        let partial = missing > 0 || plan.unknown
        let summary: String
        if partial {
            summary = missing > 0
                ? "Saved \(saved) of \(files.count) identified files. See details for gaps."
                : "Saved \(saved) files. The archive may have gaps."
        } else if exact {
            summary = "Saved \(saved) files from the captured Git commit."
        } else if !otherDates.isEmpty {
            summary = "Saved \(saved) files using captures from other dates."
        } else {
            summary = "Saved \(saved) files from Wayback captures."
        }
        return RecoveryResult(folder: folder, partial: partial, summary: summary,
                              details: notes + failures.sorted())
    }

    private func exactPlan(repo: GitHubRepo, commit: String, path: [String]) async throws -> Plan {
        var treeID = commit
        for segment in path {
            let reply = try await tree(repo: repo, id: treeID, recursive: false)
            guard let child = reply.tree.first(where: { $0.type == "tree" && $0.path == segment }) else {
                throw DownloadError("The folder was absent from the captured Git commit.")
            }
            treeID = child.sha
        }
        let root = try await tree(repo: repo, id: treeID, recursive: true)
        var plan = Plan()
        if root.truncated {
            var pending = [(path, treeID)]
            while let (prefix, id) = pending.popLast() {
                let children = try await tree(repo: repo, id: id, recursive: false)
                guard !children.truncated else { throw DownloadError("GitHub truncated a directory listing.") }
                for entry in children.tree {
                    guard safePart(entry.path) else { throw DownloadError("GitHub returned an invalid path.") }
                    let target = prefix + [entry.path]
                    if entry.type == "tree" { pending.append((target, entry.sha)) }
                    else { plan.files.append(PlannedFile(path: target, entry: entry)) }
                }
            }
        } else {
            for entry in root.tree where entry.type != "tree" {
                guard let target = repoPath(entry.path), !target.isEmpty else {
                    throw DownloadError("GitHub returned an invalid path.")
                }
                plan.files.append(PlannedFile(path: path + target, entry: entry))
            }
        }
        return plan
    }

    private func tree(repo: GitHubRepo, id: String, recursive: Bool) async throws -> GitTree {
        guard isCommit(id) else { throw DownloadError("GitHub returned an invalid tree identifier.") }
        let query = recursive ? [URLQueryItem(name: "recursive", value: "1")] : []
        let url = webURL("api.github.com", ["repos"] + repo.parts + ["git", "trees", id], query: query)
        let reply = try await network.get(url, accept: "application/vnd.github+json")
        return try JSONDecoder().decode(GitTree.self, from: reply.data)
    }

    private func recover(_ file: PlannedFile, context: ArchiveContext) async throws -> RecoveredFile? {
        try Task.checkCancellation()
        if let entry = file.entry {
            guard entry.type == "blob", let commit = context.commit else { return nil }
            let raw = webURL("raw.githubusercontent.com", context.repo.parts + [commit] + file.path)
            if let reply = try? await network.get(raw), matches(reply.data, entry: entry) {
                return RecoveredFile(bytes: reply.data, stamp: nil, rebuiltText: false)
            }
            try Task.checkCancellation()
            let api = webURL("api.github.com", ["repos"] + context.repo.parts + ["git", "blobs", entry.sha])
            if isCommit(entry.sha),
               let reply = try? await network.get(api, accept: "application/vnd.github+json"),
               let blob = try? JSONDecoder().decode(GitBlob.self, from: reply.data), blob.encoding == "base64",
               let bytes = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters),
               matches(bytes, entry: entry) {
                return RecoveredFile(bytes: bytes, stamp: nil, rebuiltText: false)
            }
        }
        return try await archivedFile(file, context: context)
    }

    private func matches(_ data: Data, entry: GitEntry) -> Bool {
        guard entry.size == nil || entry.size == data.count else { return false }
        var digest = Insecure.SHA1()
        digest.update(data: Data("blob \(data.count)\0".utf8))
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == entry.sha.lowercased()
    }

    private func save(_ data: Data, file: PlannedFile, root: [String], into stage: URL,
                      createdDirectories: inout Set<[Data]>) throws {
        let relative = file.path.dropFirst(root.count)
        guard file.path.starts(with: root), relative.allSatisfy(safePart), let leaf = relative.last else {
            throw DownloadError("Invalid relative file path")
        }
        let fs = FileManager.default
        var dir = stage
        var directoryKey = [Data]()
        for part in relative.dropLast() {
            dir = dir.appendingPathComponent(part, isDirectory: true)
            directoryKey.append(Data(part.utf8))
            if !createdDirectories.contains(directoryKey) {
                guard !fs.fileExists(atPath: dir.path) else {
                    throw DownloadError("Folder name collides with another item on this disk")
                }
                try fs.createDirectory(at: dir, withIntermediateDirectories: false)
                createdDirectories.insert(directoryKey)
            }
        }
        let output = dir.appendingPathComponent(leaf, isDirectory: false)
        guard !fs.fileExists(atPath: output.path) else {
            throw DownloadError("Filename collides with another file on this disk")
        }
        try data.write(to: output, options: .atomic)
        if file.entry?.mode == "100755" {
            try? fs.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
        }
    }

    private func publish(_ stage: URL, into destination: URL, name: String) throws -> URL {
        let fs = FileManager.default
        for attempt in 1...10_000 {
            let name = attempt == 1 ? name : "\(name) (\(attempt))"
            let result = destination.appendingPathComponent(name, isDirectory: true)
            do {
                try fs.moveItem(at: stage, to: result)
                return result
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw DownloadError("The destination has too many folders with this name.")
    }
}

extension Recovery {
    private func archivedPlan(_ context: ArchiveContext, initial: FolderPage?, root: [String],
                              progress: @escaping @Sendable (RecoveryProgress) async -> Void) async throws -> Plan {
        guard !context.ref.isEmpty else {
            return Plan(notes: ["The repository's archived default branch could not be identified."], unknown: true)
        }
        await progress(RecoveryProgress(message: "Finding files in the archived folder…", fraction: nil))
        var plan = Plan()
        var pending = [root]
        var directories = Set<[String]>()
        var files = Set<[String]>()

        while let path = pending.popLast() {
            try Task.checkCancellation()
            guard directories.insert(path).inserted else { continue }
            if directories.count.isMultiple(of: 10) {
                await progress(RecoveryProgress(message: "Checked \(directories.count) archived folders…", fraction: nil))
            }
            let folder: FolderPage?
            if path == root {
                folder = initial
            } else {
                let tail = context.ref + path
                let url = context.repo.github(["tree"] + tail)
                if let reply = try? await archivedPage(url, at: context.stamp), let capture = reply.capture {
                    folder = GitHubPage(html: String(decoding: reply.data, as: UTF8.self), original: capture.original)
                        .folder(repo: context.repo, tail: tail, knownRef: context.ref)
                    if folder?.hasListing == true && capture.stamp.prefix(8) != context.stamp.prefix(8) {
                        plan.notes.append("Directory listing for \(path.joined(separator: "/")) came from \(capture.stamp) UTC.")
                    }
                } else {
                    folder = nil
                }
            }

            for item in folder?.items ?? [] where item.path.starts(with: path) && item.path.count > path.count {
                if item.isDirectory { pending.append(item.path) }
                else { files.insert(item.path) }
            }
            if folder?.hasListing == true, folder?.listingTruncated == false { continue }

            let indexed = try await indexedFiles(context, under: path)
            plan.unknown = true
            let label = path.isEmpty ? "the repository root" : path.joined(separator: "/")
            if indexed.isEmpty {
                plan.notes.append("No complete archived listing was found for \(label).")
            } else {
                files.formUnion(indexed)
                plan.notes.append("Used Wayback's file index for \(label). The listing may be incomplete.")
            }
        }

        plan.files = files.map { PlannedFile(path: $0, entry: nil) }
        return plan
    }

    private func archivedPage(_ url: URL, at stamp: String) async throws -> HTTPReply {
        let reply = try await network.get(Capture.replay(url, at: stamp))
        guard let capture = reply.capture, samePage(capture.original, url) else {
            throw DownloadError("Wayback redirected to a different GitHub page.")
        }
        return reply
    }

    private func indexedFiles(_ context: ArchiveContext, under path: [String]) async throws -> Set<[String]> {
        let tail = context.ref + path
        let archivedBlob = context.repo.github(["blob"] + tail)
        let archivedRaw = webURL("raw.githubusercontent.com", context.repo.parts + tail)
        async let blob = index(archivedBlob, to: context.stamp)
        async let raw = index(archivedRaw, to: context.stamp)
        let (blobURLs, rawURLs) = await (blob, raw)
        try Task.checkCancellation()

        var files = Set<[String]>()
        for url in blobURLs + rawURLs {
            guard let parts = urlPath(url), context.repo.owns(parts) else { continue }
            let github = ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "")
            guard (github && parts.dropFirst(2).first == "blob") || url.host?.lowercased() == "raw.githubusercontent.com"
            else { continue }
            let suffix = parts.dropFirst(github ? 3 : 2)
            guard suffix.starts(with: tail), suffix.count > tail.count else { continue }
            files.insert(Array(suffix.dropFirst(context.ref.count)))
        }
        return files
    }

    private func index(_ prefix: URL, to stamp: String) async -> [URL] {
        let query = [
            URLQueryItem(name: "url", value: prefix.absoluteString + "/"),
            URLQueryItem(name: "matchType", value: "prefix"),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "fl", value: "timestamp,original"),
            URLQueryItem(name: "filter", value: "statuscode:200"),
            URLQueryItem(name: "collapse", value: "urlkey"),
            URLQueryItem(name: "to", value: stamp),
            URLQueryItem(name: "limit", value: "10000")
        ]
        let url = webURL("web.archive.org", ["cdx", "search", "cdx"], query: query)
        guard let reply = try? await network.get(url),
              let rows = try? JSONDecoder().decode([[String]].self, from: reply.data)
        else { return [] }
        return rows.dropFirst().compactMap { $0.count == 2 ? URL(string: $0[1]) : nil }
    }

    private func archivedFile(_ file: PlannedFile, context: ArchiveContext) async throws -> RecoveredFile? {
        let tail = context.ref + file.path
        let pinned = context.commit.map { [$0] + file.path }
        let base = rawLinks(repo: context.repo, tail: tail)
        let immutable = pinned.map { rawLinks(repo: context.repo, tail: $0) } ?? []
        let raw = immutable + base
        var tried = Set<URL>()
        for url in raw.prefix(immutable.isEmpty ? 1 : 2) {
            try Task.checkCancellation()
            guard tried.insert(url).inserted else { continue }
            if let found = await archivedRaw(url, file: file, context: context, tail: tail) { return found }
        }

        var text: (BlobPage, String)?
        var blobTails = [tail]
        if let pinned, pinned != tail { blobTails.insert(pinned, at: 0) }
        for candidate in blobTails {
            try Task.checkCancellation()
            let url = context.repo.github(["blob"] + candidate)
            guard let reply = try? await archivedPage(url, at: context.stamp), let capture = reply.capture else { continue }
            let blob = GitHubPage(html: String(decoding: reply.data, as: UTF8.self), original: capture.original)
                .blob(repo: context.repo, tail: candidate)
            if file.entry == nil, let expected = context.commit, let found = blob.commit, expected != found {
                continue
            }
            if let link = blob.rawLink, tried.insert(link).inserted,
               let found = await archivedRaw(link, file: file, context: context, tail: tail) {
                return found
            }
            if blob.lines != nil { text = text ?? (blob, capture.stamp) }
        }

        for url in raw {
            try Task.checkCancellation()
            guard tried.insert(url).inserted else { continue }
            if let found = await archivedRaw(url, file: file, context: context, tail: tail) { return found }
        }
        guard let (blob, stamp) = text, let lines = blob.lines else { return nil }
        let variants = ["\n", "\r\n"].flatMap { eol -> [Data] in
            let text = lines.joined(separator: eol)
            return [Data((text + eol).utf8), Data(text.utf8)]
        }
        if let entry = file.entry {
            guard let bytes = variants.first(where: { matches($0, entry: entry) }) else { return nil }
            return RecoveredFile(bytes: bytes, stamp: stamp, rebuiltText: false)
        }
        let bytes: Data
        if lines.isEmpty {
            bytes = Data()
        } else if let expected = blob.expectedSize {
            guard let candidate = variants.first(where: { $0.count == expected }) else { return nil }
            bytes = candidate
        } else {
            bytes = lines.last == "" ? variants[1] : variants[0]
        }
        return RecoveredFile(bytes: bytes, stamp: stamp, rebuiltText: true)
    }

    private func archivedRaw(_ url: URL, file: PlannedFile, context: ArchiveContext, tail: [String]) async -> RecoveredFile? {
        guard let reply = try? await network.get(Capture.replay(url, at: context.stamp)),
              let capture = reply.capture,
              samePage(capture.original, url) || rawLinkMatches(capture.original, repo: context.repo, tail: tail, commit: context.commit)
        else { return nil }
        let prefix = String(decoding: reply.data.prefix(4096), as: UTF8.self)
        let archiveError = prefix.contains("<title>Wayback Machine</title>")
            && (prefix.contains("web-static.archive.org") || prefix.contains("Wayback Machine doesn't have"))
        guard !archiveError, file.entry.map({ matches(reply.data, entry: $0) }) ?? true else { return nil }
        return RecoveredFile(bytes: reply.data, stamp: capture.stamp, rebuiltText: false)
    }
}
