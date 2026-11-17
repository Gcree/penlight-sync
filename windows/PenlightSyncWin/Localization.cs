using System.Drawing;
using PenlightSync.Core;

namespace PenlightSync.Win;

internal sealed record LText(Func<AppLanguage, string> Resolve)
{
    public string ResolveCurrent() => Resolve(L10n.CurrentLanguage);
}

internal static class L10n
{
    private static LanguagePreference _preference = LanguagePreference.Auto;
    private static AppLanguage _currentLanguage = LanguageResolver.Resolve(LanguagePreference.Auto);

    public static LanguagePreference Preference => _preference;
    public static AppLanguage CurrentLanguage => _currentLanguage;

    public static event Action? LanguageChanged;

    public static void SetPreference(LanguagePreference preference, bool notify = true)
    {
        var resolved = LanguageResolver.Resolve(preference);
        if (_preference == preference && _currentLanguage == resolved) return;
        _preference = preference;
        _currentLanguage = resolved;
        if (notify) LanguageChanged?.Invoke();
    }

    private static string Tr(AppLanguage lang, string zhHant, string en, string ja) => lang switch
    {
        AppLanguage.ZhHant => zhHant,
        AppLanguage.Ja => ja,
        _ => en,
    };

    // MARK: - App & Tabs

    public static string AppTitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "Ado 手燈連動", "Ado Light Stick Sync", "Ado ペンライト連動");

    public static string[] TabNames(AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return new[]
        {
            Tr(lang, "色彩", "Color", "カラー"),
            Tr(lang, "動態", "Motion", "モーション"),
            Tr(lang, "取色範圍", "Capture Area", "範囲"),
            Tr(lang, "一般", "General", "一般"),
        };
    }

    public static string SettingsTabsAccessibility(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "設定分頁", "Settings tabs", "設定タブ");

    public static string SelectedAccessibility(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "已選取", "Selected", "選択中");

    public static string FooterNotice(AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            "自動略過黑邊與字幕；畫面與聲音都不儲存或上傳。",
            "Letterbox bars & subtitles are skipped automatically; video and audio are never stored or uploaded.",
            "黒帯と字幕は自動で除外されます。映像や音声の保存・送信は行いません。"
        );

    // MARK: - Live Card

    public static (string Pill, Color Tone) StatusPill(Phase phase, bool failed, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return phase switch
        {
            Phase.Connecting => (Tr(lang, "連線中", "Connecting", "接続中"), Theme.Warning),
            Phase.Syncing => (Tr(lang, "連動中", "Syncing", "連動中"), Theme.Success),
            Phase.Reconnecting => (Tr(lang, "重新連線中", "Reconnecting", "再接続中"), Theme.Warning),
            Phase.Stopping => (Tr(lang, "停止中", "Stopping", "停止中"), Theme.Warning),
            _ => failed
                ? (Tr(lang, "已停止", "Stopped", "停止"), Theme.Danger)
                : (Tr(lang, "待機", "Idle", "待機"), Theme.SecondaryText),
        };
    }

    public static string SiteColorTileTitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "網站顏色 ↗", "Website Color ↗", "サイトカラー ↗");

    public static string SiteColorAccessibleName(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "網站顏色", "Website Color", "サイトカラー");

    public static string ScreenTile(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "螢幕", "Screen", "画面");

    public static string LampTile(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "手燈", "Light Stick", "ペンライト");

    public static string SelectLampAccessibility(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "選擇手燈", "Select light stick", "ペンライトを選択");

    public static string SelectLampPrompt(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "選擇手燈  ▾", "Select light stick  ▾", "ペンライトを選択  ▾");

    public static string NoLampFoundHint(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "尚未找到手燈，請按「掃描」", "No light stick found. Click \"Scan\".", "ペンライトが見つかりません。「スキャン」を押してください。");

    public static string LampLastUsed(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "上次使用", "Last used", "前回使用");

    public static string ScanButton(bool isScanning, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return isScanning ? Tr(lang, "停止掃描", "Stop scan", "スキャン停止") : Tr(lang, "↻ 掃描", "↻ Scan", "↻ スキャン");
    }

    public static string StartSyncButton(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "▶  開始連動", "▶  Start Sync", "▶  連動開始");

    public static string StopSyncButton(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "■  停止連動", "■  Stop Sync", "■  連動停止");

    public static string SitePlayingStateText(SitePlayingState state, AppLanguage? l = null) => state switch
    {
        SitePlayingState.Waiting => Tr(l ?? CurrentLanguage, "等待網站…", "Waiting for site…", "サイト待機中…"),
        SitePlayingState.Playing => Tr(l ?? CurrentLanguage, "播放中", "Playing", "再生中"),
        _ => Tr(l ?? CurrentLanguage, "暫停", "Paused", "一時停止"),
    };

    public static string SiteSongCaption(string title, SitePlayingState state, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        var stateText = SitePlayingStateText(state, lang);
        if (string.IsNullOrEmpty(title)) return stateText;
        return lang switch
        {
            AppLanguage.ZhHant => $"〈{title}〉{stateText}",
            AppLanguage.Ja => $"「{title}」{stateText}",
            _ => $"\"{title}\" · {stateText}",
        };
    }

    // MARK: - Color Settings

    public static string ColorSourceHeading(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "取色來源", "Color Source", "カラーソース");

    public static string[] ColorSourceNames(AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return new[] { ColorSourceName(ColorSource.Screen, lang), ColorSourceName(ColorSource.Site, lang) };
    }

    public static string ColorSourceName(ColorSource source, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return source == ColorSource.Site
            ? Tr(lang, "網站（Ado 應援預習）", "Website (Ado Cheer Guide)", "サイト（Ado 応援予習）")
            : Tr(lang, "螢幕", "Screen", "画面");
    }

    public static string OpenSiteButton(string songTitle, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        if (string.IsNullOrEmpty(songTitle))
        {
            return Tr(lang, "開啟 Ado 應援預習網站 ↗", "Open Ado Cheer Guide ↗", "Ado 応援予習サイトを開く ↗");
        }
        return Tr(
            lang,
            $"在網站開啟〈{songTitle}〉 ↗",
            $"Open \"{songTitle}\" on site ↗",
            $"サイトで「{songTitle}」を開く ↗"
        );
    }

    public static string StylePresetsHeading(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "風格預設", "Style Presets", "スタイルプリセット");

    public static string PresetName(ColorPresetId id, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return id switch
        {
            ColorPresetId.Natural => Tr(lang, "自然", "Natural", "ナチュラル"),
            ColorPresetId.Standard => Tr(lang, "標準", "Standard", "標準"),
            ColorPresetId.Vivid => Tr(lang, "鮮豔", "Vivid", "鮮やか"),
            ColorPresetId.Concert => Tr(lang, "演唱會", "Concert", "ライブ"),
            ColorPresetId.Cinema => Tr(lang, "電影院", "Cinema", "シネマ"),
            _ => id.ToString(),
        };
    }

    public static string VibranceLabel(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "鮮豔度", "Vibrance", "鮮やかさ");
    public static string MinBrightnessLabel(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "最低亮度", "Min Brightness", "最低輝度");
    public static string BrightnessLabel(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "整體亮度", "Brightness", "全体の明るさ");
    public static string WarmthLabel(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "色溫", "Color Temp", "色温度");
    public static string OffLabel(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "關", "Off", "オフ");

    public static string WarmthValue(double value, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        var amount = (int)Math.Round(Math.Abs(value) * 100);
        if (amount == 0) return Tr(lang, "中性", "Neutral", "ニュートラル");
        return value > 0 ? Tr(lang, $"暖 {amount}", $"Warm {amount}", $"暖 {amount}") : Tr(lang, $"冷 {amount}", $"Cool {amount}", $"冷 {amount}");
    }

    public static string ColorSliderHint(AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            "調整會立刻套用到手燈；點一下滑桿後可用方向鍵微調。",
            "Changes apply to the light stick immediately; click a slider and use arrow keys to fine-tune.",
            "調整は即座にペンライトへ反映されます。スライダーをクリック後、矢印キーで微調整できます。"
        );

    public static string ResetSliderAccessibility(string title, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"將{title}恢復預設值", $"Reset {title} to default", $"{title}を初期値に戻す");

    // MARK: - Motion Settings

    public static string LowLatencyTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "低延遲模式", "Low-Latency Mode", "低遅延モード");
    public static string LowLatencySubtitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "漸變最多 0.15 秒，燈光緊跟畫面", "Caps fade at 0.15 s so the light tracks tightly", "フェードを最大 0.15 秒に制限して画面に密着追従");

    public static string FadeTimeLabel(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "漸變時間", "Fade Time", "フェード時間");
    public static string FadeTimeValue(double seconds, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        if (seconds < 0.05) return Tr(lang, "立即", "Instant", "即時");
        return Tr(lang, $"{seconds:0.0} 秒", $"{seconds:0.0} s", $"{seconds:0.0} 秒");
    }

    public static string SceneCutsTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "換場快切", "Scene Cuts", "シーンカット");
    public static string SceneCutsSubtitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "畫面大幅換色時加快漸變", "Speeds up fade on large screen color jumps", "画面の大きな色変化時に素早く切り替え");

    public static string BreathingTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "呼吸律動", "Breathing", "ブリージング");
    public static string BreathingSubtitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "沒有音樂時，顏色穩定就緩慢起伏", "Gently pulses brightness when steady with no music", "音楽がなく色が安定している時にゆっくり明滅");

    public static string BeatSyncTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "跟音樂節拍", "Music Beat Sync", "音楽ビート連動");

    public static string BeatStyleName(BeatStyle style, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return style switch
        {
            BeatStyle.Auto => Tr(lang, "自動", "Auto", "自動"),
            BeatStyle.Breathe => Tr(lang, "呼吸", "Breathe", "呼吸"),
            BeatStyle.Blink => Tr(lang, "亮滅", "Blink", "点滅"),
            BeatStyle.Colors => Tr(lang, "換色", "Colors", "カラー"),
            _ => Tr(lang, "加亮", "Flash", "フラッシュ"),
        };
    }

    public static string BeatStyleSummary(BeatStyle style, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return style switch
        {
            BeatStyle.Auto => Tr(lang, "依 BPM 切換：快歌亮滅、中速換色、慢歌跟拍呼吸", "Auto by BPM: Blink for fast, Colors for mid, Breathe for slow", "BPMに応じて自動切替：速い曲は点滅、中速はカラー、遅い曲は呼吸"),
            BeatStyle.Breathe => Tr(lang, "跟著拍子緩慢起伏，每兩拍一次", "Rises and falls smoothly once every two beats", "2拍ごとにリズムに合わせてゆっくり明滅"),
            BeatStyle.Blink => Tr(lang, "拍上亮、拍間暗，像演唱會燈海", "Lit on the beat and dark between, like a concert light sea", "ビートで点灯し、ビート間は消灯（ライブのペンライト海風）"),
            BeatStyle.Colors => Tr(lang, "每拍輪流：原色、相似色、原色、對比色", "Cycles each beat: base → similar → base → opposite", "拍ごとに切替：元の色 → 類似色 → 元の色 → 補色"),
            _ => Tr(lang, "拍點瞬間變亮，拍間稍暗", "Pops to full brightness on each beat, slightly dimmer between", "ビートで明るく光り、ビート間は少し暗くなります"),
        };
    }

    public static string BeatSummarySite(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "由網站自動同步歌曲拍點與高潮閃爍", "Syncs song beats and climax flashes directly from the website", "サイトの曲のビートとサビの点滅を自動同期");

    public static string BeatSummaryOff(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "只跟畫面顏色，不聽音樂", "Follows screen color only, without listening to audio", "音声を聴かず、画面の色のみに連動");

    public static string MusicStatusSiteBpm(int bpm, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"{bpm} BPM（網站節拍）", $"{bpm} BPM (Site Beat)", $"{bpm} BPM（サイトビート）");

    public static string MusicStatusSiteWaiting(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "等待網站節拍…", "Waiting for site beat…", "サイトビート待機中…");

    public static string MusicStatusWaitingMusic(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "等待音樂…", "Waiting for music…", "音楽を待機中…");

    public static string MusicStatusDetected(int? bpm, BeatStyle? activeStyle, bool isAuto, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        var text = bpm is { } b
            ? Tr(lang, $"偵測到 {b} BPM", $"{b} BPM detected", $"{b} BPM 検出")
            : Tr(lang, "偵測到節拍", "Beat detected", "ビート検出");
        if (isAuto && activeStyle is { } picked)
        {
            text += $"・{BeatStyleName(picked, lang)}";
        }
        return text;
    }

    // MARK: - Region Settings

    public static string RegionSiteNotice(AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            "網站模式不需要框選。顏色與拍點直接來自 Ado 應援預習網站。",
            "Capture area is not needed in Website mode. Colors and beats come directly from Ado Cheer Guide.",
            "サイトモードでは範囲選択は不要です。色とビートは応援予習サイトから直接取得されます。"
        );

    public static string SelectRegionButton(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "框選範圍…", "Select Area…", "範囲を選択…");

    public static string WholeScreenButton(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "整個螢幕", "Whole Screen", "画面全体");

    public static string RegionHint(AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            "影片沒有全螢幕時，框選影片所在區域可讓顏色更準。範圍固定在螢幕上的位置，移動影片視窗後請重新框選。",
            "When the video isn't full screen, selecting its area gives more accurate colors. The area stays fixed on screen; re-select if you move the video window.",
            "動画が全画面でない場合、動画の範囲を選択すると色がより正確になります。範囲は画面上の位置に固定されるため、ウィンドウを移動したら再選択してください。"
        );

    public static string RegionWholeScreenDesc(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "目前：整個主螢幕", "Current: Whole main screen", "現在：メイン画面全体");

    public static string RegionCustomDesc(float widthPct, float heightPct, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"目前：框選範圍（寬 {widthPct:0}%、高 {heightPct:0}%）",
            $"Current: Selected area (W {widthPct:0}%, H {heightPct:0}%)",
            $"現在：選択範囲（幅 {widthPct:0}%、高さ {heightPct:0}%）"
        );

    public static string RegionOverlayHint(AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            "拖曳框選影片所在的範圍，手燈只跟這塊畫面變色。按 Esc 取消。",
            "Drag to select the video area; the light stick will follow only this region. Press Esc to cancel.",
            "ドラッグして動画の範囲を選択（この部分の色のみに連動）。Esc キーでキャンセル。"
        );

    // MARK: - General Settings & Updates

    public static string LanguageTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "語言", "Language", "言語");
    public static string LanguageSubtitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "跟隨系統語言或手動指定介面語言", "Follow system language or choose manually", "システム設定に従うか、表示言語を手動で選択");

    public static string LanguageOptionName(LanguagePreference pref, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return pref switch
        {
            LanguagePreference.Auto => Tr(lang, "自動（跟隨系統）", "Auto (System)", "自動（システム設定）"),
            LanguagePreference.ZhHant => "繁體中文",
            LanguagePreference.En => "English",
            LanguagePreference.Ja => "日本語",
            _ => "English",
        };
    }

    public static string CheckUpdatesTitle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "啟動時檢查更新", "Check for Updates on Launch", "起動時にアップデートを確認");

    public static string CurrentVersionSubtitle(string version, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"目前版本 v{version}", $"Current version v{version}", $"現在のバージョン v{version}");

    public static string UpdateDefaultNote(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "只讀取 GitHub 上的版本號，不傳送任何資料。", "Reads only the version tag from GitHub; no data is sent.", "GitHub のバージョン番号のみを取得し、データは送信しません。");

    public static string CheckNowButton(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "立即檢查", "Check Now", "今すぐ確認");
    public static string UpdateChecking(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "正在檢查…", "Checking…", "確認中…");
    public static string UpdateNewVersion(string tag, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"有新版本 {tag}", $"New version {tag} available", $"新しいバージョン {tag} があります");
    public static string UpdateLatest(string version, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"已是最新版（v{version}）", $"Up to date (v{version})", $"最新バージョンです（v{version}）");
    public static string UpdateFailed(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "無法檢查更新，請確認網路連線。", "Unable to check for updates. Please check your connection.", "アップデートを確認できません。ネットワーク接続を確認してください。");

    public static string UpdateAlertTitle(string version, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"有新版本 {version}", $"New Version {version}", $"新しいバージョン {version}");

    public static string UpdateAlertMessageWin(string currentVersion, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"目前是 v{currentVersion}。下載新版後解壓縮，取代舊的 PenlightSync.exe 即可。",
            $"You have v{currentVersion}. Download and extract the new version, then replace the old PenlightSync.exe.",
            $"現在のバージョンは v{currentVersion} です。最新版をダウンロードして展開し、古い PenlightSync.exe を置き換えてください。"
        );

    public static string UpdateDownloadButton(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "前往下載", "Download", "ダウンロード");
    public static string UpdateSkipButton(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "略過這個版本", "Skip This Version", "このバージョンをスキップ");
    public static string UpdateLaterButton(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "稍後", "Later", "あとで");

    public static string LogTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "執行記錄", "Activity Log", "実行ログ");
    public static string LogSubtitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "連線、錯誤與延遲紀錄", "Connection, error, and latency logs", "接続・エラー・遅延の履歴");
    public static string LogToggleButton(bool visible, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return visible ? Tr(lang, "隱藏記錄 ▴", "Hide Log ▴", "ログを隠す ▴") : Tr(lang, "顯示記錄 ▾", "Show Log ▾", "ログを表示 ▾");
    }

    public static string ResetTitle(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "恢復預設效果", "Restore Default Effects", "デフォルト設定に戻す");
    public static string ResetSubtitle(AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            "色彩與動態設定全部恢復預設，手燈與取色範圍不變",
            "Resets all color and motion settings; keeps light stick & capture area",
            "カラーとモーション設定を初期化します（ペンライトと範囲は維持）"
        );
    public static string ResetButton(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "全部重設", "Reset All", "すべてリセット");
    public static string ResetConfirmHeading(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "要把色彩與動態設定全部恢復預設嗎？", "Reset all color and motion settings to defaults?", "カラーとモーション設定をすべて初期状態に戻しますか？");
    public static string ResetConfirmText(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "手燈與取色範圍不會改變。", "Your selected light stick and capture area will stay.", "選択中のペンライトと取り込み範囲は変更されません。");

    // MARK: - Controller Status, Errors & Logs

    public static string StatusBtChecking(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "正在檢查藍牙…", "Checking Bluetooth…", "Bluetooth を確認中…");

    public static string StatusBtNoBle(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "這台電腦沒有可用的低功耗藍牙（BLE）。", "No Bluetooth Low Energy (BLE) adapter available.", "この PC では Bluetooth Low Energy（BLE）を利用できません。");

    public static string StatusBtOffWin(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "藍牙已關閉。請在 Windows 設定開啟藍牙後重新開啟本程式。", "Bluetooth is turned off. Turn on Bluetooth in Windows Settings and reopen this app.", "Bluetooth がオフです。Windows の設定で Bluetooth をオンにしてからアプリを再起動してください。");

    public static string StatusBtReady(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "藍牙就緒。按「掃描」尋找手燈。", "Bluetooth ready. Click \"Scan\" to find your light stick.", "Bluetooth 準備完了。「スキャン」でペンライトを探してください。");

    public static string StatusBtError(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"無法使用藍牙：{detail}", $"Bluetooth unavailable: {detail}", $"Bluetooth を利用できません：{detail}");

    public static string ErrScanStopped(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"掃描停止：{detail}", $"Scan stopped: {detail}", $"スキャン停止：{detail}");

    public static string StatusScanning(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "掃描中：請讓手燈進入配對模式（長按背面按鈕至藍燈閃爍）。", "Scanning: Put your light stick in pairing mode (hold the back button until blue blinks).", "スキャン中：ペンライトをペアリングモード（背面ボタン長押しで青点滅）にしてください。");

    public static string StatusScanNone(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "沒有找到手燈。確認手燈在配對模式，且手機 App 已關閉。", "No light stick found. Make sure it's in pairing mode and the phone app is closed.", "見つかりませんでした。ペアリングモード中かつスマホアプリが終了しているか確認してください。");

    public static string StatusScanFound(int count, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"找到 {count} 支手燈，選擇後按「開始連動」。", $"Found {count} light stick(s). Select one and click \"Start Sync\".", $"{count} 本のペンライトが見つかりました。選択して「連動開始」を押してください。");

    public static string StatusConnecting(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "連線中…", "Connecting…", "接続中…");

    public static string ErrConnectTimeout(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "連線逾時。請讓手燈重新進入配對模式後再試。", "Connection timed out. Put the light stick in pairing mode and try again.", "接続がタイムアウトしました。ペアリングモードにして再度お試しください。");

    public static string ErrFailedToConnect(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"無法連線：{detail}", $"Could not connect: {detail}", $"接続できません：{detail}");

    public static string ErrSelectedLampNotFound(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "找不到選擇的手燈。請讓手燈進入配對模式後重新掃描。", "Selected light stick not found. Put it in pairing mode and scan again.", "選択したペンライトが見つかりません。ペアリングモードにして再スキャンしてください。");

    public static string ErrWrongDeviceName(string expected, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"選擇的裝置名稱不是 {expected}，已拒絕連線。", $"Device name is not {expected}; connection refused.", $"選択したデバイス名が {expected} ではないため接続を拒否しました。");

    public static string ErrServiceDiscoveryFailed(string status, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"連線失敗或手燈沒有控制服務 0000（{status}）。請讓手燈重新進入配對模式後再試。", $"Connection failed or control service 0000 missing ({status}). Put the lamp in pairing mode and retry.", $"接続に失敗したか制御サービス 0000 が見つかりません（{status}）。ペアリングモードにして再試行してください。");

    public static string ErrCharNoWrite(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "手燈的控制特徵 0000 不支援有回應寫入。", "Control characteristic 0000 does not support write-with-response.", "制御キャラクタリスティック 0000 が応答付き書き込みに対応していません。");

    public static string ErrSyncLoop(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"連動錯誤：{detail}", $"Sync error: {detail}", $"連動エラー：{detail}");

    public static string ErrScreenTimeout(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "螢幕取樣超過 8 秒沒有完成，已停止連動。", "Screen sampling timed out after 8 seconds; sync stopped.", "画面サンプリングが 8 秒以内に完了しなかったため連動を停止しました。");

    public static string ErrScreenFailed(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"螢幕取樣失敗：{detail}", $"Screen sampling failed: {detail}", $"画面サンプリング失敗：{detail}");

    public static string ErrNoPrimaryScreen(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "找不到主螢幕。", "Primary screen not found.", "メイン画面が見つかりません。");

    public static string ErrCannotReadScreen(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "無法讀取螢幕畫面。", "Could not read screen image.", "画面を読み取れませんでした。");

    public static string ErrUnsupportedAudioFormat(string format, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"不支援的音訊格式：{format}", $"Unsupported audio format: {format}", $"未対応のオーディオ形式：{format}");

    public static string ReasonWriteTimeout(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "藍牙寫入超過 8 秒沒有回應", "Bluetooth write timed out after 8 seconds", "Bluetooth 書き込みが 8 秒以上応答なし");

    public static string ReasonWriteFailed(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"藍牙寫入失敗（{detail}）", $"Bluetooth write failed ({detail})", $"Bluetooth 書き込み失敗（{detail}）");

    public static string ReasonDisconnected(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "手燈連線中斷", "Light stick disconnected", "ペンライトが切断されました");

    public static string StatusReconnecting(string reason, int windowSeconds, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"{reason}，正在自動重新連線（最多 {windowSeconds} 秒）…若一直連不上，請長按手燈背面按鈕進入配對模式。",
            $"{reason}. Reconnecting automatically (up to {windowSeconds}s)… If it fails, hold the lamp's back button for pairing mode.",
            $"{reason}。自動再接続中（最大 {windowSeconds} 秒）…繋がらない場合は背面ボタンを長押ししてペアリングモードにしてください。"
        );

    public static string ErrReconnectTimedOut(string reason, int windowSeconds, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"{reason}，{windowSeconds} 秒內無法重新連上手燈。請讓手燈重新進入配對模式後再按「開始連動」。",
            $"{reason}. Could not reconnect within {windowSeconds}s. Put the lamp in pairing mode and click \"Start Sync\".",
            $"{reason}。{windowSeconds} 秒以内に再接続できませんでした。ペアリングモードにして再度「連動開始」を押してください。"
        );

    public static string StatusStopping(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "停止中…", "Stopping…", "停止中…");
    public static string StatusStoppedError(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "連動已因錯誤停止。", "Sync stopped due to an error.", "エラーにより連動を停止しました。");
    public static string StatusStoppedUser(AppLanguage? l = null) => Tr(l ?? CurrentLanguage, "已停止連動。", "Sync stopped.", "連動を停止しました。");

    public static string StatusSyncingSitePortInUse(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "連動中：網站模式（連接埠 51730 被佔用，無法接收網站資料）。", "Syncing: Website mode (port 51730 is in use; cannot receive data).", "連動中：サイトモード（ポート 51730 が使用中のためデータを受信できません）。");

    public static string StatusSyncingSite(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "連動中：跟隨 Ado 應援預習網站。", "Syncing: Following Ado Cheer Guide website.", "連動中：Ado 応援予習サイトに追従中。");

    public static string StatusSyncingScreen(bool hasRegion, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        return hasRegion
            ? Tr(lang, "連動中：跟隨框選範圍的平均色。", "Syncing: Following selected area average color.", "連動中：選択範囲の平均色に追従中。")
            : Tr(lang, "連動中：跟隨主螢幕平均色。", "Syncing: Following main screen average color.", "連動中：メイン画面全体の平均色に追従中。");
    }

    public static string ErrAudioFailed(string detail, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"無法聆聽系統聲音，節拍閃動已暫停：{detail}",
            $"Could not capture system audio; beat sync paused: {detail}",
            $"システム音声を取得できないためビート連動を一時停止：{detail}"
        );

    public static string LatencySummary(
        int intervalSeconds,
        (double Average, double Maximum)? capture,
        (double Average, double Maximum)? bluetooth,
        AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        string Desc((double Average, double Maximum)? stats) => stats is { } s
            ? Tr(lang, $"{s.Average:0} ms（最高 {s.Maximum:0}）", $"{s.Average:0} ms (max {s.Maximum:0})", $"{s.Average:0} ms（最大 {s.Maximum:0}）")
            : "—";
        return Tr(
            lang,
            $"延遲（近 {intervalSeconds} 秒平均）：畫面擷取 {Desc(capture)}・藍牙來回 {Desc(bluetooth)}",
            $"Latency ({intervalSeconds}s avg): Capture {Desc(capture)} · BLE RTT {Desc(bluetooth)}",
            $"遅延（直近 {intervalSeconds} 秒平均）：画面取得 {Desc(capture)}・BLE往復 {Desc(bluetooth)}"
        );
    }

    // MARK: - Log entries

    public static string LogPortInUse(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "錯誤：網站連動用的連接埠 51730 被別的程式佔用。", "Error: Port 51730 for Website mode is in use.", "エラー：サイト連動用ポート 51730 が使用中です。");

    public static string LogSourceSwitched(ColorSource source, AppLanguage? l = null)
    {
        var lang = l ?? CurrentLanguage;
        var name = ColorSourceName(source, lang);
        return Tr(lang, $"取色來源切換為：{name}。", $"Color source switched to: {name}.", $"カラーソースを「{name}」に切り替えました。");
    }

    public static string LogRegionCustom(float widthPct, float heightPct, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"取色範圍改為框選區域（寬 {widthPct:0}%、高 {heightPct:0}%）。",
            $"Capture area set to selected region (W {widthPct:0}%, H {heightPct:0}%).",
            $"取り込み範囲を選択範囲に変更（幅 {widthPct:0}%、高さ {heightPct:0}%）。"
        );

    public static string LogRegionWholeScreen(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "取色範圍改回整個主螢幕。", "Capture area reset to whole main screen.", "取り込み範囲をメイン画面全体に戻しました。");

    public static string LogAudioStarted(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "開始聆聽系統聲音（節拍）。", "Beat detection: listening to system audio.", "ビート検出：システム音声の解析を開始しました。");

    public static string LogAudioFailed(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"音訊錯誤：{detail}", $"Audio error: {detail}", $"オーディオエラー：{detail}");

    public static string LogScanStart(string targetName, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"開始掃描 {targetName}。", $"Scanning for {targetName}…", $"{targetName} のスキャンを開始しました。");

    public static string LogLampFound(string address, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"找到手燈 {address}。", $"Found light stick {address}.", $"ペンライトを検出：{address}。");

    public static string LogConnecting(string targetName, string address, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"連線 {targetName}（{address}）。", $"Connecting to {targetName} ({address}).", $"{targetName}（{address}）に接続中。");

    public static string LogConnectedDiscovering(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "已連線，探索控制特徵 0000。", "Connected; discovering control characteristic 0000.", "接続完了、制御キャラクタリスティック 0000 を検索中。");

    public static string LogSyncStarted(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "連動開始。", "Sync started.", "連動を開始しました。");

    public static string LogFastConnAccepted(double intervalMs, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"已要求較短的藍牙連線間隔（Windows 11；目前 {intervalMs:0.#} ms）。",
            $"Requested shorter BLE connection interval (Windows 11; current {intervalMs:0.#} ms).",
            $"より短い BLE 接続間隔を要求しました（Windows 11；現在 {intervalMs:0.#} ms）。"
        );

    public static string LogFastConnRejected(string status, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"系統未接受較短的藍牙連線間隔（{status}）。",
            $"System declined shorter BLE connection interval ({status}).",
            $"システムが短い BLE 接続間隔を承認しませんでした（{status}）。"
        );

    public static string LogFastConnFailed(string detail, AppLanguage? l = null) =>
        Tr(
            l ?? CurrentLanguage,
            $"無法調整藍牙連線間隔：{detail}",
            $"Could not adjust BLE connection interval: {detail}",
            $"BLE 接続間隔を調整できませんでした：{detail}"
        );

    public static string LogReconnecting(string reason, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"{reason}，自動重新連線中。", $"{reason}; reconnecting automatically.", $"{reason}。自動再接続中。");

    public static string LogReconnected(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "已自動重新連線，繼續連動。", "Reconnected automatically; resuming sync.", "自動再接続に成功し、連動を再開しました。");

    public static string LogReconnectFailed(string detail, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"重新連線失敗：{detail}", $"Reconnect failed: {detail}", $"再接続失敗：{detail}");

    public static string LogErrorPrefix(string message, AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, $"錯誤：{message}", $"Error: {message}", $"エラー：{message}");

    public static string LogStoppedByUser(AppLanguage? l = null) =>
        Tr(l ?? CurrentLanguage, "使用者停止連動。", "Sync stopped by user.", "ユーザー操作により連動を停止しました。");
}
