import NotesCore

extension ConnectionTemplate {
    /// 「+」菜单里的名字。
    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .bailian: String(localized: "Alibaba Cloud Model Studio")
        case .custom: String(localized: "Custom")
        }
    }
}
