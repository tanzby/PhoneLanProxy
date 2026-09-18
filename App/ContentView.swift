import Foundation
import SwiftUI
import PhoneLanProxyCore

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("代理状态") {
                    LabeledContent("状态") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 9, height: 9)
                            Text(model.statusText)
                        }
                    }
                    LabeledContent("局域网地址") {
                        Text(model.lanAddress ?? "未检测到 Wi-Fi")
                            .foregroundStyle(model.lanAddress == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("端口", value: String(model.port))
                    NavigationLink {
                        ConnectionMonitorView(model: model)
                    } label: {
                        LabeledContent("连接数", value: String(model.connectionCount))
                    }
                }

                Section {
                    Button(model.isActive ? "停止代理" : "启动代理") {
                        model.toggleProxy()
                    }
                    .frame(maxWidth: .infinity)
                }

                if let keepAliveWarning = model.keepAliveWarning {
                    Section("后台保活") {
                        Text(keepAliveWarning)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                if let errorDescription = model.errorDescription {
                    Section("错误") {
                        Text(errorDescription)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Text("在同一局域网的 Mac 上，将 SOCKS5、HTTP 或 HTTPS 代理设置为上面的地址和端口。代理启动后可以切换 App、刷视频听音乐或锁屏；来电、Siri、闹钟会暂时打断后台保活，结束后自动恢复。灵动岛的路由器图标为绿色表示代理已启动，橙色表示正在恢复；锁屏期间系统不允许更新灵动岛，连接数等信息会在回到 App 时刷新。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusColor: Color {
        if model.isHealthy { return .green }
        return model.isActive ? .orange : .secondary
    }
}

private enum ConnectionMonitorTab: String, CaseIterable, Identifiable {
    case active = "当前连接"
    case ended = "已结束"

    var id: String { rawValue }
}

private struct ConnectionMonitorView: View {
    let model: AppModel
    @State private var selectedTab: ConnectionMonitorTab = .active

    var body: some View {
        List {
            switch selectedTab {
            case .active:
                if !model.activeConnections.isEmpty {
                    Section("当前连接（\(model.activeConnections.count)）") {
                        ForEach(model.activeConnections) { connection in
                            NavigationLink {
                                ProxyConnectionDetailView(snapshot: connection)
                            } label: {
                                ActiveConnectionRow(snapshot: connection)
                            }
                        }
                    }
                }
            case .ended:
                if !model.endedConnections.isEmpty {
                    Section("已结束（\(model.endedConnections.count)）") {
                        ForEach(model.endedConnections) { connection in
                            NavigationLink {
                                ProxyConnectionDetailView(snapshot: connection)
                            } label: {
                                EndedConnectionRow(snapshot: connection)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            emptyState
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("连接状态", selection: $selectedTab) {
                    ForEach(ConnectionMonitorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 190)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch selectedTab {
        case .active where model.activeConnections.isEmpty:
            ConnectionMonitorEmptyState(
                title: "暂无当前连接",
                message: "新的 SOCKS5、HTTP 或 HTTPS 连接会显示在这里。",
                systemImage: "arrow.left.arrow.right"
            )
        case .ended where model.endedConnections.isEmpty:
            ConnectionMonitorEmptyState(
                title: "暂无历史连接",
                message: "本次代理运行期间结束的连接会保留在这里。",
                systemImage: "clock.arrow.circlepath"
            )
        default:
            EmptyView()
        }
    }
}

private struct ActiveConnectionRow: View {
    let snapshot: ProxyConnectionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(snapshot.endpoint ?? "正在识别目标")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(snapshot.protocolKind?.displayName ?? "识别中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(snapshot.phase.displayName)
                Spacer()
                Text("↑ \(ConnectionMonitorFormatting.rate(snapshot.uploadRate))")
                Text("↓ \(ConnectionMonitorFormatting.rate(snapshot.downloadRate))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct EndedConnectionRow: View {
    let snapshot: ProxyConnectionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: snapshot.endReason?.isFailure == true ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(snapshot.endReason?.isFailure == true ? .red : .secondary)
                Text(snapshot.endpoint ?? "未识别目标")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(snapshot.protocolKind?.displayName ?? "未识别")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(snapshot.endReason?.displayName ?? "已结束")
                Spacer()
                Text("↑ \(ConnectionMonitorFormatting.bytes(snapshot.uploadedBytes))")
                Text("↓ \(ConnectionMonitorFormatting.bytes(snapshot.downloadedBytes))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("平均")
                Spacer()
                Text("↑ \(ConnectionMonitorFormatting.rate(snapshot.averageUploadRate))")
                Text("↓ \(ConnectionMonitorFormatting.rate(snapshot.averageDownloadRate))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectionMonitorEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ProxyConnectionDetailView: View {
    let snapshot: ProxyConnectionSnapshot

    var body: some View {
        List {
            Section("连接信息") {
                LabeledContent("状态", value: snapshot.phase.displayName)
                LabeledContent("协议", value: snapshot.protocolKind?.displayName ?? "未识别")
                LabeledContent("目标", value: snapshot.endpoint ?? "正在识别目标")
                LabeledContent("客户端", value: snapshot.clientAddress ?? "未知")
            }

            Section("流量") {
                LabeledContent("上传", value: ConnectionMonitorFormatting.bytes(snapshot.uploadedBytes))
                LabeledContent("下载", value: ConnectionMonitorFormatting.bytes(snapshot.downloadedBytes))
                if snapshot.isEnded {
                    LabeledContent("平均上传", value: ConnectionMonitorFormatting.rate(snapshot.averageUploadRate))
                    LabeledContent("平均下载", value: ConnectionMonitorFormatting.rate(snapshot.averageDownloadRate))
                } else {
                    LabeledContent("当前上传", value: ConnectionMonitorFormatting.rate(snapshot.uploadRate))
                    LabeledContent("当前下载", value: ConnectionMonitorFormatting.rate(snapshot.downloadRate))
                }
            }

            Section("时间线") {
                LabeledContent("接入时间", value: snapshot.acceptedAt.formatted(date: .abbreviated, time: .standard))
                if let connectedAt = snapshot.connectedAt {
                    LabeledContent("连接目标", value: connectedAt.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("持续时间", value: ConnectionMonitorFormatting.duration(snapshot.duration))
                LabeledContent("最后活动", value: snapshot.lastActivityAt.formatted(date: .abbreviated, time: .standard))
            }

            if let endReason = snapshot.endReason {
                Section("结束结果") {
                    LabeledContent("结果", value: endReason.displayName)
                    if let failureDescription = snapshot.failureDescription {
                        Text(failureDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(snapshot.endpoint ?? "连接详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ConnectionMonitorFormatting {
    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var number = Double(value)
        var index = 0
        while number >= 1024, index < units.count - 1 {
            number /= 1024
            index += 1
        }
        if index == 0 {
            return "\(value) B"
        }
        return String(format: "%.1f %@", number, units[index])
    }

    static func rate(_ value: Double) -> String {
        guard value > 0 else { return "0 B/s" }
        return "\(bytes(UInt64(value.rounded()))) /s"
    }

    static func duration(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds) 秒"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(seconds) 秒"
        }
        let hours = minutes / 60
        return "\(hours) 小时 \(minutes % 60) 分"
    }
}
