import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        fatalError("\(file):\(line): \(message)")
    }
}

@main
struct LocalizationTests {
    @MainActor
    static func main() {
        // 1. Language auto-detection
        expect(AppLanguage.detect(from: ["zh-Hant-TW", "en-TW"]) == .zhHant, "zh-Hant-TW must map to .zhHant")
        expect(AppLanguage.detect(from: ["zh-HK", "en-US"]) == .zhHant, "zh-HK must map to .zhHant")
        expect(AppLanguage.detect(from: ["ja-JP", "en-US"]) == .ja, "ja-JP must map to .ja")
        expect(AppLanguage.detect(from: ["en-US", "zh-Hant-TW"]) == .en, "en-US first must map to .en")
        expect(AppLanguage.detect(from: ["fr-FR", "ja-JP"]) == .ja, "Fallback down preferredLanguages list must pick ja-JP")
        expect(AppLanguage.detect(from: ["fr-FR", "ko-KR"]) == .en, "Unsupported languages must fall back to .en")
        expect(AppLanguage.detect(from: []) == .en, "Empty preferredLanguages must fall back to .en")

        // 2. Explicit preference overrides system locale
        expect(AppLanguage.resolve(preference: .zhHant, preferredLanguages: ["en-US"]) == .zhHant, "Explicit zhHant overrides en")
        expect(AppLanguage.resolve(preference: .en, preferredLanguages: ["zh-Hant-TW"]) == .en, "Explicit en overrides zhHant")
        expect(AppLanguage.resolve(preference: .ja, preferredLanguages: ["zh-Hant-TW"]) == .ja, "Explicit ja overrides zhHant")
        expect(AppLanguage.resolve(preference: .auto, preferredLanguages: ["ja-JP"]) == .ja, "Auto follows system language")

        // 3. Persistence and live switching via LocalizationManager
        let suiteName = "penlight-sync.i18n-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = LocalizationManager(defaults: defaults, preferredLanguages: ["en-US"])
        expect(manager.preference == .auto && manager.resolved == .en, "Default preference must be auto -> en")
        manager.preference = .ja
        expect(manager.resolved == .ja, "Switching preference must update resolved immediately")
        let reloaded = LocalizationManager(defaults: defaults, preferredLanguages: ["en-US"])
        expect(reloaded.preference == .ja && reloaded.resolved == .ja, "Preference must persist in UserDefaults")

        // 4. All core tables return non-empty strings across all languages
        for lang in AppLanguage.allCases {
            expect(!L10n.appTitle(lang).isEmpty, "appTitle empty for \(lang)")
            expect(!L10n.footerNotice(lang).isEmpty, "footerNotice empty for \(lang)")
            for tab in SettingsTab.allCases {
                expect(!L10n.tabName(tab, lang).isEmpty, "tabName empty for \(tab) in \(lang)")
            }
            for preset in ColorPreset.all {
                expect(!L10n.presetName(preset, lang).isEmpty, "presetName empty for \(preset.id) in \(lang)")
            }
            for style in BeatStyle.allCases {
                expect(!L10n.beatStyleName(style, lang).isEmpty, "beatStyleName empty for \(style) in \(lang)")
                expect(!L10n.beatStyleSummary(style, lang).isEmpty, "beatStyleSummary empty for \(style) in \(lang)")
            }
            for source in ColorSource.allCases {
                expect(!L10n.colorSourceName(source, lang).isEmpty, "colorSourceName empty for \(source) in \(lang)")
            }
            for state in [SitePlayingState.waiting, .playing, .paused] {
                expect(!L10n.sitePlayingState(state, lang).isEmpty, "sitePlayingState empty in \(lang)")
            }
            for pref in LanguagePreference.allCases {
                expect(!L10n.languageOptionName(pref, lang).isEmpty, "languageOptionName empty for \(pref) in \(lang)")
            }
        }

        // 5. Distinct translations across zhHant, en, ja
        let titles = Set(AppLanguage.allCases.map { L10n.appTitle($0) })
        expect(titles.count == 3, "appTitle should have distinct zhHant/en/ja translations")
        let starts = Set(AppLanguage.allCases.map { L10n.startSync($0) })
        expect(starts.count == 3, "startSync should have distinct zhHant/en/ja translations")

        // 6. SettingsStore round-trip and clamping
        var store = SettingsStore(defaults: defaults)
        expect(store.colorSource == .screen && abs(store.fadeTime - 0.6) < 0.001, "SettingsStore defaults")
        store.colorSource = .site
        store.fadeTime = 9.0 // should clamp to 2.0
        store.vibrance = -1.0 // should clamp to 0.0
        store.brightness = 0.0 // should clamp to 0.1
        let reloadedStore = SettingsStore(defaults: defaults)
        expect(reloadedStore.colorSource == .site, "SettingsStore persists colorSource")
        expect(reloadedStore.fadeTime == 2.0, "SettingsStore clamps fadeTime upper bound")
        expect(reloadedStore.vibrance == 0.0, "SettingsStore clamps vibrance lower bound")
        expect(reloadedStore.brightness == 0.1, "SettingsStore clamps brightness lower bound")

        print("Localization self-tests passed")
    }
}
