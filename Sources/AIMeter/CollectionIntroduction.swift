import SwiftUI
import CoreFoundation

enum CollectionIntroduction {
    static let acknowledgmentPreference = "hasAcknowledgedCollectionV1"

    /// Earlier versions started collection at launch. Preserve those users'
    /// chosen services without presenting a new-install screen after an update.
    static func hasAcknowledged(in defaults: UserDefaults) -> Bool {
        if let value = defaults.object(forKey: acknowledgmentPreference) {
            return isTrueBoolean(value)
        }
        return ["didCalibrateRealLimitsV1", "didAutoSeedLocalProvidersV2", "didMigrateHonestCostsV3"]
            .contains { key in
                defaults.object(forKey: key).map(isTrueBoolean) ?? false
            }
    }

    private static func isTrueBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
}

struct CollectionIntroductionView: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AIMeterへようこそ", systemImage: "gauge.with.needle")
                .font(.headline)

            Text("AIツールの利用状況を、このMacで集計して表示します。開始するまではログを読み取りません。")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("最初に集計するサービス")
                    .font(.subheadline.weight(.semibold))
                Toggle("Codexのローカルログ", isOn: $monitor.showOpenAISection)
                Toggle("Geminiのローカルログ", isOn: $monitor.showGeminiSection)
                Text("他のサービスやログの場所は、開始後に「設定 → サービス連携」から選べます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                introductionDetail("読み取る内容", text: "利用量の情報を読み、数値がないログでは会話本文の文字数を端末内で一時的に使うことがあります。")
                introductionDetail("保存と通信", text: "集計はこのMacに保存し、会話本文は集計へ保存せず外部へ送りません。任意のAPI連携を設定すると、キーなどをその連携先の認証に使い、利用量を照会します。更新の確認・取得ではGitHubへ接続します。")
                introductionDetail("表示の意味", text: "各AIサービスとは独立した非公式ツールです。設定上限からの目安や推定使用量は、公式の残量・請求額とは異なることがあります。")
                introductionDetail("いつでも停止", text: "「設定 → サービス連携」でサービスを無効にすると、そのサービスの収集と任意API取得を停止します。アプリの終了でも収集を停止できます。")
            }

            Button("選んだサービスで使い始める") {
                monitor.beginCollection()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("begin-collection")

            Text("すべてオフのまま開始し、あとで設定することもできます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
    }

    private func introductionDetail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
