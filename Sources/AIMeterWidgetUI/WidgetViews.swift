import SwiftUI
import WidgetKit
import AIMeterCore

/// The production content is also rendered by the layout tests. WidgetKit owns
/// the outer margins; this view adds only spacing between related information.
public struct AIMeterWidgetContent: View {
    public let snapshot: AIMeterWidgetSnapshot
    public let family: WidgetFamily

    public init(snapshot: AIMeterWidgetSnapshot, family: WidgetFamily) {
        self.snapshot = snapshot
        self.family = family
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 4) {
                WidgetHeader(snapshot: snapshot, small: family == .systemSmall)
                if !snapshot.hasData || snapshot.allServices.isEmpty {
                    WidgetEmptyContent(hasData: snapshot.hasData)
                } else if family == .systemSmall {
                    if let item = snapshot.mostCriticalService ?? snapshot.allServices.first {
                        SmallServiceContent(item: item, showAmounts: snapshot.showUsageAmounts)
                    }
                } else {
                    let large = family != .systemMedium
                    let items = large ? Array(snapshot.allServices.prefix(6)) : snapshot.topServices
                    let nameWidth = min(large ? 118 : 106, geometry.size.width * 0.36)
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            ServiceRow(item: item, showAmounts: snapshot.showUsageAmounts,
                                       large: large, nameWidth: nameWidth)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .widgetLayoutFrame("content")
        }
        .coordinateSpace(name: "AIMeterWidgetContent")
    }
}

/// Shared by the production and QA extensions, including the native background.
/// Deep links belong to each extension's wrapper, outside this shared surface.
public struct AIMeterWidgetSurface: View {
    public let snapshot: AIMeterWidgetSnapshot
    public let family: WidgetFamily

    public init(snapshot: AIMeterWidgetSnapshot, family: WidgetFamily) {
        self.snapshot = snapshot
        self.family = family
    }

    public var body: some View {
        AIMeterWidgetContent(snapshot: snapshot, family: family)
            .containerBackground(.ultraThinMaterial, for: .widget)
    }
}

private struct WidgetHeader: View {
    let snapshot: AIMeterWidgetSnapshot
    let small: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(small ? "AIMeter" : "AIMeter · 残り枠")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if snapshot.updateFailed {
                Label("更新失敗", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("更新失敗。最後に取得した値を表示しています")
                    .fixedSize()
            } else if let date = snapshot.updatedAt {
                Text(date, style: .relative)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text("最終取得 ") + Text(date, style: .date) + Text(date, style: .time))
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .widgetLayoutFrame("header")
    }
}

private struct SmallServiceContent: View {
    let item: WidgetServiceItem
    let showAmounts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                ServiceIcon(serviceID: item.id, fallbackSystemName: item.iconName, size: 16)
                    .fixedSize()
                Text(item.shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .widgetLayoutFrame("name:\(item.id)")
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            Text(item.periodLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .widgetLayoutFrame("period:\(item.id)")
            if item.isRemainingAvailable {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(item.remainingSource.percentText(item.remainingPercent))
                        // The widest value, 約100%, must leave room for 残り
                        // within the small widget's 128 pt content width.
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .foregroundStyle(percentColor(item.remainingPercent))
                        .fixedSize()
                        .widgetLayoutFrame("primary.percent:\(item.id)")
                    Text("残り")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .widgetLayoutFrame("primary.label:\(item.id)")
                }
                .widgetLayoutFrame("primary:\(item.id)")
                WidgetRemainingBar(item: item)
            } else {
                Text("公式残量 未取得")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .widgetLayoutFrame("primary:\(item.id)")
            }
            if let usage = WidgetRowText(item: item, showAmounts: showAmounts).usage {
                Text(usage)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .widgetLayoutFrame("usage:\(item.id)")
            }
            if item.isRemainingAvailable, let reset = item.remainingResetText() {
                Text("リセット：\(reset)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .widgetLayoutFrame("reset:\(item.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetLayoutFrame("row:\(item.id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetRowText(item: item, showAmounts: showAmounts).accessibilityLabel)
    }
}

/// Two aligned lines keep all three medium rows readable with amounts enabled.
/// Large rows put the reset under the period in the name column so all six
/// services fit within WidgetKit's native content area.
private struct ServiceRow: View {
    let item: WidgetServiceItem
    let showAmounts: Bool
    let large: Bool
    let nameWidth: CGFloat

    var body: some View {
        let text = WidgetRowText(item: item, showAmounts: showAmounts, showReset: large)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top, spacing: 7) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        ServiceIcon(serviceID: item.id, fallbackSystemName: item.iconName, size: 16)
                        Text(large ? item.name : item.shortName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(item.periodLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .widgetLayoutFrame("period:\(item.id)")
                    if large, item.isRemainingAvailable, let reset = item.remainingResetText() {
                        Text("リセット：\(reset.hasPrefix("あと") ? String(reset.dropFirst(2)) : reset)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .widgetLayoutFrame("reset:\(item.id)")
                    }
                }
                .frame(width: nameWidth, alignment: .leading)

                VStack(alignment: .trailing, spacing: 0) {
                    if item.isRemainingAvailable {
                        HStack(spacing: 7) {
                            WidgetRemainingBar(item: item)
                            Text(item.remainingSource.percentText(item.remainingPercent))
                                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                                .foregroundStyle(percentColor(item.remainingPercent))
                                .fixedSize()
                                .frame(width: 66, alignment: .trailing)
                                .widgetLayoutFrame("primary:\(item.id)")
                        }
                    } else {
                        Text("公式残量 未取得")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .trailing)
                            .widgetLayoutFrame("primary:\(item.id)")
                    }
                    if let usage = text.usage {
                        Text(usage)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .widgetLayoutFrame("usage:\(item.id)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .widgetLayoutFrame("row:\(item.id)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.accessibilityLabel)
    }
}

struct WidgetRowText {
    let item: WidgetServiceItem
    let showAmounts: Bool
    var showReset: Bool = true

    var usage: String? {
        guard showAmounts, !item.isQuotaOnly else { return nil }
        return item.isRemainingAvailable
            ? "\(item.usedDisplay)/\(item.limitDisplay) \(item.unit)"
            : "推定使用量 \(item.usedDisplay) \(item.unit)"
    }

    var accessibilityLabel: String {
        let value: String
        if item.isRemainingAvailable {
            let source = item.remainingSource == .official ? "公式残量" : "設定上限からの目安"
            value = "\(source)、残り\(item.remainingPercent)パーセント"
        } else {
            value = "公式残量 未取得"
        }
        var parts = [item.name, item.periodLabel, value]
        if let usage {
            parts.append(item.isRemainingAvailable
                ? "利用量 \(item.usedDisplay)、上限 \(item.limitDisplay) \(item.unit)"
                : usage)
        }
        if showReset, item.isRemainingAvailable, let reset = item.remainingResetText() {
            parts.append("リセット：\(reset)")
        }
        return parts.joined(separator: "、")
    }
}

private struct WidgetRemainingBar: View {
    let item: WidgetServiceItem

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .widgetLayoutFrame("bar.track:\(item.id)")
                Capsule().fill(barColor(item.remainingPercent))
                    .frame(width: remainingFillWidth(ratio: item.remainingRatio, width: geometry.size.width))
                    .widgetLayoutFrame("bar.fill:\(item.id)")
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

func remainingFillWidth(ratio: Double, width: CGFloat) -> CGFloat {
    guard ratio.isFinite, width.isFinite else { return 0 }
    return max(0, width) * CGFloat(min(max(ratio, 0), 1))
}

private func percentColor(_ percent: Int) -> Color {
    percent <= 15 ? .red : percent <= 35 ? .orange : .primary
}

private func barColor(_ percent: Int) -> Color {
    percent <= 15 ? .red : percent <= 35 ? .orange : .primary.opacity(0.68)
}

private struct WidgetEmptyContent: View {
    let hasData: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(hasData ? "表示するサービスがありません" : "データ未取得")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(hasData ? "AIMeterの設定でサービスを有効にしてください" : "AIMeterを開いて更新してください")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// Frames of the real views allow tests to detect overflow and compare axes.
struct WidgetLayoutFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private extension View {
    func widgetLayoutFrame(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: WidgetLayoutFramesKey.self,
                                   value: [key: geometry.frame(in: .named("AIMeterWidgetContent"))])
        })
    }
}
