import AppKit
import SwiftUI

@main
struct PenlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PenlightController()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var i18n = LocalizationManager.shared

    var body: some Scene {
        Window(L10n.appTitle(i18n.resolved), id: "main") {
            ContentView(controller: controller, updates: updates, i18n: i18n)
                .frame(width: 480, height: 800)
                .onChange(of: i18n.resolved) { _, newLang in
                    NSApp.windows.forEach { $0.title = L10n.appTitle(newLang) }
                }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Colors that follow the system light/dark appearance; the dark set matches the app icon.
enum Theme {
    static let background = dynamic(light: 0xF3F4FA, dark: 0x0E1224)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x161B33)
    static let field = dynamic(light: 0xEEF0F8, dark: 0x0F1430)
    static let border = dynamic(light: 0xDFE2EF, dark: 0x262D52)
    static let secondaryText = dynamic(light: 0x5B6080, dark: 0x9AA3C7)
    static let accent = dynamic(light: 0x4F55E0, dark: 0x7C83FF)
    static let success = dynamic(light: 0x1E7F4A, dark: 0x5EE09A)
    static let warning = dynamic(light: 0x9A5B00, dark: 0xF5B94C)
    static let danger = dynamic(light: 0xC62F45, dark: 0xFF8FA3)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct ContentView: View {
    @ObservedObject var controller: PenlightController
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var i18n: LocalizationManager
    @State private var tab = SettingsTab.color

    private var lang: AppLanguage { i18n.resolved }

    var body: some View {
        VStack(spacing: 12) {
            LiveCard(controller: controller, lang: lang)

            if let errorText = controller.errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Label(errorText.resolve(lang), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.needsScreenPermission {
                        Button(L10n.openScreenPermissionSettings(lang)) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 14) {
                Picker(L10n.settingsTabsAccessibility(lang), selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text(L10n.tabName($0, lang)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    Group {
                        switch tab {
                        case .color: ColorSettings(controller: controller, lang: lang)
                        case .motion: MotionSettings(controller: controller, lang: lang)
                        case .region: RegionSettings(controller: controller, lang: lang)
                        case .general: GeneralSettings(controller: controller, updates: updates, i18n: i18n)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
            .card(fillHeight: true)

            Text(L10n.footerNotice(lang))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .tint(Theme.accent)
        .task { await updates.checkOnLaunchIfEnabled() }
        .alert(L10n.updateAlertTitle(updates.offered?.version ?? "", lang),
               isPresented: Binding(get: { updates.offered != nil }, set: { if !$0 { updates.offered = nil } }),
               presenting: updates.offered) { release in
            Button(L10n.updateDownloadButton(lang)) { NSWorkspace.shared.open(UpdateChecker.downloadPage) }
            Button(L10n.updateSkipButton(lang)) { updates.skip(release) }
            Button(L10n.updateLaterButton(lang), role: .cancel) {}
        } message: { _ in
            Text(L10n.updateAlertMessage(updates.currentVersion, lang))
        }
    }
}

// MARK: - Live status, colors and connection

private struct LiveCard: View {
    @ObservedObject var controller: PenlightController
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(phase: controller.phase, failed: controller.errorText != nil, lang: lang)
                Spacer()
                if let latencyText = controller.latencyText {
                    Text(latencyText.resolve(lang))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(controller.statusText.resolve(lang))
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if controller.colorSource == .site {
                    let sub = L10n.siteSongCaption(title: controller.siteSongTitle, state: controller.sitePlayingState, lang)
                    Button {
                        controller.openAdoGuideSite()
                    } label: {
                        ColorTile(title: L10n.siteColorTile(lang), subtitle: sub, color: controller.screenColor, glows: false, hasLink: true)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.siteColorTooltip(lang))
                } else {
                    ColorTile(title: L10n.screenTile(lang), color: controller.screenColor, glows: false)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                ColorTile(title: L10n.lampTile(lang), color: controller.lampColor, glows: true)
            }

            HStack(spacing: 8) {
                if controller.lamps.isEmpty {
                    Label(L10n.noLampFoundHint(lang), systemImage: "light.cylindrical.ceiling")
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Picker(L10n.lampTile(lang), selection: $controller.selectedLampID) {
                        ForEach(controller.lamps) { lamp in
                            Text(lampLabel(lamp)).tag(Optional(lamp.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .disabled(controller.phase != .idle)
                }
                Button {
                    controller.isScanning ? controller.stopScan() : controller.startScan()
                } label: {
                    HStack(spacing: 6) {
                        if controller.isScanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(L10n.scanButton(isScanning: controller.isScanning, lang))
                    }
                }
                .disabled(!controller.bluetoothReady || controller.phase != .idle)
            }

            Group {
                if controller.phase == .idle {
                    Button { controller.start() } label: {
                        Label(L10n.startSync(lang), systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canStart)
                } else {
                    Button(role: .destructive) { controller.stop() } label: {
                        Label(L10n.stopSync(lang), systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.danger)
                    .disabled(controller.phase == .stopping)
                }
            }
            .controlSize(.large)
        }
        .card()
    }

    private func lampLabel(_ lamp: DiscoveredLamp) -> String {
        let detail = lamp.rssi.map { "\($0) dBm" } ?? (lamp.remembered ? L10n.lampLastUsed(lang) : "")
        return "Ado Light Stick · \(lamp.id.uuidString.prefix(8))" + (detail.isEmpty ? "" : " · \(detail)")
    }
}

private struct StatusPill: View {
    let phase: PenlightController.Phase
    let failed: Bool
    let lang: AppLanguage

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(L10n.statusPill(phase, failed: failed, lang)).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch phase {
        case .syncing: return Theme.success
        case .connecting, .reconnecting, .stopping: return Theme.warning
        case .idle: return failed ? Theme.danger : Theme.secondaryText
        }
    }
}

private struct ColorTile: View {
    let title: String
    var subtitle: String? = nil
    let color: ScreenRGB?
    let glows: Bool
    var hasLink: Bool = false

    var body: some View {
        let fill = color.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) }
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fill ?? Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                .frame(height: 84)
                .shadow(color: glows ? (fill ?? .clear).opacity(0.55) : .clear, radius: 14)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title).font(.subheadline.weight(.medium))
                        if hasLink {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(color?.description ?? "—")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings tabs

private struct ColorSettings: View {
    @ObservedObject var controller: PenlightController
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.colorSourceHeading(lang)).font(.caption).foregroundStyle(Theme.secondaryText)
                Picker(L10n.colorSourceHeading(lang), selection: $controller.colorSource) {
                    ForEach(ColorSource.allCases) { source in
                        Text(L10n.colorSourceName(source, lang)).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if controller.colorSource == .site {
                    HStack {
                        Button {
                            controller.openAdoGuideSite()
                        } label: {
                            Label(
                                L10n.openSiteButton(songTitle: controller.siteSongTitle, lang),
                                systemImage: "safari"
                            )
                        }
                        .buttonStyle(.link)
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(Theme.secondaryText)
                            .font(.caption2)
                    }
                    .padding(.top, 2)
                }
            }
            Divider()

            Text(L10n.stylePresetsHeading(lang)).font(.caption).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 6) {
                ForEach(ColorPreset.all) { preset in
                    PresetChip(name: L10n.presetName(preset, lang), selected: controller.activePreset == preset) { controller.apply(preset) }
                }
            }
            ParamSlider(title: L10n.vibranceLabel(lang), value: $controller.vibrance, range: 0...1, step: 0.05,
                        defaultValue: ColorPreset.standard.vibrance, lang: lang) { percent($0) }
            ParamSlider(title: L10n.minBrightnessLabel(lang), value: $controller.minBrightness, range: 0...0.5, step: 0.05,
                        defaultValue: ColorPreset.standard.minBrightness, lang: lang) { $0 < 0.001 ? L10n.offLabel(lang) : percent($0) }
            ParamSlider(title: L10n.brightnessLabel(lang), value: $controller.brightness, range: 0.1...1, step: 0.05,
                        defaultValue: ColorPreset.standard.brightness, lang: lang) { percent($0) }
            ParamSlider(title: L10n.warmthLabel(lang), value: $controller.warmth, range: -0.5...0.5, step: 0.05,
                        defaultValue: ColorPreset.standard.warmth, lang: lang) { L10n.warmthValue($0, lang) }
            Text(L10n.colorSliderHint(lang))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

private struct MotionSettings: View {
    @ObservedObject var controller: PenlightController
    let lang: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(title: L10n.lowLatencyTitle(lang), subtitle: L10n.lowLatencySubtitle(lang), isOn: $controller.lowLatency)
            ParamSlider(title: L10n.fadeTimeLabel(lang), value: $controller.fadeTime, range: 0...2, step: 0.1, defaultValue: 0.6, lang: lang) {
                L10n.fadeTimeValue($0, lang)
            }
            .disabled(controller.lowLatency)
            Divider()
            ToggleRow(title: L10n.sceneCutsTitle(lang), subtitle: L10n.sceneCutsSubtitle(lang), isOn: $controller.sceneCuts)
            ToggleRow(title: L10n.breathingTitle(lang), subtitle: L10n.breathingSubtitle(lang), isOn: $controller.breathing)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.beatSyncTitle(lang))
                    Spacer()
                    Text(musicStatus)
                        .font(.caption)
                        .foregroundStyle(((controller.colorSource == .site ? (controller.bpm ?? 0) > 0 : controller.musicDetected) ? Theme.success : Theme.secondaryText))
                }
                HStack(spacing: 6) {
                    PresetChip(name: L10n.offLabel(lang), selected: !controller.beatSync) { controller.beatSync = false }
                    ForEach(BeatStyle.choices) { style in
                        PresetChip(name: L10n.beatStyleName(style, lang), selected: controller.beatSync && controller.beatStyle == style) {
                            controller.beatStyle = style
                            controller.beatSync = true
                        }
                    }
                }
                Text(controller.colorSource == .site
                     ? L10n.beatSummarySite(lang)
                     : (controller.beatSync ? L10n.beatStyleSummary(controller.beatStyle, lang) : L10n.beatSummaryOff(lang)))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// Detected tempo, plus the style auto picked for it.
    private var musicStatus: String {
        if controller.colorSource == .site {
            if let bpm = controller.bpm, bpm > 0 {
                return L10n.musicStatusSiteBpm(bpm, lang)
            }
            return L10n.musicStatusSiteWaiting(lang)
        }
        guard controller.beatSync else { return "" }
        guard controller.musicDetected else { return L10n.musicStatusWaitingMusic(lang) }
        return L10n.musicStatusDetected(bpm: controller.bpm, activeStyle: controller.activeBeatStyle, isAuto: controller.beatStyle == .auto, lang)
    }
}

private struct RegionSettings: View {
    @ObservedObject var controller: PenlightController
    let lang: AppLanguage

    var body: some View {
        if controller.colorSource == .site {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.regionSiteNotice(lang), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    controller.openAdoGuideSite()
                } label: {
                    Label(
                        L10n.openSiteButton(songTitle: controller.siteSongTitle, lang),
                        systemImage: "arrow.up.forward.app"
                    )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                RegionPreview(region: controller.captureRegion)
                Text(regionDescription)
                HStack {
                    Button(L10n.selectRegionButton(lang)) { controller.selectRegion() }
                    if controller.captureRegion != nil {
                        Button(L10n.wholeScreenButton(lang)) { controller.useWholeScreen() }
                    }
                }
                Text(L10n.regionHint(lang))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var regionDescription: String {
        guard let region = controller.captureRegion else { return L10n.regionWholeScreenDesc(lang) }
        return L10n.regionCustomDesc(widthPct: region.width * 100, heightPct: region.height * 100, lang)
    }
}

private struct RegionPreview: View {
    let region: CGRect?

    var body: some View {
        let aspect = NSScreen.main.map { $0.frame.width / max(1, $0.frame.height) } ?? 16 / 10
        let area = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .overlay(
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.accent.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                        .frame(width: geometry.size.width * area.width, height: geometry.size.height * area.height)
                        .offset(x: geometry.size.width * area.minX, y: geometry.size.height * area.minY)
                }
                .padding(6)
            )
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 130)
            .accessibilityHidden(true)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var controller: PenlightController
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var i18n: LocalizationManager
    @State private var showLog = false
    @State private var confirmReset = false

    private var lang: AppLanguage { i18n.resolved }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.languageTitle(lang))
                    Text(L10n.languageSubtitle(lang))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Picker(L10n.languageTitle(lang), selection: $i18n.preference) {
                    ForEach(LanguagePreference.allCases) { pref in
                        Text(L10n.languageOptionName(pref, lang)).tag(pref)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 156)
            }
            Divider()
            ToggleRow(title: L10n.checkUpdatesTitle(lang), subtitle: L10n.currentVersionSubtitle(updates.currentVersion, lang), isOn: $updates.checkOnLaunch)
            HStack {
                Text(updateNoteText)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button(L10n.checkNowButton(lang)) { Task { await updates.check(manual: true) } }
                    .disabled(updates.isChecking)
            }
            Divider()
            DisclosureGroup(L10n.logTitle(lang), isExpanded: $showLog) {
                ScrollView {
                    Text(controller.logLines.isEmpty ? L10n.logEmpty(lang) : controller.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 140)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 6)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.resetTitle(lang))
                    Text(L10n.resetSubtitle(lang))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button(L10n.resetButton(lang), role: .destructive) { confirmReset = true }
            }
            .confirmationDialog(L10n.resetConfirmTitle(lang), isPresented: $confirmReset) {
                Button(L10n.resetButton(lang), role: .destructive) { controller.resetEffects() }
            }
        }
    }

    private var updateNoteText: String {
        switch updates.noteState {
        case .none: return L10n.updateDefaultNote(lang)
        case .checking: return L10n.updateChecking(lang)
        case .newVersion(let tag): return L10n.updateNewVersion(tag, lang)
        case .upToDate(let version): return L10n.updateLatest(version, lang)
        case .failed: return L10n.updateFailed(lang)
        }
    }
}

// MARK: - Building blocks

private struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let lang: AppLanguage
    let format: (Double) -> String

    var body: some View {
        let isDefault = abs(value - defaultValue) < step / 2
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            // Snapping in the binding instead of `step:` avoids the stepped slider's crowded tick marks.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            Text(format(value))
                .monospacedDigit()
                .frame(width: 68, alignment: .trailing)
                .lineLimit(1)
            Button { value = defaultValue } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.resetSliderTooltip(lang))
            .accessibilityLabel(L10n.resetSliderAccessibility(title, lang))
            .opacity(isDefault ? 0 : 1)
            .disabled(isDefault)
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    var subtitleColor = Theme.secondaryText
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(subtitleColor)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

private struct PresetChip: View {
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Theme.accent : Theme.field, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CardStyle: ViewModifier {
    let fillHeight: Bool

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

private extension View {
    func card(fillHeight: Bool = false) -> some View { modifier(CardStyle(fillHeight: fillHeight)) }
}
