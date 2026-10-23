import AppKit
import CoreGraphics

/// Full-screen overlay on the main display: drag a rectangle to pick the area to sample, Esc to cancel.
/// Reports the rectangle normalized to the display (0–1, top-left origin), or nil when cancelled or too small.
enum RegionSelector {
    private static var overlay: NSWindow?

    static func select(completion: @escaping (CGRect?) -> Void) {
        guard overlay == nil else { return }
        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[screenKey] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) ?? NSScreen.main else { return }

        let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { rect in
            window.orderOut(nil)
            overlay = nil
            let size = view.bounds.size
            guard let rect, rect.width >= 20, rect.height >= 20, size.width > 0, size.height > 0 else {
                completion(nil)
                return
            }
            completion(CGRect(
                x: rect.minX / size.width,
                y: (size.height - rect.maxY) / size.height,
                width: rect.width / size.width,
                height: rect.height / size.height
            ))
        }
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        overlay = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        finish(selection)
    }

    override func cancelOperation(_ sender: Any?) { finish(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil) } else { super.keyDown(with: event) } // 53 = Esc
    }

    private func finish(_ rect: CGRect?) {
        let callback = onFinish
        onFinish = nil
        callback?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.systemGreen.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 3
            outline.stroke()
        }
        let text = "拖曳框選影片所在的範圍，手燈只跟這塊畫面變色。按 Esc 取消。" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 80)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: NSRect(origin: origin, size: size).insetBy(dx: -16, dy: -10), xRadius: 10, yRadius: 10).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
