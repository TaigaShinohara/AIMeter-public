import SwiftUI

/// A distinct, synthetic-only containing app for WidgetKit desktop QA.
@main
struct AIMeterWidgetQAHost: App {
    var body: some Scene {
        WindowGroup("AIMeter Widget QA") {
            VStack(alignment: .leading, spacing: 16) {
                Label("AIMeter Widget QA", systemImage: "gauge.with.needle")
                    .font(.title2.weight(.semibold))
                Text("レイアウト確認用の合成データを表示します。")
                Text("デスクトップの「ウィジェットを編集」で「AIMeter QA」を選び、小・中・大の表示を確認してください。")
                    .foregroundStyle(.secondary)
                Text("確認後は、追加したQA用ウィジェットをデスクトップから取り除いてください。")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 440)
            .fixedSize(horizontal: false, vertical: true)
            .onOpenURL { _ in
                // The dedicated QA URL only opens this explanatory host.
            }
        }
        .windowResizability(.contentSize)
    }
}
