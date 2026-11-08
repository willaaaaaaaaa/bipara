import Foundation

public enum AppLocalization {
    public static func text(_ key: String, language: InterfaceLanguage) -> String {
        let bundle = Bundle.module.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .module
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
