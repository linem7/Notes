import MarkdownUI
import SwiftUI

extension Theme {
    /// Board 里 Detail 的 Markdown 主题：移植 Chatbot 的 `Theme.chatbot`，字号缩小，去掉代码块的复制按钮。
    ///
    /// MarkdownUI 2.4.1 的 Theme 不是 Sendable，所以限定在 MainActor 上。
    @MainActor
    static let notes = Theme.basic
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.9))
            BackgroundColor(Color.primary.opacity(0.06))
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.2))
                .markdownMargin(top: 0, bottom: 6)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.15))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .markdownMargin(top: 0, bottom: 6)
        }
}
