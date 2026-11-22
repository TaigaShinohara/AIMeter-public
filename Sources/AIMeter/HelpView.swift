import SwiftUI

/// One set of answers for the settings help screen and its search results.
enum HelpQuestions {
    struct Item: Identifiable {
        let id: String
        let question: String
        let answer: String
    }

    static let items: [Item] = [
        Item(id: "remaining", question: "「約」「未取得」は何を表していますか？",
             answer: "「約」は設定した上限からの残量の目安です。公式残量を取得できない枠は「未取得」とし、0%や逼迫順位には含めません。Geminiのログからは公式残量を算出しません。"),
        Item(id: "amounts", question: "使用量やリセット日時も見たい",
             answer: "使用量は「一般 → トークン量・利用回数を表示」で切り替えます。各サービスの情報ボタンで、データ元・参考額・取得できたリセット日時を確認できます。期間は「要点表示 / 全枠表示」、上限は「制限と予算」で変更します。"),
        Item(id: "collection", question: "何を集計していますか？",
             answer: collectionAnswer),
        Item(id: "other-devices", question: "ブラウザやスマホ、別のMacの利用も含みますか？",
             answer: otherDevicesAnswer),
        Item(id: "not-detected", question: "ツールが「未検出」になる場合は？",
             answer: pathAnswer),
        Item(id: "menu-bar", question: "メニューバーにはどの残量が表示されますか？",
             answer: "残量を算出できる枠のうち、残り割合が最も少ない枠を表示します。「一般 → メニューバー」で表示モードや優先する期間を変更できます。"),
        Item(id: "stop", question: "収集を止める・OpenAIキーを変更するには？",
             answer: "「サービス連携」でサービスをオフにすると、ログ収集とクラウド取得を停止します。メニューバー表示の切替は表示だけを変えます。OpenAIのキーはKeychainに残り、同じ画面の「保存済みキーの保守」で削除できます。新しいキーは「OpenAIの組織API」で入力し、保存してください。"),
        Item(id: "widget", question: "デスクトップに常時表示するには？",
             answer: "メニューバーの「ウィジェットを表示」で移動可能なカードを開けます。macOSのウィジェットは、デスクトップのウィジェット編集から追加します。反映時刻はmacOSが調整するため、本体の更新直後に変わらない場合があります。"),
        Item(id: "antigravity", question: "Antigravityの公式残量を表示するには？",
             answer: antigravityAnswer)
    ]

    static func matching(_ query: String) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.question.localizedCaseInsensitiveContains(query) || $0.answer.localizedCaseInsensitiveContains(query)
        }
    }

    #if AIMETER_APP_STORE
    private static let collectionAnswer = "サービスごとに許可した場所のローカルログを、このMac内で期間ごとに集計します。会話本文は保存・送信しません。任意のOpenAI連携では組織のAPI利用量・費用も使います。GCP連携には対応していません。"
    private static let otherDevicesAnswer = "ローカル集計は、このMacで読み取りを許可したログだけが対象です。ブラウザやスマホの会話を直接読む機能はありません。任意のOpenAI連携には、設定した組織のMac以外からのAPI利用分が含まれることがあります。"
    private static let pathAnswer = "「サービス連携」でサービスを選び、「読み取り先」でフォルダまたはファイルを選択してから更新してください。保存済みの選択を確認できない場合は、再選択します。"
    private static let antigravityAnswer = "Mac App Store版はAntigravityの公式残量取得に対応していません。Geminiの読み取り先でAntigravityのログを許可した場合も、集計するのは推定使用量です。"
    #else
    private static let collectionAnswer = "各AIツールがこのMacに保存したログやデータベースを、期間ごとに集計します。会話本文は保存・送信しません。任意のOpenAI・GCP連携では、組織・プロジェクトのAPI利用量も使います。"
    private static let otherDevicesAnswer = "ローカル集計は、このMacに保存されたログだけが対象です。ブラウザやスマホの会話を直接読む機能はありません。任意のOpenAI・GCP連携には、設定した組織・プロジェクトのMac以外からのAPI利用分が含まれることがあります。"
    private static let pathAnswer = "「サービス連携」でサービスを選び、「ローカルログパス」からログファイルまたはフォルダを指定して「検証 & 適用」を押します。シンボリックリンクではなく、実体のパスを指定してください。"
    private static let antigravityAnswer = "「サービス連携 → Antigravity」を有効にし、Antigravityを起動・ログインした状態で更新します。モデル群ごとの公式残量を取得し、2分以上古い値やリセット予定を過ぎた値は使いません。Geminiのログ由来の推定使用量とは別の情報です。"
    #endif
}

struct HelpView: View {
    @State private var searchText = ""

    var body: some View {
        SettingsForm {
            SettingsSection("よくある質問") {
                TextField("質問を検索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("よくある質問を検索")
                let items = HelpQuestions.matching(searchText)
                if items.isEmpty {
                    Text("該当する質問がありません。別の言葉で検索してください。")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    DisclosureGroup(item.question) {
                        Text(item.answer)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                }
            }

            SettingsSection("データと通信") {
                DisclosureGroup("データの扱いを確認") {
                    #if AIMETER_APP_STORE
                    Text("許可した場所のローカルログをこのMac内で集計します。任意のOpenAI連携は公式APIへ通信します。GCPとAntigravityの残量連携には対応していません。アップデートはMac App Storeから行います。")
                    #else
                    Text("ローカルログはMac内で集計します。任意のOpenAI・GCP連携は公式APIへ、Antigravity連携は同じMacの正規アプリへ通信します。アプリの更新はボタンを押したときにGitHubへ確認・ダウンロードします。")
                    #endif
                    Text("会話本文は集計ファイルに保存せず、連携先への要求にも含めません。トークン情報がない場合は、文字数を端末内で一時的に使うことがあります。")
                }
                .foregroundStyle(.secondary)
            }

            SettingsSection("お問い合わせ") {
                Link(SupportContact.email, destination: SupportContact.mailURL)
                Text("利用ログ・集計ファイル・APIキーは添付しないでください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("脆弱性を非公開で報告", destination: URL(string: "https://github.com/TaigaShinohara/AIMeter-public/security/advisories/new")!)
            }
        }
        .navigationTitle("ヘルプ & 情報")
    }
}
