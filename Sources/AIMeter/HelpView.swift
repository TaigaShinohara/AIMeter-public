import SwiftUI

// MARK: - Help & QA View
struct HelpView: View {
    var isMenuBar: Bool = false
    var onBack: () -> Void

    @State private var expandedQAIds: Set<String> = ["qa-1", "qa-2"]
    @State private var searchText: String = ""

    struct QAItem: Identifiable {
        let id: String
        let category: String
        let question: String
        let answer: String
    }

    private let qaItems: [QAItem] = [
        QAItem(
            id: "qa-1",
            category: "集計・仕組み",
            question: "使用量はどのように集計されていますか？",
            answer: "通常は、お使いの Mac 内に各 AI ツール（Cursor, Windsurf, Claude Code, Copilot, Codex, Gemini など）が保存したローカルセッションログやキャッシュデータベースを読み取り、タイムスタンプに基づいて 2時間 / 5時間 / 1日 / 7日 / 30日 ごとに合算します。この集計は Mac 内で行います。任意の OpenAI・GCP 連携を有効にすると、公式 API から取得した利用量も表示に使用します。Antigravity の公式残量は、同じ Mac の起動・ログイン済みアプリから取得します。"
        ),
        QAItem(
            id: "qa-2",
            category: "集計・仕組み",
            question: "ブラウザ版（Web）やスマホでの会話は反映されますか？",
            answer: "ローカルログの集計には、その Mac に保存されたデータだけが反映されます。ブラウザ版やスマホの会話を直接読み取る機能はありません。任意の OpenAI・GCP 連携を有効にした場合は、設定した組織・プロジェクトの API 利用量も表示に使用するため、Mac 以外からの API 利用分が含まれることがあります。"
        ),
        QAItem(
            id: "qa-3",
            category: "トラブルシューティング",
            question: "使っているツールが「未検出」と表示される場合は？",
            answer: "ポータブル版エディタや非標準のディレクトリにインストールしている場合、設定画面の「ログパス」ボタンから、ログファイル（.jsonl や state.vscdb）または保存先フォルダを直接指定できます。「検証 & 適用」を押して検証に成功すると即座に読み込まれます。"
        ),
        QAItem(
            id: "qa-4",
            category: "セキュリティ",
            question: "コードやプロンプトが外部に送信される心配はありませんか？",
            answer: "AIMeter は、ローカルログ内のコードやプロンプト本文を連携先 API の要求に含めません。ログの集計は Mac 内で行い、集計ファイル (~/.ai_meter_usage.json) はご自身のアカウントだけが読み書きできる権限（0600）で保存します。任意の OpenAI 連携は組織の利用量・費用 API へ、GCP 連携は gcloud のログイン情報を使って Google Cloud Monitoring へ通信します。Antigravity の残量取得は、同じ Mac のアプリとのローカル通信です。"
        ),
        QAItem(
            id: "qa-cloud-credentials",
            category: "セキュリティ",
            question: "クラウド連携を停止したり、OpenAI キーを変更するには？",
            answer: "設定 → サービス連携でサービスをオフにすると、そのサービスのローカルログ収集とクラウド取得を停止します。メニューバーへの表示切替は表示だけを制御します。OpenAI の保存済みキーは Keychain に残ります。旧設定の移行や、この端末の保存済みキーの削除は、連携がオフでも保守操作から行えます。キーは保存と読戻しの確認後だけ使用し、移行に失敗した場合は旧設定を残します。"
        ),
        QAItem(
            id: "qa-5",
            category: "使い方",
            question: "表示枠（2h / 5h / 1d / 7d / 30d）の切り替えや上限変更は？",
            answer: "通常は残り％を表示します。トークン数なども確認したい場合は、設定 → 一般の「トークン量・利用回数を表示」をオンにしてください。各サービスの情報ボタンでは、データ元・プランの補足、API換算額（参考）、取得できた枠のリセット日時を確認できます。上部の「要点 / 全枠」は表示する期間を切り替えます。各サービスの表示枠や上限値は設定から変更できます。"
        ),
        QAItem(
            id: "qa-6",
            category: "使い方",
            question: "メニューバーに表示されるパーセントは何を表していますか？",
            answer: "残量を算出できる枠のうち、残り割合が最も少ない枠を表示します。公式の利用率を取得できた枠はその値、設定した上限から計算する枠は「約」を付けた目安です。公式残量が必要で未取得のサービスは、逼迫順位や0%警告に含めません。"
        ),
        QAItem(
            id: "qa-antigravity-quota",
            category: "データ",
            question: "Antigravityの残量を表示するには？",
            answer: "設定 → サービス連携 → Antigravityを有効にし、Antigravityアプリを起動・ログインした状態で更新してください。AIMeterへの追加ログインは不要で、Antigravityが返すモデル群ごとの残り割合を表示します。トークン数からの推計ではありません。起動していない場合や残量を取得できない場合は未取得とし、2分以上古い値やリセット予定を過ぎた値は使いません。Antigravity内部のローカルAPIを使うため、アプリの更新で取得できなくなる場合があります。Geminiのカードは引き続きログ由来の推定使用量です。"
        ),
        QAItem(
            id: "qa-gemini-quota",
            category: "データ",
            question: "Geminiの残量が「未取得」なのはなぜ？",
            answer: "現在の収集元からはGeminiの公式残量を取得できません。ローカルログや任意のGCP連携で分かる使用量を、契約上の残り％に置き換えないため「未取得」と表示します。推定使用量は設定から表示でき、キャッシュの重み付けや文字数による推計を含む参考情報です。"
        ),
        QAItem(
            id: "qa-7",
            category: "使い方",
            question: "デスクトップウィジェットとして画面上に常時表示できますか？",
            answer: "メニューバーのカード下部にある「ウィジェット表示」ボタンをクリックすると、デスクトップ上にドラッグ移動可能なフローティングカードウィンドウが表示されます。"
        ),
        QAItem(
            id: "qa-8",
            category: "集計・仕組み",
            question: "複数台の Mac を使っている場合はどうなりますか？",
            answer: "ローカルログからの集計は各 Mac に保存されたデータが対象です。職場と自宅の Mac で作業を分担した場合、それぞれの端末のログを集計します。任意の OpenAI・GCP 連携の値は、端末別ではなく設定した組織・プロジェクトの API 利用量です。"
        )
    ]

    private var filteredQAs: [QAItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return qaItems
        }
        return qaItems.filter {
            $0.question.localizedCaseInsensitiveContains(searchText) ||
            $0.answer.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Bar
            HStack(spacing: 8) {
                if !isMenuBar {
                    Color.clear
                        .frame(width: 52, height: 16)
                        .accessibilityHidden(true)
                }

                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("戻る")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(NativeGlassButtonStyle())

                Text("ヘルプ & よくある質問")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer()

                LiquidGlassBadge(text: "AIMeter", icon: "sparkles", tint: .accentColor)
            }

            // About AIMeter Card
            HStack(alignment: .top, spacing: 10) {
                LiquidGlassIconOrb(
                    systemName: "gauge.with.needle.fill",
                    accent: .accentColor,
                    size: 28,
                    iconSize: 14
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("AIMeter について")
                        .font(.system(size: 12.5, weight: .bold))

                    Text("Mac 内で利用中の各 AI ツール（Cursor, Windsurf, Claude Code, GitHub Copilot, Gemini, OpenAI 等）のローカルログを直接解析し、リアルタイムの使用量・残量メーターとAPI換算コストを可視化するメニューバー＆ウィジェットアプリです。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2.5)
                }
            }
            .padding(11)
            .background(
                FrostedGlassCardBackground(cornerRadius: 12, accentTint: .accentColor)
            )

            // Search Filter
            Link("お問い合わせ: \(SupportContact.email)", destination: SupportContact.mailURL)
                .font(.caption)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("質問やキーワードを検索...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(NativeGlassButtonStyle())
                    .controlSize(.small)
                    .accessibilityLabel("検索をクリア")
                }
            }
            .controlSize(.small)

            // Q&A List
            ScrollView {
                VStack(spacing: 8) {
                    if filteredQAs.isEmpty {
                        Text("該当する質問が見つかりませんでした。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(filteredQAs) { item in
                            qaRowView(item: item)
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 340)
        }
        .liquidGlassGroup()
    }

    @ViewBuilder
    private func qaRowView(item: QAItem) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedQAIds.contains(item.id) },
            set: { expanded in
                if expanded { expandedQAIds.insert(item.id) }
                else { expandedQAIds.remove(item.id) }
            }
        )) {
            HStack(alignment: .top, spacing: 7) {
                Text("A.")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(item.answer)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(.top, 2)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Text("Q.")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)

                Text(item.question)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
        }
        .disclosureGroupStyle(.automatic)
        .padding(11)
        .background(
            FrostedGlassCardBackground(cornerRadius: 11)
        )
    }
}
