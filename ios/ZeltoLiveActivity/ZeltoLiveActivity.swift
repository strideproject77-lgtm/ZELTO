import ActivityKit
import SwiftUI
import WidgetKit
import ZeltoCore

@main
struct ZeltoLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ZeltoDownloadLiveActivity()
    }
}

struct ZeltoDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ZELTO DOWNLOAD")
                            .font(.caption2.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        Text(context.attributes.fileName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(context.state.status.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(context.state.status == "Completed" ? .green : .cyan)
                }

                if let expected = context.state.expectedBytes, expected > 0 {
                    ProgressView(value: context.state.progress)
                        .tint(.cyan)
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: context.state.bytesWritten, countStyle: .file))
                        Spacer()
                        Text("\(Int(context.state.progress * 100))%")
                            .fontWeight(.bold)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .tint(.cyan)
                    Text(ByteCountFormatter.string(fromByteCount: context.state.bytesWritten, countStyle: .file) + " downloaded")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Label(Self.speedText(context.state.speedBytesPerSecond), systemImage: "speedometer")
                    if let eta = context.state.estimatedSecondsRemaining {
                        Label(Self.durationText(eta), systemImage: "clock")
                    }
                    Spacer(minLength: 0)
                    if let average = context.state.averageSpeedBytesPerSecond, average > 0 {
                        Text("AVG " + Self.speedText(average))
                    }
                }
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.035, green: 0.075, blue: 0.16))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.expectedBytes != nil {
                        Text("\(Int(context.state.progress * 100))%")
                            .font(.headline.monospacedDigit())
                    } else {
                        Text("↓")
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.fileName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: context.state.progress)
                            .tint(.cyan)
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: context.state.bytesWritten, countStyle: .file))
                            Spacer()
                            Text(Self.speedText(context.state.speedBytesPerSecond))
                            Spacer()
                            Text(context.state.status)
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(context.state.expectedBytes == nil ? "↓" : "\(Int(context.state.progress * 100))%")
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.cyan)
            }
        }
    }

    private static func speedText(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return "Waiting" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    private static func durationText(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value >= 3600 { return "\(value / 3600)h \((value % 3600) / 60)m" }
        if value >= 60 { return "\(value / 60)m \(value % 60)s" }
        return "\(value)s"
    }
}
