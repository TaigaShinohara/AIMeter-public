import WidgetKit
import SwiftUI
import AIMeterCore

// MARK: - Timeline Entry
struct AIMeterWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AIMeterWidgetSnapshot
}

// MARK: - Timeline Provider
struct AIMeterTimelineProvider: TimelineProvider {
    typealias Entry = AIMeterWidgetEntry

    func placeholder(in context: Context) -> AIMeterWidgetEntry {
        AIMeterWidgetEntry(date: Date(), snapshot: .placeholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (AIMeterWidgetEntry) -> Void) {
        if context.isPreview {
            completion(AIMeterWidgetEntry(date: Date(), snapshot: .placeholder()))
        } else {
            let snap = SharedStore.loadWidgetSnapshot()
            completion(AIMeterWidgetEntry(date: Date(), snapshot: snap))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AIMeterWidgetEntry>) -> Void) {
        let currentDate = Date()
        let snap = SharedStore.loadWidgetSnapshot()
        let entry = AIMeterWidgetEntry(date: currentDate, snapshot: snap)

        // 15分後の再読込を要求。本体からもreloadを要求するが、反映時刻はOSが調整する。
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate) ?? currentDate.addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Liquid Glass Progress Bar (macOS Default Widget Harmony)
private struct WidgetLiquidProgressBar: View {
    let ratio: Double
    let color: Color
    var height: CGFloat = 5.5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let clamped = min(max(ratio, 0.0), 1.0)
        GeometryReader { geo in
            let w = max(height, geo.size.width * CGFloat(clamped))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.10))

                ZStack(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(color)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.25 : 0.35), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: height * 0.5)
                }
                .frame(width: min(geo.size.width, w), height: height)
            }
        }
        .frame(height: height)
    }
}

private func widgetStatusColor(for remainingPct: Int) -> Color {
    if remainingPct <= 15 {
        return .red
    } else if remainingPct <= 35 {
        return .orange
    } else {
        return Color.primary.opacity(0.72)
    }
}

private func widgetPercentColor(for remainingPct: Int) -> Color {
    if remainingPct <= 15 {
        return .red
    } else if remainingPct <= 35 {
        return .orange
    } else {
        return .primary
    }
}

private func widgetUsageText(for item: WidgetServiceItem) -> String {
    item.isRemainingAvailable
        ? "\(item.usedDisplay)/\(item.limitDisplay) \(item.unit)"
        : "推定使用量 \(item.usedDisplay) \(item.unit)"
}

private func widgetUsageAccessibility(for item: WidgetServiceItem) -> String {
    item.isRemainingAvailable
        ? "利用量 \(item.usedDisplay)、上限 \(item.limitDisplay) \(item.unit)"
        : "推定使用量 \(item.usedDisplay) \(item.unit)"
}

// MARK: - Small Widget View (最逼迫サービス)
struct SmallWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AIMeter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                WidgetUpdateStatus(snapshot: snapshot)
            }
            if let item = snapshot.mostCriticalService ?? snapshot.allServices.first {
                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    ServiceIcon(serviceID: item.id, fallbackSystemName: item.iconName)
                    Text(item.shortName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(item.bottleneckPeriod.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(item.isRemainingAvailable
                         ? item.remainingSource.percentText(item.remainingPercent) : "公式残量 未取得")
                        .font(.system(size: item.isRemainingAvailable ? 28 : 16,
                                      weight: .semibold).monospacedDigit())
                        .foregroundStyle(item.isRemainingAvailable
                                         ? widgetPercentColor(for: item.remainingPercent) : .secondary)
                    if item.isRemainingAvailable {
                        Text("残り")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if item.isRemainingAvailable {
                    WidgetLiquidProgressBar(
                        ratio: item.remainingRatio,
                        color: widgetStatusColor(for: item.remainingPercent),
                        height: 5.5
                    )
                } else {
                    Text("サービスの残り枠は取得できていません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if snapshot.showUsageAmounts {
                        Text(widgetUsageText(for: item))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(item.isRemainingAvailable ? 1 : 2)
                            .minimumScaleFactor(0.8)
                            .accessibilityLabel(widgetUsageAccessibility(for: item))
                    }
                    if item.isRemainingAvailable, let reset = item.remainingResetText() {
                        Text("リセット：\(reset)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            } else {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(snapshot.hasData ? "表示するサービスがありません" : "データ未取得")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(12)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }
}

// MARK: - Medium Widget View (主要3サービス一覧)
struct MediumWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Label("AIMeter · 残り枠", systemImage: "gauge.with.needle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                WidgetUpdateStatus(snapshot: snapshot)
            }

            Divider()
                .opacity(0.35)

            // Service Bars
            if snapshot.topServices.isEmpty {
                Spacer()
                Text("利用可能なデータがありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(spacing: 7) {
                    ForEach(snapshot.topServices) { item in
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                ServiceIcon(serviceID: item.id, fallbackSystemName: item.iconName)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.shortName).font(.caption.weight(.semibold))
                                    Text(item.bottleneckPeriod.label).font(.caption2).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                                .frame(width: 44, alignment: .leading)
                            }

                            if item.isRemainingAvailable {
                                WidgetLiquidProgressBar(
                                    ratio: item.remainingRatio,
                                    color: widgetStatusColor(for: item.remainingPercent),
                                    height: 5.5
                                )

                                Text(item.remainingSource.percentText(item.remainingPercent))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(widgetPercentColor(for: item.remainingPercent))
                                    .frame(width: 46, alignment: .trailing)
                            } else {
                                Text("公式残量 未取得")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .lineLimit(2)
                            }

                            if snapshot.showUsageAmounts {
                                Text(widgetUsageText(for: item))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(2)
                                    .frame(width: 88, alignment: .trailing)
                                    .accessibilityLabel(widgetUsageAccessibility(for: item))
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

}

// MARK: - Large Widget View (全サービス詳細)
struct LargeWidgetView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header
            HStack {
                Label("AIMeter · 残り枠", systemImage: "gauge.with.needle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                WidgetUpdateStatus(snapshot: snapshot)
            }

            Divider()
                .opacity(0.35)

            // Service Grid / Rows
            if snapshot.allServices.isEmpty {
                Spacer()
                Text("監視対象のサービスが設定されていません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.allServices.prefix(6)) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                HStack(spacing: 5) {
                                    ServiceIcon(serviceID: item.id, fallbackSystemName: item.iconName)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.caption.weight(.medium))
                                        Text(item.bottleneckPeriod.label).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                                }

                                if item.isRemainingAvailable {
                                    WidgetLiquidProgressBar(
                                        ratio: item.remainingRatio,
                                        color: widgetStatusColor(for: item.remainingPercent),
                                        height: 5.5
                                    )

                                    Text(item.remainingSource.percentText(item.remainingPercent))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(widgetPercentColor(for: item.remainingPercent))
                                        .frame(width: 48, alignment: .trailing)
                                } else {
                                    Text("公式残量 未取得")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }

                            HStack(alignment: .top, spacing: 8) {
                                if snapshot.showUsageAmounts {
                                    Text(item.isRemainingAvailable
                                         ? "利用量 \(widgetUsageText(for: item))" : widgetUsageText(for: item))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .accessibilityLabel(widgetUsageAccessibility(for: item))
                                }

                                if item.isRemainingAvailable, let reset = item.remainingResetText() {
                                    Spacer(minLength: 0)
                                    Text("リセット：\(reset)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(14)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }

}

private struct WidgetUpdateStatus: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        if snapshot.updateFailed {
            Label("更新失敗", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .accessibilityLabel("更新失敗。最後に取得した値を表示しています")
        } else if let date = snapshot.updatedAt {
            Text(date, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("最終取得 ") + Text(date, style: .date) + Text(date, style: .time))
        }
    }
}

private struct WidgetEmptyView: View {
    let snapshot: AIMeterWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AIMeter", systemImage: "gauge.with.needle")
                .font(.caption.weight(.semibold))
            Spacer()
            Label(snapshot.hasData ? "表示するサービスがありません" : "データ未取得",
                  systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.medium))
            Text(snapshot.hasData ? "AIMeterの設定でサービスを有効にしてください" : "AIMeterを開いて更新してください")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if snapshot.updateFailed {
                Label("更新に失敗しました", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .containerBackground(.ultraThinMaterial, for: .widget)
    }
}

// MARK: - Entry View Router
struct AIMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: AIMeterWidgetEntry

    var body: some View {
        Group {
            if !entry.snapshot.hasData || entry.snapshot.allServices.isEmpty {
                WidgetEmptyView(snapshot: entry.snapshot)
            } else {
                switch family {
                case .systemSmall:
                    SmallWidgetView(snapshot: entry.snapshot)
                case .systemMedium:
                    MediumWidgetView(snapshot: entry.snapshot)
                case .systemLarge, .systemExtraLarge:
                    LargeWidgetView(snapshot: entry.snapshot)
                default:
                    SmallWidgetView(snapshot: entry.snapshot)
                }
            }
        }
        .widgetURL(URL(string: "aimeter://"))
    }
}

// MARK: - Main Widget Definition
@main
struct AIMeterWidget: Widget {
    let kind: String = "com.local.AIMeter.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AIMeterTimelineProvider()) { entry in
            AIMeterWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Meter")
        .description("AIツールの残り枠・トークン使用量をデスクトップに表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
