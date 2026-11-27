import SwiftUI
import ZeltoCore

struct DownloadListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var unusedEnvironment: EmptyEnvironmentObject
    @State private var tasks: [DownloadTask] = []
    @State private var sourceURL = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    private var appDelegate: ZeltoAppDelegate? {
        UIApplication.shared.delegate as? ZeltoAppDelegate
    }

    var body: some View {
        NavigationStack {
            Group {
                if let startupError = appDelegate?.startupError {
                    ContentUnavailableView("Storage unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError))
                } else if tasks.isEmpty {
                    ContentUnavailableView("No downloads yet", systemImage: "arrow.down.circle", description: Text("Paste a direct file URL below to start your first download."))
                } else {
                    List(tasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(task.sourceURL.lastPathComponent.isEmpty ? task.sourceURL.host ?? "Download" : task.sourceURL.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                            ProgressView(value: task.progress)
                            HStack {
                                Text(task.status.rawValue.capitalized)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: task.bytesWritten, countStyle: .file))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Zelto")
            .safeAreaInset(edge: .bottom) {
                addDownloadPanel
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reloadTasks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh downloads")
                }
            }
            .task { await reloadTasks() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reloadTasks() } }
            }
            .alert("Download couldn't start", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var addDownloadPanel: some View {
        VStack(spacing: 10) {
            TextField("https://example.com/file.zip", text: $sourceURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await addDownload() }
            } label: {
                HStack {
                    if isAdding { ProgressView().tint(.white) }
                    Label("Add download", systemImage: "arrow.down.circle.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAdding || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }

    @MainActor
    private func reloadTasks() async {
        guard let store = appDelegate?.downloadStore else { return }
        tasks = await store.allTasks()
    }

    @MainActor
    private func addDownload() async {
        guard let store = appDelegate?.downloadStore,
              let manager = appDelegate?.backgroundDownloads else {
            errorMessage = appDelegate?.startupError ?? "Download services are not ready."
            return
        }

        isAdding = true
        defer { isAdding = false }

        do {
            guard let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DownloadTaskError.invalidSourceURL
            }
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let folder = support.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let suggestedName = url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent
            let safeName = suggestedName.replacingOccurrences(of: "/", with: "_")
            let destination = folder.appendingPathComponent(safeName)
            let task = try DownloadTask(sourceURL: url, destinationPath: destination.path)
            try await store.insert(task)
            _ = try await manager.enqueue(id: task.id)
            sourceURL = ""
            await reloadTasks()
        } catch {
            errorMessage = error.localizedDescription
            await reloadTasks()
        }
    }
}

private struct EmptyEnvironmentObject: ObservableObject {}
