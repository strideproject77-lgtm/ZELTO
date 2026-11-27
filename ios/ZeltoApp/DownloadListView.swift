import SwiftUI
import UIKit
import ZeltoCore

struct DownloadListView: View {
    @Environment(\.scenePhase) private var scenePhase
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
                    EmptyStateView(title: "Storage unavailable", systemImage: "externaldrive.badge.exclamationmark", message: startupError)
                } else if tasks.isEmpty {
                    EmptyStateView(title: "No downloads yet", systemImage: "arrow.down.circle", message: "Paste a direct file URL below to start your first download.")
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if task.status == .downloading {
                                Button {
                                    Task { await pauseDownload(task.id) }
                                } label: {
                                    Label("Pause", systemImage: "pause.fill")
                                }.tint(.orange)
                            } else if task.status == .paused || task.status == .queued {
                                Button {
                                    Task { await resumeDownload(task.id) }
                                } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }.tint(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Zelto")
            .safeAreaInset(edge: .bottom) {
                addDownloadPanel
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await reloadTasks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh downloads")
                }
            }
            .task { await reloadTasks() }
            .onChange(of: scenePhase) { phase in
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
    private func pauseDownload(_ id: UUID) async {
        do {
            try await appDelegate?.backgroundDownloads?.pause(id: id)
            await reloadTasks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func resumeDownload(_ id: UUID) async {
        do {
            _ = try await appDelegate?.backgroundDownloads?.enqueue(id: id)
            await reloadTasks()
        } catch {
            errorMessage = error.localizedDescription
        }
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

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
