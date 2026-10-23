import AppKit
import SwiftUI

@main
struct PenlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = PenlightController()
    @StateObject private var updates = UpdateChecker()

    var body: some Scene {
        Window("Ado 手燈連動", id: "main") {
            ContentView(controller: controller, updates: updates)
                .frame(width: 440, height: 770)
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

enum SettingsTab: String, CaseIterable, Identifiable {
    case color = "色彩"
    case motion = "動態"
    case region = "取色範圍"
    case general = "一般"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var controller: PenlightController
    @ObservedObject var updates: UpdateChecker
    @State private var tab = SettingsTab.color

    var body: some View {
        VStack(spacing: 12) {
            LiveCard(controller: controller)

            if let error = controller.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.needsScreenPermission {
                        Button("開啟螢幕錄製設定") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 14) {
                Picker("設定分頁", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    Group {
                        switch tab {
                        case .color: ColorSettings(controller: controller)
                        case .motion: MotionSettings(controller: controller)
                        case .region: RegionSettings(controller: controller)
                        case .general: GeneralSettings(controller: controller, updates: updates)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
            .card(fillHeight: true)

            Text("自動略過黑邊與字幕；畫面與聲音都不儲存或上傳。")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .tint(Theme.accent)
        .task { await updates.checkOnLaunchIfEnabled() }
        .alert("有新版本 \(updates.offered?.version ?? "")",
               isPresented: Binding(get: { updates.offered != nil }, set: { if !$0 { updates.offered = nil } }),
               presenting: updates.offered) { release in
            Button("前往下載") { NSWorkspace.shared.open(UpdateChecker.downloadPage) }
            Button("略過這個版本") { updates.skip(release) }
            Button("稍後", role: .cancel) {}
        } message: { _ in
            Text("目前是 v\(updates.currentVersion)。下載新版後取代舊的 app 即可；更新後需要重新允許藍牙與螢幕錄製權限。")
        }
    }
}

// MARK: - Live status, colors and connection

private struct LiveCard: View {
    @ObservedObject var controller: PenlightController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatusPill(phase: controller.phase, failed: controller.errorMessage != nil)
                Spacer()
                if let latency = controller.latencySummary {
                    Text(latency)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text(controller.status)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ColorTile(title: "螢幕", color: controller.screenColor, glows: false)
                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                ColorTile(title: "手燈", color: controller.lampColor, glows: true)
            }

            HStack(spacing: 8) {
                if controller.lamps.isEmpty {
                    Label("尚未找到手燈，請按「掃描」", systemImage: "light.cylindrical.ceiling")
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Picker("手燈", selection: $controller.selectedLampID) {
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
                        Text(controller.isScanning ? "停止" : "掃描")
                    }
                }
                .disabled(!controller.bluetoothReady || controller.phase != .idle)
            }

            Group {
                if controller.phase == .idle {
                    Button { controller.start() } label: {
                        Label("開始連動", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canStart)
                } else {
                    Button(role: .destructive) { controller.stop() } label: {
                        Label("停止連動", systemImage: "stop.fill").frame(maxWidth: .infinity)
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
        let detail = lamp.rssi.map { "\($0) dBm" } ?? (lamp.remembered ? "上次使用" : "")
        return "Ado Light Stick · \(lamp.id.uuidString.prefix(8))" + (detail.isEmpty ? "" : " · \(detail)")
    }
}

private struct StatusPill: View {
    let phase: PenlightController.Phase
    let failed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var title: String {
        switch phase {
        case .idle: return failed ? "已停止" : "待機"
        case .connecting: return "連線中"
        case .syncing: return "連動中"
        case .reconnecting: return "重新連線中"
        case .stopping: return "停止中"
        }
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
    let color: ScreenRGB?
    let glows: Bool

    var body: some View {
        let fill = color.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) }
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fill ?? Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                .frame(height: 84)
                .shadow(color: glows ? (fill ?? .clear).opacity(0.55) : .clear, radius: 14)
            HStack {
                Text(title).font(.subheadline.weight(.medium))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("風格預設").font(.caption).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 6) {
                ForEach(ColorPreset.all) { preset in
                    PresetChip(name: preset.name, selected: controller.activePreset == preset) { controller.apply(preset) }
                }
            }
            ParamSlider(title: "鮮豔度", value: $controller.vibrance, range: 0...1, step: 0.05,
                        defaultValue: ColorPreset.standard.vibrance) { percent($0) }
            ParamSlider(title: "最低亮度", value: $controller.minBrightness, range: 0...0.5, step: 0.05,
                        defaultValue: ColorPreset.standard.minBrightness) { $0 < 0.001 ? "關" : percent($0) }
            ParamSlider(title: "整體亮度", value: $controller.brightness, range: 0.1...1, step: 0.05,
                        defaultValue: ColorPreset.standard.brightness) { percent($0) }
            ParamSlider(title: "色溫", value: $controller.warmth, range: -0.5...0.5, step: 0.05,
                        defaultValue: ColorPreset.standard.warmth) { warmthText($0) }
            Text("調整會立刻套用到手燈；左右箭頭可微調選取的滑桿。")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func warmthText(_ value: Double) -> String {
        let amount = Int((abs(value) * 100).rounded())
        return amount == 0 ? "中性" : (value > 0 ? "暖 \(amount)" : "冷 \(amount)")
    }
}

private struct MotionSettings: View {
    @ObservedObject var controller: PenlightController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(title: "低延遲模式", subtitle: "漸變最多 0.15 秒，燈光緊跟畫面", isOn: $controller.lowLatency)
            ParamSlider(title: "漸變時間", value: $controller.fadeTime, range: 0...2, step: 0.1, defaultValue: 0.6) {
                $0 < 0.05 ? "立即" : String(format: "%.1f 秒", $0)
            }
            .disabled(controller.lowLatency)
            Divider()
            ToggleRow(title: "換場快切", subtitle: "畫面大幅換色時加快漸變", isOn: $controller.sceneCuts)
            ToggleRow(title: "呼吸律動", subtitle: "顏色穩定時亮度緩慢起伏", isOn: $controller.breathing)
            ToggleRow(title: "跟音樂節拍閃動",
                      subtitle: controller.musicDetected ? (controller.bpm.map { "偵測到 \($0) BPM" } ?? "偵測到節拍") : "依 BPM 調整快慢",
                      subtitleColor: controller.musicDetected ? Theme.success : Theme.secondaryText,
                      isOn: $controller.beatSync)
        }
    }
}

private struct RegionSettings: View {
    @ObservedObject var controller: PenlightController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RegionPreview(region: controller.captureRegion)
            Text(regionDescription)
            HStack {
                Button("框選範圍…") { controller.selectRegion() }
                if controller.captureRegion != nil {
                    Button("整個螢幕") { controller.useWholeScreen() }
                }
            }
            Text("影片沒有全螢幕時，框選影片所在區域可讓顏色更準。範圍固定在螢幕上的位置，移動影片視窗後請重新框選。")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var regionDescription: String {
        guard let region = controller.captureRegion else { return "目前：整個主螢幕" }
        return String(format: "目前：框選範圍（寬 %.0f%%、高 %.0f%%）", region.width * 100, region.height * 100)
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
    @State private var showLog = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(title: "啟動時檢查更新", subtitle: "目前版本 v\(updates.currentVersion)", isOn: $updates.checkOnLaunch)
            HStack {
                Text(updates.note ?? "只讀取 GitHub 上的版本號，不傳送任何資料。")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("立即檢查") { Task { await updates.check(manual: true) } }
                    .disabled(updates.isChecking)
            }
            Divider()
            DisclosureGroup("執行記錄", isExpanded: $showLog) {
                ScrollView {
                    Text(controller.logLines.isEmpty ? "尚無記錄。" : controller.logLines.joined(separator: "\n"))
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
                    Text("恢復預設效果")
                    Text("色彩與動態設定全部恢復預設，手燈與取色範圍不變")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("全部重設", role: .destructive) { confirmReset = true }
            }
            .confirmationDialog("要把色彩與動態設定全部恢復預設嗎？", isPresented: $confirmReset) {
                Button("全部重設", role: .destructive) { controller.resetEffects() }
            }
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
    let format: (Double) -> String

    var body: some View {
        let isDefault = abs(value - defaultValue) < step / 2
        HStack(spacing: 10) {
            Text(title).frame(width: 64, alignment: .leading)
            // Snapping in the binding instead of `step:` avoids the stepped slider's crowded tick marks.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            Text(format(value))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Button { value = defaultValue } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("恢復預設值")
            .accessibilityLabel("將\(title)恢復預設值")
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
