import Foundation

enum AppLanguage: String {
    case russian = "ru"
    case english = "en"

    static var preferred: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .russian : .english
    }
}

enum L10n {
    static func text(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.preferred.rawValue
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

struct SessionNotice {
    let key: String
    var detail: String? = nil

    var text: String {
        let message = L10n.text(key)
        guard let detail, !detail.isEmpty else { return message }
        return message + " " + L10n.text(detail)
    }
}
