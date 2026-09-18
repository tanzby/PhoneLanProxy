import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island and Lock Screen presentation of a running proxy.
///
/// Every presentation deliberately omits connection details. The router glyph
/// is green while the proxy is running and gray while it is recovering.
struct ProxyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProxyActivityAttributes.self) { context in
            let appearance = ProxyActivityAppearance(health: context.state.health)
            HStack(spacing: 12) {
                RouterGlyph(tint: appearance.tint)
                    .font(.system(size: 24, weight: .semibold))
                Text(appearance.title)
                    .font(.headline)
            }
            .padding(16)
            .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let appearance = ProxyActivityAppearance(health: context.state.health)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RouterGlyph(tint: appearance.tint)
                        .font(.system(size: 30, weight: .semibold))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(appearance.title)
                        .font(.headline)
                }
            } compactLeading: {
                RouterGlyph(tint: appearance.tint)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                RouterGlyph(tint: appearance.tint)
            }
            .keylineTint(appearance.tint)
        }
    }
}

private struct ProxyActivityAppearance {
    let tint: Color
    let title: String

    init(health: ProxyActivityAttributes.ContentState.Health) {
        switch health {
        case .running:
            tint = .green
            title = "代理运行中"
        case .recovering:
            tint = .gray
            title = "代理正在恢复"
        }
    }
}

private struct RouterGlyph: View {
    let tint: Color

    var body: some View {
        Image(systemName: "wifi.router.fill")
            .foregroundStyle(tint)
            .accessibilityLabel("PhoneLanProxy")
    }
}
