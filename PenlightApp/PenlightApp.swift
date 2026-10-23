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
                .frame(width: 420, height: 910)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @ObservedObject var controller: PenlightController
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Swatch(title: "螢幕平均色", color: controller.screenColor)
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Swatch(title: "手燈", color: controller.lampColor)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 10, height: 10)
                    Text(controller.status)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let latency = controller.latencySummary {
                    Text(latency)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if controller.lamps.isEmpty {
                        Text("尚未找到手燈。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        List(controller.lamps, selection: $controller.selectedLampID) { lamp in
                            LampRow(lamp: lamp)
                        }
                        .listStyle(.bordered)
                        .frame(height: 96)
                        .disabled(controller.phase != .idle)
                    }
                    HStack {
                        Button(controller.isScanning ? "停止掃描" : "掃描手燈") {
                            controller.isScanning ? controller.stopScan() : controller.startScan()
                        }
                        .disabled(!controller.bluetoothReady || controller.phase != .idle)
                        if controller.isScanning { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                }
            } label: {
                Text("手燈")
            }

            GroupBox {
                HStack {
                    Text(regionDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if controller.captureRegion != nil {
                        Button("整個螢幕") { controller.useWholeScreen() }
                    }
                    Button("框選範圍…") { controller.selectRegion() }
                }
            } label: {
                Text("取色範圍")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("低延遲模式（漸變最多 0.15 秒，燈光緊跟畫面）", isOn: $controller.lowLatency)
                    SliderRow(title: "鮮豔度", value: $controller.vibrance, range: 0...1, step: 0.05) {
                        String(format: "%.0f%%", $0 * 100)
                    }
                    SliderRow(title: "最低亮度", value: $controller.minBrightness, range: 0...0.5, step: 0.05) {
                        $0 == 0 ? "關" : String(format: "%.0f%%", $0 * 100)
                    }
                    SliderRow(title: "漸變時間", value: $controller.fadeTime, range: 0...2, step: 0.1) {
                        $0 == 0 ? "立即" : String(format: "%.1f 秒", $0)
                    }
                    .disabled(controller.lowLatency)
                    Toggle("換場快切（畫面大幅換色時加快漸變）", isOn: $controller.sceneCuts)
                    Toggle("呼吸律動（畫面顏色穩定時，亮度緩慢起伏）", isOn: $controller.breathing)
                    HStack {
                        Toggle("跟音樂節拍閃動（依 BPM 調整快慢）", isOn: $controller.beatSync)
                        Spacer()
                        if controller.musicDetected {
                            Label(controller.bpm.map { "\($0) BPM" } ?? "偵測到節拍", systemImage: "music.note")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }
            } label: {
                Text("燈光效果")
            }

            Group {
                if controller.phase == .idle {
                    Button { controller.start() } label: {
                        Label("開始連動", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canStart)
                } else {
                    Button(role: .destructive) { controller.stop() } label: {
                        Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .disabled(controller.phase == .stopping)
                }
            }
            .controlSize(.large)

            if let error = controller.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.needsScreenPermission {
                        Button("開啟螢幕錄製設定") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
            }

            // Fixed window height: the log absorbs leftover space so status/error text never pushes content off-screen.
            VStack(alignment: .leading, spacing: 4) {
                Text("執行記錄").font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    Text(controller.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(minHeight: 48, maxHeight: .infinity)
            }

            HStack {
                Toggle("啟動時檢查更新", isOn: $updates.checkOnLaunch)
                Spacer()
                if let note = updates.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Button("立即檢查") { Task { await updates.check(manual: true) } }
                    .disabled(updates.isChecking)
            }

            Text("取色時自動略過黑邊與字幕；只送出改變的顏色，畫面與聲音都不儲存或上傳。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
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

    private var regionDescription: String {
        guard let region = controller.captureRegion else { return "整個主螢幕" }
        return String(format: "框選範圍（寬 %.0f%%、高 %.0f%%）", region.width * 100, region.height * 100)
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .syncing: return .green
        case .connecting, .reconnecting, .stopping: return .orange
        case .idle: return controller.errorMessage == nil ? .secondary : .red
        }
    }
}

private struct Swatch: View {
    let title: String
    let color: ScreenRGB?

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 12)
                .fill(color.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255) }
                    ?? Color.secondary.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                .frame(width: 150, height: 96)
            Text(title).font(.headline)
            Text(color?.description ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(format(value))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private struct LampRow: View {
    let lamp: DiscoveredLamp

    var body: some View {
        HStack {
            Image(systemName: "light.cylindrical.ceiling")
            VStack(alignment: .leading) {
                Text("Ado Light Stick")
                Text(lamp.id.uuidString.prefix(8) + "…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let rssi = lamp.rssi {
                Text("\(rssi) dBm").font(.caption).foregroundStyle(.secondary)
            } else if lamp.remembered {
                Text("上次使用").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
