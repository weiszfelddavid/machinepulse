import AppKit

@main
struct MachinePulseXDRFixtureApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
private final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let content = DynamicContentView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MachinePulse XDR stability fixture"
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        content.startAnimating()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit MachinePulse XDR Fixture",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }
}

@MainActor
private final class DynamicContentView: NSView {
    private enum Mode {
        case dynamic
        case staticNeutral
    }

    private var mode = Mode.dynamic
    private var phase: CGFloat = 0
    private var timer: Timer?
    private var startedAt = Date()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func startAnimating() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(advanceFrame),
            userInfo: nil,
            repeats: true
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            mode = mode == .dynamic ? .staticNeutral : .dynamic
            phase = 0
            startedAt = Date()
            needsDisplay = true
            return
        }
        if event.keyCode == 53 {
            NSApplication.shared.terminate(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch mode {
        case .dynamic:
            drawDynamicFixture()
        case .staticNeutral:
            drawStaticFixture()
        }
        drawInstructions()
    }

    @objc private func advanceFrame() {
        guard mode == .dynamic else { return }
        phase = (phase + 0.008).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    private func drawDynamicFixture() {
        let hue = phase.truncatingRemainder(dividingBy: 1)
        let start = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.18, alpha: 1)
        let end = NSColor(
            calibratedHue: (hue + 0.28).truncatingRemainder(dividingBy: 1),
            saturation: 0.7,
            brightness: 0.78,
            alpha: 1
        )
        NSGradient(starting: start, ending: end)?.draw(in: bounds, angle: 20 + phase * 90)

        let columnWidth = max(84, bounds.width / 9)
        for index in 0..<11 {
            let progress = (CGFloat(index) / 11 + phase).truncatingRemainder(dividingBy: 1)
            let x = progress * (bounds.width + columnWidth) - columnWidth
            let height = bounds.height * (0.24 + CGFloat(index % 5) * 0.11)
            let rect = NSRect(x: x, y: bounds.midY - height / 2, width: columnWidth * 0.72, height: height)
            NSColor.white.withAlphaComponent(index.isMultiple(of: 2) ? 0.24 : 0.1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
        }

        let lineHeight: CGFloat = 32
        for index in 0..<18 {
            let y =
                (CGFloat(index) * lineHeight + phase * lineHeight * 18)
                .truncatingRemainder(dividingBy: bounds.height + lineHeight) - lineHeight
            let width = bounds.width * (0.35 + CGFloat(index % 6) * 0.09)
            let rect = NSRect(x: 44, y: y, width: min(width, bounds.width - 88), height: 4)
            NSColor.white.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawStaticFixture() {
        NSColor(calibratedWhite: 0.48, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedWhite: 0.54, alpha: 1).setStroke()
        let grid = NSBezierPath()
        stride(from: CGFloat(0), through: bounds.width, by: 48).forEach {
            grid.move(to: NSPoint(x: $0, y: 0))
            grid.line(to: NSPoint(x: $0, y: bounds.height))
        }
        stride(from: CGFloat(0), through: bounds.height, by: 48).forEach {
            grid.move(to: NSPoint(x: 0, y: $0))
            grid.line(to: NSPoint(x: bounds.width, y: $0))
        }
        grid.lineWidth = 1
        grid.stroke()
    }

    private func drawInstructions() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let modeLabel = mode == .dynamic ? "DYNAMIC · 30 fps" : "STATIC NEUTRAL"
        let title = "MachinePulse XDR soak · \(modeLabel)"
        let subtitle =
            mode == .dynamic
            ? "Space switches modes · Esc or ⌘Q quits · Mode time \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            : "Pixels intentionally stay fixed · use an external 5-minute timer · Space resumes motion"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82),
        ]
        (title as NSString).draw(at: NSPoint(x: 28, y: 24), withAttributes: attributes)
        (subtitle as NSString).draw(at: NSPoint(x: 28, y: 56), withAttributes: subtitleAttributes)
    }
}
