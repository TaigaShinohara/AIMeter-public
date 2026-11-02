import WidgetKit
import SwiftUI
import AIMeterCore
import AIMeterWidgetUI
import AIMeterWidgetFixtures

private struct QAEntry: TimelineEntry {
    let date: Date
    let snapshot: AIMeterWidgetSnapshot
}

/// No production provider, cache, settings, or network is used by this target.
private struct QAProvider: TimelineProvider {
    let scenario: WidgetFixtureScenario

    func placeholder(in context: Context) -> QAEntry {
        entry(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QAEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QAEntry>) -> Void) {
        completion(Timeline(entries: [entry(at: Date())], policy: .never))
    }

    private func entry(at date: Date) -> QAEntry {
        QAEntry(date: date, snapshot: WidgetFixtures.snapshot(for: scenario, at: date))
    }
}

private struct QAWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QAEntry
    let scenario: WidgetFixtureScenario

    var body: some View {
        AIMeterWidgetSurface(snapshot: entry.snapshot, family: family)
            .widgetURL(URL(string: "aimeter-widget-qa://\(scenario.rawValue)"))
    }
}

private struct QAScenarioWidget: Widget {
    let scenario: WidgetFixtureScenario
    var kind: String { "com.local.AIMeterWidgetQA.\(scenario.rawValue)" }

    init() {
        scenario = .normal
    }

    init(scenario: WidgetFixtureScenario) {
        self.scenario = scenario
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QAProvider(scenario: scenario)) { entry in
            QAWidgetEntryView(entry: entry, scenario: scenario)
        }
        .configurationDisplayName(Text(verbatim: "AIMeter QA · " + scenario.title))
        .description("配置・文字サイズを確認するための固定された合成データです。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Measures WidgetKit's actual proposal without changing the production UI.
private struct QAMeasurementContent: View {
    @Environment(\.widgetContentMargins) private var margins

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 4) {
                Text("QA 内容領域の計測").font(.system(size: 12, weight: .semibold))
                Text(verbatim: String(format: "内容 %.1f × %.1f pt", geometry.size.width, geometry.size.height))
                Text(verbatim: String(format: "余白 上%.1f 下%.1f 左%.1f 右%.1f",
                                     margins.top, margins.bottom, margins.leading, margins.trailing))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11).monospacedDigit())
        }
        .containerBackground(.ultraThinMaterial, for: .widget)
    }
}

private struct QAMeasurementWidget: Widget {
    let kind = "com.local.AIMeterWidgetQA.measurement"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QAProvider(scenario: .normal)) { _ in
            QAMeasurementContent()
        }
        .configurationDisplayName("AIMeter QA · 内容領域の計測")
        .description("WidgetKitが渡す実際の内容寸法と余白を確認します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AIMeterWidgetQABundle: WidgetBundle {
    var body: some Widget {
        QAScenarioWidget(scenario: .normal)
        QAScenarioWidget(scenario: .longMixed)
        QAScenarioWidget(scenario: .empty)
        QAScenarioWidget(scenario: .updateFailed)
        QAMeasurementWidget()
    }
}
