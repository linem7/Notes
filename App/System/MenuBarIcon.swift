import SwiftUI

/// 菜单栏图标加数字（SPEC §1）：数字是今天到期 + 已逾期的未完成 Note 数量，为 0 时不显示。
struct MenuBarIcon: View {
    let count: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "note.text")
            if let count {
                Text(verbatim: count).monospacedDigit()
            }
        }
    }
}
