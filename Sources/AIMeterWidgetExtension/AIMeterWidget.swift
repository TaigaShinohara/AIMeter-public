import WidgetKit
import SwiftUI
import AIMeterCore
import AIMeterWidgetUI

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
        let snap = SharedStore.loadWidgetSnapshot(at: currentDate)

        // 15分後の再読込を要求。本体からもreloadを要求するが、反映時刻はOSが調整する。
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: currentDate) ?? currentDate.addingTimeInterval(900)
        // Expiry entries also work while the host is closed. Requesting a
        // timeline entry does not guarantee that WidgetKit renders it on time.
        let expirations = Set(snap.allServices.compactMap { item -> Date? in
            guard item.isRemainingAvailable, let expiry = item.quotaExpirationDate,
                  expiry > currentDate, expiry <= nextUpdate else { return nil }
            return expiry
        }).sorted()
        let entries = ([currentDate] + expirations).map { date in
            AIMeterWidgetEntry(date: date, snapshot: snap.expiringQuotas(at: date))
        }
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Production wrapper (identity and data path remain unchanged)
struct AIMeterWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: AIMeterWidgetEntry

    var body: some View {
        AIMeterWidgetSurface(snapshot: entry.snapshot, family: family)
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
