import SwiftUI

/// System tab navigation, with the standard segmented picker on older macOS.
struct UsageDisplayModePicker: View {
    @Binding var isDetailedView: Bool

    private var picker: some View {
        Picker("表示モード", selection: $isDetailedView) {
            Text("要点表示").tag(false)
            Text("全枠表示").tag(true)
        }
        .labelsHidden()
    }

    var body: some View {
        Group {
            if #available(macOS 27.0, *) {
                picker.pickerStyle(.tabs)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
        .controlSize(.small)
        .help("要点表示は残量の割合が最も少ない枠と月間枠、全枠表示は有効なすべての枠を表示します")
    }
}
