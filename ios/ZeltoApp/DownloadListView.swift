import SwiftUI
import UserNotifications
import ZeltoCore

struct DownloadListView: View {
    let appDelegate: ZeltoAppDelegate

    @Environment(\.scenePhase) private var scenePhase
    @State private var tasks: [DownloadTask] = []
    @State private var sourceURL = ""
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteID: UUID?
    @State private var speedSamples: [UUID: [SpeedSample]] = [:]
    @State private var liveSpeeds: [UUID: Double] = [:]
    @State private var peakSpeeds: [UUID: Double] = [:]
    @State private var speedHistory: [UUID: [Double]] = [:]

    private struct SpeedSample {
        let bytes: Int64
        let date: Date
    }

    private var activeCount: Int { tasks.filter { $0.status == .downloading }.count }
    private var completedCount: Int { tasks.filter { $0.status == .completed }.count }
    private var totalBytes: Int64 { tasks.reduce(0) { $0 + $1.bytesWritten } }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.075, blue: 0.16),
                             Color(red: 0.055, green: 0.12, blue: 0.22),
                             Color(uiColor: .systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if let startupError = appDelegate.startupError {
                    EmptyStateView(title: "Storage unavailable",
                                   systemImage: "externaldrive.badge.exclamationmark",
                                   message: startupError)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            header
                            overview
                            if tasks.isEmpty {
                                EmptyStateView(title: "Ready when you are",
                                               systemImage: "arrow.down.to.line.circle",
                                               message: "Add a direct file link below. Zelto will manage the download and keep its progress saved.")
                                    .padding(.top, 24)
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Text("YOUR DOWNLOADS")
                                            .font(.caption.weight(.bold))
                                            .tracking(1.4)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(tasks.count) ITEMS")
                                            .font(.caption2.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(tasks) { task in
                                        DownloadCard(
                                            task: task,
                                            speed: liveSpeeds[task.id] ?? 0,
                                            peakSpeed: peakSpeeds[task.id] ?? 0,
                                            averageSpeed: averageSpeed(for: task.id),
                                            speedHistory: speedHistory[task.id] ?? [],
                                            onPause: { Task { await pauseDownload(task.id) } },
                                            onResume: { Task { await resumeDownload(task.id) } },
                                            onDelete: {
                                                pendingDeleteID = task.id
                                                showDeleteConfirmation = true
                                            }
                                        )
                                    }
                                }
                            }
                            addDownloadPanel
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await reloadTasks()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    await reloadTasks()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task { await reloadTasks() }
                }
            }
            .confirmationDialog("Delete this download?", isPresented: $showDeleteConfirmation,
                               titleVisibility: .visible) {
                Button("Delete file and record", role: .destructive) {
                    if let id = pendingDeleteID { Task { await deleteDownload(id) } }
                    pendingDeleteID = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteID = nil }
            } message: {
                Text("This removes the downloaded file and its saved download record.")
            }
            .alert("Zelto", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [.cyan, .blue, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("ZELTO")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .tracking(2.2)
                Text("DOWNLOAD MANAGER")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await reloadTasks() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .accessibilityLabel("Refresh downloads")
        }
    }

    private var overview: some View {
        HStack(spacing: 10) {
            OverviewTile(title: "ACTIVE", value: "\(activeCount)", symbol: "arrow.down.circle.fill", tint: .cyan)
            OverviewTile(title: "COMPLETED", value: "\(completedCount)", symbol: "checkmark.circle.fill", tint: .green)
            OverviewTile(title: "TRANSFERRED", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file),
                         symbol: "externaldrive.fill", tint: .purple)
        }
    }

    private var addDownloadPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(.cyan)
                Text("NEW DOWNLOAD")
                    .font(.caption.weight(.bold))
                    .tracking(1.3)
                Spacer()
                Text("HTTP / HTTPS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("Paste direct file URL", text: $sourceURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
            Button {
                Task { await addDownload() }
            } label: {
                HStack(spacing: 9) {
                    if isAdding {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(isAdding ? "ADDING DOWNLOAD…" : "START DOWNLOAD")
                        .font(.subheadline.weight(.bold))
                        .tracking(0.8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 51)
                .background(LinearGradient(colors: [.cyan, .blue],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .foregroundStyle(.white)
            }
            .disabled(isAdding || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(isAdding || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    @MainActor
    private func reloadTasks() async {
        let updated = await appDelegate.downloadStore?.allTasks() ?? []
        let now = Date()
        for task in updated where task.status == .downloading {
            var samples = speedSamples[task.id] ?? []
            samples.append(SpeedSample(bytes: task.bytesWritten, date: now))
            samples = samples.filter { now.timeIntervalSince($0.date) <= 2.0 }

            // Measure over a rolling window instead of a single 250 ms slice.
            // This prevents tiny callback bursts from making the speed jump wildly.
            if let baseline = samples.first(where: { now.timeIntervalSince($0.date) >= 0.9 }) {
                let elapsed = now.timeIntervalSince(baseline.date)
                if elapsed > 0 {
                    let delta = max(0, task.bytesWritten - baseline.bytes)
                    let measured = Double(delta) / elapsed
                    let previousSpeed = liveSpeeds[task.id] ?? measured
                    // Smooth the one-second rolling rate while still reacting quickly.
                    let stableSpeed = previousSpeed == 0
                        ? measured
                        : previousSpeed * 0.45 + measured * 0.55
                    liveSpeeds[task.id] = stableSpeed
                    if measured > 0 {
                        peakSpeeds[task.id] = max(peakSpeeds[task.id] ?? 0, measured)
                    }
                    var history = speedHistory[task.id] ?? []
                    history.append(measured)
                    speedHistory[task.id] = Array(history.suffix(24))
                    samples = samples.filter { $0.date > baseline.date }
                }
            }
            speedSamples[task.id] = samples
        }
        let activeIDs = Set(updated.filter { $0.status == .downloading }.map(\.id))
        liveSpeeds = liveSpeeds.filter { activeIDs.contains($0.key) }
        speedSamples = speedSamples.filter { activeIDs.contains($0.key) }
        peakSpeeds = peakSpeeds.filter { activeIDs.contains($0.key) }
        speedHistory = speedHistory.filter { activeIDs.contains($0.key) }
        tasks = updated
    }

    private func averageSpeed(for id: UUID) -> Double {
        let samples = speedHistory[id] ?? []
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    @MainActor
    private func pauseDownload(_ id: UUID) async {
        do {
            try await appDelegate.backgroundDownloads?.pause(id: id)
            await reloadTasks()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func deleteDownload(_ id: UUID) async {
        do {
            try await appDelegate.backgroundDownloads?.delete(id: id)
            liveSpeeds[id] = nil
            speedSamples[id] = nil
            peakSpeeds[id] = nil
            speedHistory[id] = nil
            await reloadTasks()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func resumeDownload(_ id: UUID) async {
        do {
            _ = try await appDelegate.backgroundDownloads?.enqueue(id: id)
            await reloadTasks()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func addDownload() async {
        guard let store = appDelegate.downloadStore,
              let manager = appDelegate.backgroundDownloads else {
            errorMessage = appDelegate.startupError ?? "Download services are not ready. Please restart Zelto and try again."
            return
        }
        isAdding = true
        defer { isAdding = false }
        let notificationCenter = UNUserNotificationCenter.current()
        let notificationSettings = await notificationCenter.notificationSettings()
        if notificationSettings.authorizationStatus == .notDetermined {
            _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        }
        do {
            let rawURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil else {
                throw DownloadTaskError.invalidSourceURL
            }
            // If a previous partial transfer expired, inspect the replacement
            // URL and reuse its saved bytes only when size plus a stable validator
            // prove that it is the same representation.
            let savedTasks = await store.allTasks()
            if let identity = try? await DownloadLinkInspector.inspect(url),
               let candidate = savedTasks.first(where: {
                   ($0.status == .paused || $0.status == .failed) &&
                   identity.safelyMatches($0)
               }) {
                _ = try await store.update(id: candidate.id) { value in
                    try value.replaceExpiredLink(with: url, identity: identity)
                }
                _ = try await manager.enqueue(id: candidate.id)
                sourceURL = ""
                await reloadTasks()
                return
            }

            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = support.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID()
            let name = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
            let destination = DownloadDestination.fileURL(in: folder, suggestedName: name, taskID: id)
            let task = try DownloadTask(id: id, sourceURL: url, destinationPath: destination.path)
            try await store.insert(task)
            _ = try await manager.enqueue(id: id)
            sourceURL = ""
            await reloadTasks()
        } catch {
            errorMessage = error.localizedDescription
            await reloadTasks()
        }
    }
}

private struct DownloadCard: View {
    let task: DownloadTask
    let speed: Double
    let peakSpeed: Double
    let averageSpeed: Double
    let speedHistory: [Double]
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    private var fileName: String {
        let name = task.sourceURL.lastPathComponent
        return name.isEmpty ? (task.sourceURL.host ?? "Download") : name
    }
    private var isActive: Bool { task.status == .downloading }
    private var remaining: String {
        guard let expected = task.expectedBytes, expected > task.bytesWritten, speed > 0 else {
            return "Calculating…"
        }
        return Self.duration(Int(ceil(Double(expected - task.bytesWritten) / speed)))
    }
    private var statusColor: Color {
        switch task.status {
        case .downloading: return .cyan
        case .completed: return .green
        case .paused: return .orange
        case .failed: return .red
        case .queued: return .secondary
        }
    }
    private var statusTitle: String {
        switch task.status {
        case .downloading: return "DOWNLOADING"
        case .completed: return "COMPLETED"
        case .paused: return "PAUSED"
        case .failed: return "FAILED"
        case .queued: return "QUEUED"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 45, height: 45)
                    Image(systemName: task.status == .completed ? "doc.zipper" :
                            (task.sourceURL.pathExtension.lowercased() == "zip" ? "archivebox.fill" : "doc.fill"))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(task.sourceURL.host ?? task.sourceURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(statusTitle)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.13), in: Capsule())
            }

            VStack(spacing: 7) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.09))
                        Capsule()
                            .fill(LinearGradient(colors: [statusColor, statusColor.opacity(0.55)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * CGFloat(task.progress ?? 0))
                    }
                }
                .frame(height: 7)
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: task.bytesWritten, countStyle: .file))")
                    Spacer()
                    Text(task.expectedBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unknown")
                    if let progress = task.progress {
                        Text("· \(Int(progress * 100))%")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if isActive {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("LIVE SPEED")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.1)
                                .foregroundStyle(.secondary)
                            Text(speed > 0 ? Self.speedString(speed) + "/s" : "Measuring…")
                                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.cyan)
                                .contentTransition(.numericText())
                        }
                        Spacer()
                        SpeedHistoryGraph(samples: speedHistory)
                            .frame(width: 92, height: 34)
                            .accessibilityLabel("Recent download speed graph")
                    }
                    HStack(spacing: 0) {
                        MetricValue(title: "AVERAGE", value: averageSpeed > 0 ? Self.speedString(averageSpeed) + "/s" : "—")
                        Spacer(minLength: 8)
                        MetricValue(title: "PEAK", value: peakSpeed > 0 ? Self.speedString(peakSpeed) + "/s" : "—")
                        Spacer(minLength: 8)
                        MetricValue(title: "TIME LEFT", value: remaining)
                    }
                }
                .padding(12)
                .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 12))
            }

            if let failure = task.failureMessage {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                if isActive {
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.orange)
                    .buttonStyle(.bordered)
                } else if task.status == .paused || task.status == .queued || task.status == .failed {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.cyan)
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("Saved on device", systemImage: "checkmark.icloud.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 42, height: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Delete download")
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private static func speedString(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let units = ["B", "KB", "MB", "GB"]
        var scaled = value
        var index = 0
        while scaled >= 1024 && index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        return String(format: scaled >= 100 ? "%.0f %@" : (scaled >= 10 ? "%.1f %@" : "%.2f %@"), scaled, units[index])
    }

    private static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let secs = value % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}

private struct SpeedHistoryGraph: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { proxy in
            let maximum = max(samples.max() ?? 1, 1)
            Path { path in
                guard samples.count > 1 else { return }
                for (index, sample) in samples.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(samples.count - 1)
                    let y = proxy.size.height - (proxy.size.height * CGFloat(sample / maximum))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct OverviewTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

private struct MetricValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.cyan)
            Text(title).font(.title3.weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
