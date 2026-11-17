import Foundation
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case color
    case motion
    case region
    case general
    var id: String { rawValue }
}

enum LanguagePreference: String, CaseIterable, Identifiable {
    case auto = "auto"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"

    var id: String { rawValue }
}

enum AppLanguage: String, CaseIterable {
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"

    static func resolve(
        preference: LanguagePreference,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch preference {
        case .zhHant: return .zhHant
        case .en: return .en
        case .ja: return .ja
        case .auto: return detect(from: preferredLanguages)
        }
    }

    static func detect(from preferredLanguages: [String]) -> AppLanguage {
        for tag in preferredLanguages {
            let lower = tag.lowercased()
            if lower.hasPrefix("ja") { return .ja }
            if lower.hasPrefix("zh") { return .zhHant }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// Reactive text value that re-evaluates in whichever language is currently active.
struct LText: Equatable {
    private let id: String
    private let resolver: (AppLanguage) -> String

    init(id: String = UUID().uuidString, _ resolver: @escaping (AppLanguage) -> String) {
        self.id = id
        self.resolver = resolver
    }

    func resolve(_ language: AppLanguage) -> String { resolver(language) }

    static func == (lhs: LText, rhs: LText) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    private static let preferenceKey = "appLanguage"

    @Published var preference: LanguagePreference {
        didSet {
            defaults.set(preference.rawValue, forKey: Self.preferenceKey)
            resolved = AppLanguage.resolve(preference: preference, preferredLanguages: preferredLanguages)
        }
    }
    @Published private(set) var resolved: AppLanguage

    private let defaults: UserDefaults
    private let preferredLanguages: [String]

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let saved = defaults.string(forKey: Self.preferenceKey).flatMap(LanguagePreference.init(rawValue:)) ?? .auto
        self.preference = saved
        self.resolved = AppLanguage.resolve(preference: saved, preferredLanguages: preferredLanguages)
    }
}

enum L10n {
    @MainActor static var currentLanguage: AppLanguage {
        LocalizationManager.shared.resolved
    }

    private static func tr(_ lang: AppLanguage, _ zhHant: String, _ en: String, _ ja: String) -> String {
        switch lang {
        case .zhHant: return zhHant
        case .en: return en
        case .ja: return ja
        }
    }

    // MARK: - App & Tabs

    static func appTitle(_ l: AppLanguage) -> String {
        tr(l, "Ado 手燈連動", "Ado Light Stick Sync", "Ado ペンライト連動")
    }

    static func tabName(_ tab: SettingsTab, _ l: AppLanguage) -> String {
        switch tab {
        case .color: return tr(l, "色彩", "Color", "カラー")
        case .motion: return tr(l, "動態", "Motion", "モーション")
        case .region: return tr(l, "取色範圍", "Capture Area", "範囲")
        case .general: return tr(l, "一般", "General", "一般")
        }
    }

    static func settingsTabsAccessibility(_ l: AppLanguage) -> String {
        tr(l, "設定分頁", "Settings tabs", "設定タブ")
    }

    static func footerNotice(_ l: AppLanguage) -> String {
        tr(
            l,
            "自動略過黑邊與字幕；畫面與聲音都不儲存或上傳。",
            "Letterbox bars & subtitles are skipped automatically; video and audio are never stored or uploaded.",
            "黒帯と字幕は自動で除外されます。映像や音声の保存・送信は行いません。"
        )
    }

    static func openScreenPermissionSettings(_ l: AppLanguage) -> String {
        tr(l, "開啟螢幕錄製設定", "Open Screen Recording Settings", "画面収録の設定を開く")
    }

    // MARK: - Live Card

    static func statusPill(_ phase: PenlightController.Phase, failed: Bool, _ l: AppLanguage) -> String {
        switch phase {
        case .idle: return failed ? tr(l, "已停止", "Stopped", "停止") : tr(l, "待機", "Idle", "待機")
        case .connecting: return tr(l, "連線中", "Connecting", "接続中")
        case .syncing: return tr(l, "連動中", "Syncing", "連動中")
        case .reconnecting: return tr(l, "重新連線中", "Reconnecting", "再接続中")
        case .stopping: return tr(l, "停止中", "Stopping", "停止中")
        }
    }

    static func siteColorTile(_ l: AppLanguage) -> String {
        tr(l, "網站顏色", "Website Color", "サイトカラー")
    }

    static func siteColorTooltip(_ l: AppLanguage) -> String {
        tr(
            l,
            "按一下在瀏覽器中開啟 Ado 應援預習網站",
            "Click to open the Ado Cheer Guide website in your browser",
            "クリックしてブラウザで Ado 応援予習サイトを開く"
        )
    }

    static func screenTile(_ l: AppLanguage) -> String {
        tr(l, "螢幕", "Screen", "画面")
    }

    static func lampTile(_ l: AppLanguage) -> String {
        tr(l, "手燈", "Light Stick", "ペンライト")
    }

    static func siteSongCaption(title: String, state: SitePlayingState, _ l: AppLanguage) -> String {
        let stateText = sitePlayingState(state, l)
        if title.isEmpty { return stateText }
        switch l {
        case .zhHant: return "〈\(title)〉\(stateText)"
        case .en: return "\"\(title)\" · \(stateText)"
        case .ja: return "「\(title)」\(stateText)"
        }
    }

    static func sitePlayingState(_ state: SitePlayingState, _ l: AppLanguage) -> String {
        switch state {
        case .waiting: return tr(l, "等待網站…", "Waiting for site…", "サイト待機中…")
        case .playing: return tr(l, "播放中", "Playing", "再生中")
        case .paused: return tr(l, "暫停", "Paused", "一時停止")
        }
    }

    static func noLampFoundHint(_ l: AppLanguage) -> String {
        tr(l, "尚未找到手燈，請按「掃描」", "No light stick found. Click \"Scan\".", "ペンライトが見つかりません。「スキャン」を押してください。")
    }

    static func scanButton(isScanning: Bool, _ l: AppLanguage) -> String {
        isScanning ? tr(l, "停止", "Stop", "停止") : tr(l, "掃描", "Scan", "スキャン")
    }

    static func startSync(_ l: AppLanguage) -> String {
        tr(l, "開始連動", "Start Sync", "連動開始")
    }

    static func stopSync(_ l: AppLanguage) -> String {
        tr(l, "停止連動", "Stop Sync", "連動停止")
    }

    static func lampLastUsed(_ l: AppLanguage) -> String {
        tr(l, "上次使用", "Last used", "前回使用")
    }

    // MARK: - Color Settings

    static func colorSourceHeading(_ l: AppLanguage) -> String {
        tr(l, "取色來源", "Color Source", "カラーソース")
    }

    static func colorSourceName(_ source: ColorSource, _ l: AppLanguage) -> String {
        switch source {
        case .screen: return tr(l, "螢幕", "Screen", "画面")
        case .site: return tr(l, "網站（Ado 應援預習）", "Website (Ado Cheer Guide)", "サイト（Ado 応援予習）")
        }
    }

    static func openSiteButton(songTitle: String, _ l: AppLanguage) -> String {
        if songTitle.isEmpty {
            return tr(l, "開啟 Ado 應援預習網站", "Open Ado Cheer Guide", "Ado 応援予習サイトを開く")
        }
        return tr(
            l,
            "在網站開啟〈\(songTitle)〉",
            "Open \"\(songTitle)\" on site",
            "サイトで「\(songTitle)」を開く"
        )
    }

    static func stylePresetsHeading(_ l: AppLanguage) -> String {
        tr(l, "風格預設", "Style Presets", "スタイルプリセット")
    }

    static func presetName(_ preset: ColorPreset, _ l: AppLanguage) -> String {
        switch preset.id {
        case "自然": return tr(l, "自然", "Natural", "ナチュラル")
        case "標準": return tr(l, "標準", "Standard", "標準")
        case "鮮豔": return tr(l, "鮮豔", "Vivid", "鮮やか")
        case "演唱會": return tr(l, "演唱會", "Concert", "ライブ")
        case "電影院": return tr(l, "電影院", "Cinema", "シネマ")
        default: return preset.name
        }
    }

    static func vibranceLabel(_ l: AppLanguage) -> String { tr(l, "鮮豔度", "Vibrance", "鮮やかさ") }
    static func minBrightnessLabel(_ l: AppLanguage) -> String { tr(l, "最低亮度", "Min Brightness", "最低輝度") }
    static func brightnessLabel(_ l: AppLanguage) -> String { tr(l, "整體亮度", "Brightness", "全体の明るさ") }
    static func warmthLabel(_ l: AppLanguage) -> String { tr(l, "色溫", "Color Temp", "色温度") }
    static func offLabel(_ l: AppLanguage) -> String { tr(l, "關", "Off", "オフ") }

    static func warmthValue(_ value: Double, _ l: AppLanguage) -> String {
        let amount = Int((abs(value) * 100).rounded())
        if amount == 0 { return tr(l, "中性", "Neutral", "ニュートラル") }
        if value > 0 { return tr(l, "暖 \(amount)", "Warm \(amount)", "暖 \(amount)") }
        return tr(l, "冷 \(amount)", "Cool \(amount)", "冷 \(amount)")
    }

    static func colorSliderHint(_ l: AppLanguage) -> String {
        tr(
            l,
            "調整會立刻套用到手燈；左右箭頭可微調選取的滑桿。",
            "Changes apply to the light stick immediately; use Left/Right arrows to fine-tune.",
            "調整は即座にペンライトへ反映されます。左右キーで微調整できます。"
        )
    }

    static func resetSliderTooltip(_ l: AppLanguage) -> String {
        tr(l, "恢復預設值", "Reset to default", "初期値に戻す")
    }

    static func resetSliderAccessibility(_ title: String, _ l: AppLanguage) -> String {
        tr(l, "將\(title)恢復預設值", "Reset \(title) to default", "\(title)を初期値に戻す")
    }

    // MARK: - Motion Settings

    static func lowLatencyTitle(_ l: AppLanguage) -> String { tr(l, "低延遲模式", "Low-Latency Mode", "低遅延モード") }
    static func lowLatencySubtitle(_ l: AppLanguage) -> String {
        tr(l, "漸變最多 0.15 秒，燈光緊跟畫面", "Caps fade at 0.15 s so the light tracks tightly", "フェードを最大 0.15 秒に制限して画面に密着追従")
    }

    static func fadeTimeLabel(_ l: AppLanguage) -> String { tr(l, "漸變時間", "Fade Time", "フェード時間") }
    static func fadeTimeValue(_ seconds: Double, _ l: AppLanguage) -> String {
        if seconds < 0.05 { return tr(l, "立即", "Instant", "即時") }
        return tr(
            l,
            String(format: "%.1f 秒", seconds),
            String(format: "%.1f s", seconds),
            String(format: "%.1f 秒", seconds)
        )
    }

    static func sceneCutsTitle(_ l: AppLanguage) -> String { tr(l, "換場快切", "Scene Cuts", "シーンカット") }
    static func sceneCutsSubtitle(_ l: AppLanguage) -> String {
        tr(l, "畫面大幅換色時加快漸變", "Speeds up fade on large screen color jumps", "画面の大きな色変化時に素早く切り替え")
    }

    static func breathingTitle(_ l: AppLanguage) -> String { tr(l, "呼吸律動", "Breathing", "ブリージング") }
    static func breathingSubtitle(_ l: AppLanguage) -> String {
        tr(l, "沒有音樂時，顏色穩定就緩慢起伏", "Gently pulses brightness when steady with no music", "音楽がなく色が安定している時にゆっくり明滅")
    }

    static func beatSyncTitle(_ l: AppLanguage) -> String { tr(l, "跟音樂節拍", "Music Beat Sync", "音楽ビート連動") }

    static func beatStyleName(_ style: BeatStyle, _ l: AppLanguage) -> String {
        switch style {
        case .auto: return tr(l, "自動", "Auto", "自動")
        case .flash: return tr(l, "加亮", "Flash", "フラッシュ")
        case .blink: return tr(l, "亮滅", "Blink", "点滅")
        case .colors: return tr(l, "換色", "Colors", "カラー")
        case .breathe: return tr(l, "呼吸", "Breathe", "呼吸")
        }
    }

    static func beatStyleSummary(_ style: BeatStyle, _ l: AppLanguage) -> String {
        switch style {
        case .auto: return tr(l, "依 BPM 切換：快歌亮滅、中速換色、慢歌跟拍呼吸", "Auto by BPM: Blink for fast, Colors for mid, Breathe for slow", "BPMに応じて自動切替：速い曲は点滅、中速はカラー、遅い曲は呼吸")
        case .flash: return tr(l, "拍點瞬間變亮，拍間稍暗", "Pops to full brightness on each beat, slightly dimmer between", "ビートで明るく光り、ビート間は少し暗くなります")
        case .blink: return tr(l, "拍上亮、拍間暗，像演唱會燈海", "Lit on the beat and dark between, like a concert light sea", "ビートで点灯し、ビート間は消灯（ライブのペンライト海風）")
        case .colors: return tr(l, "每拍輪流：原色、相似色、原色、對比色", "Cycles each beat: base → similar → base → opposite", "拍ごとに切替：元の色 → 類似色 → 元の色 → 補色")
        case .breathe: return tr(l, "跟著拍子緩慢起伏，每兩拍一次", "Rises and falls smoothly once every two beats", "2拍ごとにリズムに合わせてゆっくり明滅")
        }
    }

    static func beatSummarySite(_ l: AppLanguage) -> String {
        tr(l, "由網站自動同步歌曲拍點與高潮閃爍", "Syncs song beats and climax flashes directly from the website", "サイトの曲のビートとサビの点滅を自動同期")
    }

    static func beatSummaryOff(_ l: AppLanguage) -> String {
        tr(l, "只跟畫面顏色，不聽音樂", "Follows screen color only, without listening to audio", "音声を聴かず、画面の色のみに連動")
    }

    static func musicStatusSiteBpm(_ bpm: Int, _ l: AppLanguage) -> String {
        tr(l, "\(bpm) BPM（網站節拍）", "\(bpm) BPM (Site Beat)", "\(bpm) BPM（サイトビート）")
    }

    static func musicStatusSiteWaiting(_ l: AppLanguage) -> String {
        tr(l, "等待網站節拍…", "Waiting for site beat…", "サイトビート待機中…")
    }

    static func musicStatusWaitingMusic(_ l: AppLanguage) -> String {
        tr(l, "等待音樂…", "Waiting for music…", "音楽を待機中…")
    }

    static func musicStatusDetected(bpm: Int?, activeStyle: BeatStyle?, isAuto: Bool, _ l: AppLanguage) -> String {
        var text = bpm.map { tr(l, "偵測到 \($0) BPM", "\($0) BPM detected", "\($0) BPM 検出") }
            ?? tr(l, "偵測到節拍", "Beat detected", "ビート検出")
        if isAuto, let activeStyle {
            text += "・\(beatStyleName(activeStyle, l))"
        }
        return text
    }

    // MARK: - Region Settings

    static func regionSiteNotice(_ l: AppLanguage) -> String {
        tr(
            l,
            "網站模式不需要框選。顏色與拍點直接來自 Ado 應援預習網站。",
            "Capture area is not needed in Website mode. Colors and beats come directly from Ado Cheer Guide.",
            "サイトモードでは範囲選択は不要です。色とビートは応援予習サイトから直接取得されます。"
        )
    }

    static func selectRegionButton(_ l: AppLanguage) -> String {
        tr(l, "框選範圍…", "Select Area…", "範囲を選択…")
    }

    static func wholeScreenButton(_ l: AppLanguage) -> String {
        tr(l, "整個螢幕", "Whole Screen", "画面全体")
    }

    static func regionHint(_ l: AppLanguage) -> String {
        tr(
            l,
            "影片沒有全螢幕時，框選影片所在區域可讓顏色更準。範圍固定在螢幕上的位置，移動影片視窗後請重新框選。",
            "When the video isn't full screen, selecting its area gives more accurate colors. The area stays fixed on screen; re-select if you move the video window.",
            "動画が全画面でない場合、動画の範囲を選択すると色がより正確になります。範囲は画面上の位置に固定されるため、ウィンドウを移動したら再選択してください。"
        )
    }

    static func regionWholeScreenDesc(_ l: AppLanguage) -> String {
        tr(l, "目前：整個主螢幕", "Current: Whole main screen", "現在：メイン画面全体")
    }

    static func regionCustomDesc(widthPct: Double, heightPct: Double, _ l: AppLanguage) -> String {
        tr(
            l,
            String(format: "目前：框選範圍（寬 %.0f%%、高 %.0f%%）", widthPct, heightPct),
            String(format: "Current: Selected area (W %.0f%%, H %.0f%%)", widthPct, heightPct),
            String(format: "現在：選択範囲（幅 %.0f%%、高さ %.0f%%）", widthPct, heightPct)
        )
    }

    static func regionOverlayHint(_ l: AppLanguage) -> String {
        tr(
            l,
            "拖曳框選影片所在的範圍，手燈只跟這塊畫面變色。按 Esc 取消。",
            "Drag to select the video area; the light stick will follow only this region. Press Esc to cancel.",
            "ドラッグして動画の範囲を選択（この部分の色のみに連動）。Esc キーでキャンセル。"
        )
    }

    // MARK: - General Settings & Updates

    static func languageTitle(_ l: AppLanguage) -> String { tr(l, "語言", "Language", "言語") }
    static func languageSubtitle(_ l: AppLanguage) -> String {
        tr(l, "跟隨系統語言或手動指定介面語言", "Follow system language or choose manually", "システム設定に従うか、表示言語を手動で選択")
    }

    static func languageOptionName(_ pref: LanguagePreference, _ l: AppLanguage) -> String {
        switch pref {
        case .auto: return tr(l, "自動（跟隨系統）", "Auto (System)", "自動（システム設定）")
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    static func checkUpdatesTitle(_ l: AppLanguage) -> String {
        tr(l, "啟動時檢查更新", "Check for Updates on Launch", "起動時にアップデートを確認")
    }

    static func currentVersionSubtitle(_ version: String, _ l: AppLanguage) -> String {
        tr(l, "目前版本 v\(version)", "Current version v\(version)", "現在のバージョン v\(version)")
    }

    static func updateDefaultNote(_ l: AppLanguage) -> String {
        tr(l, "只讀取 GitHub 上的版本號，不傳送任何資料。", "Reads only the version tag from GitHub; no data is sent.", "GitHub のバージョン番号のみを取得し、データは送信しません。")
    }

    static func checkNowButton(_ l: AppLanguage) -> String { tr(l, "立即檢查", "Check Now", "今すぐ確認") }
    static func updateChecking(_ l: AppLanguage) -> String { tr(l, "正在檢查…", "Checking…", "確認中…") }
    static func updateNewVersion(_ tag: String, _ l: AppLanguage) -> String {
        tr(l, "有新版本 \(tag)", "New version \(tag) available", "新しいバージョン \(tag) があります")
    }
    static func updateLatest(_ version: String, _ l: AppLanguage) -> String {
        tr(l, "已是最新版（v\(version)）", "Up to date (v\(version))", "最新バージョンです（v\(version)）")
    }
    static func updateFailed(_ l: AppLanguage) -> String {
        tr(l, "無法檢查更新，請確認網路連線。", "Unable to check for updates. Please check your connection.", "アップデートを確認できません。ネットワーク接続を確認してください。")
    }

    static func updateAlertTitle(_ version: String, _ l: AppLanguage) -> String {
        tr(l, "有新版本 \(version)", "New Version \(version)", "新しいバージョン \(version)")
    }

    static func updateDownloadButton(_ l: AppLanguage) -> String { tr(l, "前往下載", "Download", "ダウンロード") }
    static func updateSkipButton(_ l: AppLanguage) -> String { tr(l, "略過這個版本", "Skip This Version", "このバージョンをスキップ") }
    static func updateLaterButton(_ l: AppLanguage) -> String { tr(l, "稍後", "Later", "あとで") }

    static func updateAlertMessage(_ currentVersion: String, _ l: AppLanguage) -> String {
        tr(
            l,
            "目前是 v\(currentVersion)。下載新版後取代舊的 app 即可；更新後需要重新允許藍牙與螢幕錄製權限。",
            "You have v\(currentVersion). Download the new version and replace the old app; you'll need to re-allow Bluetooth and Screen Recording permissions.",
            "現在のバージョンは v\(currentVersion) です。最新版をダウンロードして古いアプリと置き換えてください（更新後、Bluetooth と画面収録の権限を再度許可する必要があります）。"
        )
    }

    static func logTitle(_ l: AppLanguage) -> String { tr(l, "執行記錄", "Activity Log", "実行ログ") }
    static func logEmpty(_ l: AppLanguage) -> String { tr(l, "尚無記錄。", "No logs yet.", "ログはまだありません。") }

    static func resetTitle(_ l: AppLanguage) -> String { tr(l, "恢復預設效果", "Restore Default Effects", "デフォルト設定に戻す") }
    static func resetSubtitle(_ l: AppLanguage) -> String {
        tr(
            l,
            "色彩與動態設定全部恢復預設，手燈與取色範圍不變",
            "Resets all color and motion settings; keeps light stick & capture area",
            "カラーとモーション設定を初期化します（ペンライトと範囲は維持）"
        )
    }
    static func resetButton(_ l: AppLanguage) -> String { tr(l, "全部重設", "Reset All", "すべてリセット") }
    static func resetConfirmTitle(_ l: AppLanguage) -> String {
        tr(
            l,
            "要把色彩與動態設定全部恢復預設嗎？",
            "Reset all color and motion settings to defaults?",
            "カラーとモーション設定をすべて初期状態に戻しますか？"
        )
    }

    // MARK: - Controller Status, Errors & Logs

    static func statusBtStarting(_ l: AppLanguage) -> String {
        tr(l, "正在啟動藍牙…若系統詢問藍牙權限，請按「允許」。", "Starting Bluetooth… Click \"Allow\" if prompted for permission.", "Bluetooth を起動中…権限を求められたら「許可」を押してください。")
    }

    static func statusBtReady(_ l: AppLanguage) -> String {
        tr(l, "藍牙就緒。按「掃描」尋找手燈。", "Bluetooth ready. Click \"Scan\" to find your light stick.", "Bluetooth 準備完了。「スキャン」でペンライトを探してください。")
    }

    static func statusBtUnauthorized(_ l: AppLanguage) -> String {
        tr(l, "未允許藍牙權限。請在「系統設定 › 隱私權與安全性 › 藍牙」允許本 App。", "Bluetooth permission denied. Allow this app in System Settings › Privacy & Security › Bluetooth.", "Bluetooth の権限がありません。「システム設定 › プライバシーとセキュリティ › Bluetooth」で許可してください。")
    }

    static func statusBtOff(_ l: AppLanguage) -> String {
        tr(l, "藍牙已關閉，請開啟藍牙。", "Bluetooth is turned off. Please turn on Bluetooth.", "Bluetooth がオフです。Bluetooth をオンにしてください。")
    }

    static func statusBtUnsupported(_ l: AppLanguage) -> String {
        tr(l, "這台電腦不支援低功耗藍牙。", "This Mac does not support Bluetooth Low Energy.", "この Mac は Bluetooth Low Energy に対応していません。")
    }

    static func errBtUnavailable(_ l: AppLanguage) -> String {
        tr(l, "藍牙已無法使用，連動已停止。", "Bluetooth became unavailable; sync stopped.", "Bluetooth が利用できなくなったため、連動を停止しました。")
    }

    static func statusScanning(_ l: AppLanguage) -> String {
        tr(l, "掃描中：請讓手燈進入配對模式（長按背面按鈕至藍燈閃爍）。", "Scanning: Put your light stick in pairing mode (hold the back button until blue blinks).", "スキャン中：ペンライトをペアリングモード（背面ボタン長押しで青点滅）にしてください。")
    }

    static func statusScanNone(_ l: AppLanguage) -> String {
        tr(l, "沒有找到手燈。確認手燈在配對模式，且手機 App 已關閉。", "No light stick found. Make sure it's in pairing mode and the phone app is closed.", "見つかりませんでした。ペアリングモード中かつスマホアプリが終了しているか確認してください。")
    }

    static func statusScanFound(_ count: Int, _ l: AppLanguage) -> String {
        tr(
            l,
            "找到 \(count) 支手燈，選擇後按「開始連動」。",
            "Found \(count) light stick(s). Select one and click \"Start Sync\".",
            "\(count) 本のペンライトが見つかりました。選択して「連動開始」を押してください。"
        )
    }

    static func errScreenPermission(_ l: AppLanguage) -> String {
        tr(
            l,
            "需要螢幕錄製權限。請在「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許本 App，然後結束並重新開啟本 App。",
            "Screen Recording permission required. Allow this app in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen.",
            "画面収録の権限が必要です。「システム設定 › プライバシーとセキュリティ › 画面収録とシステムオーディオ録音」で許可し、アプリを再起動してください。"
        )
    }

    static func errNoDisplays(_ l: AppLanguage) -> String {
        tr(l, "找不到可擷取的螢幕。", "No screen displays are available to capture.", "取り込み可能な画面が見つかりません。")
    }

    static func errCouldNotReadScreenshot(_ l: AppLanguage) -> String {
        tr(l, "無法讀取螢幕畫面像素。", "Could not read pixels from the screen capture.", "画面のピクセルを読み取れませんでした。")
    }

    static func errSelectedLampNotFound(_ l: AppLanguage) -> String {
        tr(l, "找不到選擇的手燈。請先按「掃描」。", "Selected light stick not found. Click \"Scan\" first.", "選択したペンライトが見つかりません。先に「スキャン」を押してください。")
    }

    static func errWrongDeviceName(_ expected: String, _ l: AppLanguage) -> String {
        tr(l, "選擇的裝置名稱不是 \(expected)，已拒絕連線。請重新掃描。", "Device name is not \(expected); connection refused. Please scan again.", "選択したデバイス名が \(expected) ではないため接続を拒否しました。再スキャンしてください。")
    }

    static func statusConnecting(_ l: AppLanguage) -> String { tr(l, "連線中…", "Connecting…", "接続中…") }

    static func errConnectTimeout(_ l: AppLanguage) -> String {
        tr(l, "連線逾時。請讓手燈重新進入配對模式後再試。", "Connection timed out. Put the light stick in pairing mode and try again.", "接続がタイムアウトしました。ペアリングモードにして再度お試しください。")
    }

    static func errConnectedWrongLamp(_ l: AppLanguage) -> String {
        tr(l, "連上的裝置與選擇的手燈不符，已中斷。", "Connected device does not match the selected light stick; disconnected.", "接続されたデバイスが選択したものと一致しないため切断しました。")
    }

    static func statusDiscoveringServices(_ l: AppLanguage) -> String {
        tr(l, "已連線，尋找控制服務…", "Connected; discovering control service…", "接続完了、制御サービスを検索中…")
    }

    static func errFailedToConnect(_ detail: String?, _ l: AppLanguage) -> String {
        let msg = detail ?? tr(l, "未知錯誤", "unknown error", "不明なエラー")
        return tr(l, "無法連線：\(msg)。", "Could not connect: \(msg).", "接続できません：\(msg)。")
    }

    static func errDisconnected(_ l: AppLanguage) -> String {
        tr(l, "手燈連線中斷。請讓手燈重新進入配對模式後再按「開始連動」。", "Light stick disconnected. Put it back in pairing mode and click \"Start Sync\".", "ペンライトが切断されました。ペアリングモードにして再度「連動開始」を押してください。")
    }

    static func reasonDisconnected(_ detail: String?, _ l: AppLanguage) -> String {
        if let detail {
            return tr(l, "手燈連線中斷（\(detail)）", "Light stick disconnected (\(detail))", "ペンライトが切断されました（\(detail)）")
        }
        return tr(l, "手燈連線中斷", "Light stick disconnected", "ペンライトが切断されました")
    }

    static func errServiceDiscovery(_ detail: String, _ l: AppLanguage) -> String {
        tr(l, "服務探索失敗：\(detail)", "Service discovery failed: \(detail)", "サービス検索に失敗：\(detail)")
    }

    static func errNoControlService(_ l: AppLanguage) -> String {
        tr(l, "手燈沒有控制服務 0000。", "Control service 0000 not found on light stick.", "制御サービス 0000 が見つかりません。")
    }

    static func errCharDiscovery(_ detail: String, _ l: AppLanguage) -> String {
        tr(l, "特徵探索失敗：\(detail)", "Characteristic discovery failed: \(detail)", "キャラクタリスティック検索に失敗：\(detail)")
    }

    static func errCharNoWrite(_ l: AppLanguage) -> String {
        tr(l, "手燈的控制特徵 0000 不支援有回應寫入。", "Control characteristic 0000 does not support write-with-response.", "制御キャラクタリスティック 0000 が応答付き書き込みに対応していません。")
    }

    static func reasonWriteFailed(_ detail: String, _ l: AppLanguage) -> String {
        tr(l, "藍牙寫入失敗（\(detail)）", "Bluetooth write failed (\(detail))", "Bluetooth 書き込み失敗（\(detail)）")
    }

    static func reasonWriteTimeout(_ l: AppLanguage) -> String {
        tr(l, "藍牙寫入超過 8 秒沒有回應", "Bluetooth write timed out after 8 seconds", "Bluetooth 書き込みが 8 秒以上応答なし")
    }

    static func errScreenCaptureFailed(_ detail: String, _ l: AppLanguage) -> String {
        tr(l, "螢幕擷取失敗：\(detail)", "Screen capture failed: \(detail)", "画面キャプチャ失敗：\(detail)")
    }

    static func errEncodeFailed(_ detail: String, _ l: AppLanguage) -> String {
        tr(l, "無法編碼顏色指令：\(detail)", "Could not encode color command: \(detail)", "カラーコマンドのエンコードに失敗：\(detail)")
    }

    static func statusNotSyncing(_ l: AppLanguage) -> String { tr(l, "未連動。", "Not syncing.", "未連動。") }
    static func statusStopping(_ l: AppLanguage) -> String { tr(l, "停止中…", "Stopping…", "停止中…") }
    static func statusStoppedError(_ l: AppLanguage) -> String { tr(l, "連動已因錯誤停止。", "Sync stopped due to an error.", "エラーにより連動を停止しました。") }
    static func statusStoppedUser(_ l: AppLanguage) -> String { tr(l, "已停止連動。", "Sync stopped.", "連動を停止しました。") }

    static func statusSyncingSitePortInUse(_ l: AppLanguage) -> String {
        tr(l, "網站連動用的連接埠 51730 被別的程式佔用。", "Port 51730 for Website mode is in use by another app.", "サイト連動用のポート 51730 が他のアプリに使用されています。")
    }

    static func statusSyncingSite(_ l: AppLanguage) -> String {
        tr(l, "連動中：跟隨網站（Ado 應援預習）。", "Syncing: Following website (Ado Cheer Guide).", "連動中：サイトに追従中（Ado 応援予習）。")
    }

    static func statusSyncingScreen(hasRegion: Bool, _ l: AppLanguage) -> String {
        if hasRegion {
            return tr(l, "連動中：跟隨框選範圍的平均色。", "Syncing: Following selected area average color.", "連動中：選択範囲の平均色に追従中。")
        }
        return tr(l, "連動中：跟隨主螢幕平均色。", "Syncing: Following main screen average color.", "連動中：メイン画面全体の平均色に追従中。")
    }

    static func statusReconnecting(_ reason: String, windowSeconds: Int, _ l: AppLanguage) -> String {
        tr(
            l,
            "\(reason)，正在自動重新連線（最多 \(windowSeconds) 秒）…若一直連不上，請長按手燈背面按鈕進入配對模式。",
            "\(reason). Reconnecting automatically (up to \(windowSeconds)s)… If it fails, hold the lamp's back button for pairing mode.",
            "\(reason)。自動再接続中（最大 \(windowSeconds) 秒）…繋がらない場合は背面ボタンを長押ししてペアリングモードにしてください。"
        )
    }

    static func errReconnectTimedOut(_ reason: String, windowSeconds: Int, _ l: AppLanguage) -> String {
        tr(
            l,
            "\(reason)，\(windowSeconds) 秒內無法重新連上手燈。請讓手燈重新進入配對模式後再按「開始連動」。",
            "\(reason). Could not reconnect within \(windowSeconds)s. Put the lamp in pairing mode and click \"Start Sync\".",
            "\(reason)。\(windowSeconds) 秒以内に再接続できませんでした。ペアリングモードにして再度「連動開始」を押してください。"
        )
    }

    static func errAudioFailed(_ detail: String, _ l: AppLanguage) -> String {
        tr(
            l,
            "無法擷取系統音訊，節拍同步暫停（顏色連動照常）：\(detail)",
            "Could not capture system audio; beat sync paused (color sync continues): \(detail)",
            "システム音声を取得できないためビート連動を一時停止（色連動は継続）：\(detail)"
        )
    }

    static func latencySummary(
        intervalSeconds: Int,
        captureAvg: Double?,
        captureMax: Double?,
        btAvg: Double?,
        btMax: Double?,
        _ l: AppLanguage
    ) -> String {
        func desc(_ avg: Double?, _ maxVal: Double?) -> String {
            guard let avg, let maxVal else { return "—" }
            return tr(
                l,
                String(format: "%.0f ms（最高 %.0f）", avg, maxVal),
                String(format: "%.0f ms (max %.0f)", avg, maxVal),
                String(format: "%.0f ms（最大 %.0f）", avg, maxVal)
            )
        }
        return tr(
            l,
            "延遲（近 \(intervalSeconds) 秒平均）：畫面擷取 \(desc(captureAvg, captureMax))・藍牙來回 \(desc(btAvg, btMax))",
            "Latency (\(intervalSeconds)s avg): Capture \(desc(captureAvg, captureMax)) · BLE RTT \(desc(btAvg, btMax))",
            "遅延（直近 \(intervalSeconds) 秒平均）：画面取得 \(desc(captureAvg, captureMax))・BLE往復 \(desc(btAvg, btMax))"
        )
    }

    // MARK: - Log entries

    static func logPortInUse(_ l: AppLanguage) -> String {
        tr(l, "錯誤：網站連動用的連接埠 51730 被別的程式佔用。", "Error: Port 51730 for Website mode is in use.", "エラー：サイト連動用ポート 51730 が使用中です。")
    }

    static func logSourceSwitched(_ source: ColorSource, _ l: AppLanguage) -> String {
        let name = colorSourceName(source, l)
        return tr(l, "取色來源切換為：\(name)。", "Color source switched to: \(name).", "カラーソースを「\(name)」に切り替えました。")
    }

    static func logScanStart(_ targetName: String, _ l: AppLanguage) -> String {
        tr(l, "開始掃描 \(targetName)。", "Scanning for \(targetName)…", "\(targetName) のスキャンを開始しました。")
    }

    static func logLampFound(_ uuid: String, _ l: AppLanguage) -> String {
        tr(l, "找到手燈 \(uuid)。", "Found light stick \(uuid).", "ペンライトを検出：\(uuid)。")
    }

    static func logConnecting(_ targetName: String, _ uuid: String, _ l: AppLanguage) -> String {
        tr(l, "連線 \(targetName)（\(uuid)）。", "Connecting to \(targetName) (\(uuid)).", "\(targetName)（\(uuid)）に接続中。")
    }

    static func logConnectedDiscovering(_ l: AppLanguage) -> String {
        tr(l, "已連線，探索服務 0000。", "Connected; discovering service 0000.", "接続完了、サービス 0000 を検索中。")
    }

    static func logReconnected(_ l: AppLanguage) -> String {
        tr(l, "已自動重新連線，繼續連動。", "Reconnected automatically; resuming sync.", "自動再接続に成功し、連動を再開しました。")
    }

    static func logSyncStarted(_ l: AppLanguage) -> String {
        tr(l, "連動開始。", "Sync started.", "連動を開始しました。")
    }

    static func logErrorPrefix(_ message: String, _ l: AppLanguage) -> String {
        tr(l, "錯誤：\(message)", "Error: \(message)", "エラー：\(message)")
    }

    static func logStoppedByUser(_ l: AppLanguage) -> String {
        tr(l, "使用者停止連動。", "Sync stopped by user.", "ユーザー操作により連動を停止しました。")
    }

    static func logRegionCustom(widthPct: Double, heightPct: Double, _ l: AppLanguage) -> String {
        tr(
            l,
            String(format: "取色範圍改為框選區域（寬 %.0f%%、高 %.0f%%）。", widthPct, heightPct),
            String(format: "Capture area set to selected region (W %.0f%%, H %.0f%%).", widthPct, heightPct),
            String(format: "取り込み範囲を選択範囲に変更（幅 %.0f%%、高さ %.0f%%）。", widthPct, heightPct)
        )
    }

    static func logRegionWholeScreen(_ l: AppLanguage) -> String {
        tr(l, "取色範圍改回整個主螢幕。", "Capture area reset to whole main screen.", "取り込み範囲をメイン画面全体に戻しました。")
    }

    static func logReconnecting(_ reason: String, _ l: AppLanguage) -> String {
        tr(l, "\(reason)，自動重新連線中。", "\(reason); reconnecting automatically.", "\(reason)。自動再接続中。")
    }

    static func logAudioStarted(_ l: AppLanguage) -> String {
        tr(l, "節拍偵測：開始聆聽系統音訊。", "Beat detection: listening to system audio.", "ビート検出：システム音声の解析を開始しました。")
    }

    static func logAudioFailed(_ detail: String, _ l: AppLanguage) -> String {
        tr(l, "節拍偵測失敗：\(detail)", "Beat detection failed: \(detail)", "ビート検出失敗：\(detail)")
    }
}
