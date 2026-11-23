import AppKit
import SwiftUI

@main
struct Launcher {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1, args[1] == "--recover" else {
            WaybackApp.main()
            return
        }
        guard args.count == 4 else {
            print("Usage: WaybackFolderDownloader --recover SNAPSHOT_URL DESTINATION")
            exit(2)
        }
        do {
            let link = try FolderLink(args[2])
            let destination = URL(fileURLWithPath: args[3], isDirectory: true)
            let result = try await Recovery().download(link, into: destination) { progress in
                print(progress.message)
            }
            print(result.folder.path)
            print(result.summary)
            for detail in result.details { print(detail) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

struct WaybackApp: App {
    var body: some Scene {
        WindowGroup("Wayback Folder Downloader") {
            DownloadView()
        }
        .defaultSize(width: 690, height: 440)
        .windowResizability(.contentSize)
    }
}

private struct DownloadView: View {
    @State private var input = ""
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @State private var task: Task<Void, Never>?
    @State private var progress: RecoveryProgress?
    @State private var result: RecoveryResult?
    @State private var status: String?
    @State private var failed = false
    @State private var showsDetails = false
    @FocusState private var linkFocused: Bool

    private let accent = Color(red: 0.20, green: 0.34, blue: 0.79)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Wayback snapshot link").fontWeight(.semibold)
                    HStack(spacing: 10) {
                        TextField("https://web.archive.org/web/…/https://github.com/…", text: $input)
                            .textFieldStyle(.roundedBorder)
                            .focused($linkFocused)
                            .onSubmit { start() }
                            .accessibilityLabel("Wayback snapshot link")
                        Button("Paste") {
                            if let clipboard = NSPasteboard.general.string(forType: .string) {
                                input = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                                linkFocused = true
                            }
                        }
                    }
                    Text("Copy the URL from a dated Wayback capture of a GitHub folder or repository.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.title3)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Save to").fontWeight(.semibold)
                        Text(destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~",
                                                                   options: .anchored))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destination.path)
                    }
                    Spacer(minLength: 4)
                    Button("Choose…", action: chooseDestination)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            }
            .disabled(task != nil)

            HStack(spacing: 12) {
                Button(action: start) {
                    Label("Download Folder", systemImage: "arrow.down.to.line")
                        .padding(.horizontal, 4)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
                .disabled(task != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let task {
                    Button("Cancel") { task.cancel() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                if let result {
                    Button("Details") { showsDetails = true }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.folder])
                    }
                }
            }
            statusView
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(minWidth: 620, idealWidth: 690, maxWidth: 900,
               minHeight: 420, idealHeight: 440, maxHeight: 620)
        .background {
            LinearGradient(colors: [accent.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showsDetails) { detailsView }
        .onAppear { linkFocused = true }
    }

    private var header: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(accent.gradient)
                    .frame(width: 52, height: 52)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Wayback Folder Downloader")
                    .font(.system(size: 25, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Recover GitHub folders from the Wayback Machine.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress {
                Text(progress.message).foregroundStyle(.secondary)
                if let fraction = progress.fraction { ProgressView(value: fraction).tint(accent) }
                else { ProgressView().progressViewStyle(.linear).tint(accent) }
            } else if let result {
                Label(result.summary, systemImage: result.partial ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(result.partial ? Color.orange : Color.primary)
                Text(result.folder.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let status {
                Label(status, systemImage: failed ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(minHeight: 38, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var detailsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recovery details").font(.title2.bold())
            ScrollView {
                Text(result?.details.joined(separator: "\n\n") ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { showsDetails = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 390)
    }

    private func chooseDestination() {
        let picker = NSOpenPanel()
        picker.title = "Choose where to save recovered folders"
        picker.prompt = "Choose"
        picker.directoryURL = destination
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let selected = picker.url {
            destination = selected
        }
    }

    private func start() {
        guard task == nil, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        status = nil
        result = nil
        failed = false
        let link: FolderLink
        do {
            link = try FolderLink(input)
        } catch {
            status = error.localizedDescription
            failed = true
            return
        }

        let output = destination
        linkFocused = false
        progress = RecoveryProgress(message: "Opening the Wayback snapshot…", fraction: nil)
        task = Task {
            defer {
                progress = nil
                task = nil
            }
            do {
                result = try await Recovery().download(link, into: output) { update in
                    await MainActor.run { progress = update }
                }
            } catch {
                if Task.isCancelled {
                    status = "Download cancelled."
                } else {
                    status = error.localizedDescription
                    failed = true
                }
            }
        }
    }
}
