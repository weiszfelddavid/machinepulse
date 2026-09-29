import AppKit
import MachinePulseCore
import MetalKit
import QuartzCore
import os

struct XDROverlayRenderCounts {
    var presentedFrameCount = 0
    var failedFrameCount = 0
}

struct XDROverlayRuntimeRecord {
    let displayID: LocalDisplayID
    let instanceID: UUID
    let multiplier: Double
    let frame: CGRect
    let isVisible: Bool
    let targetFramesPerSecond: Int
    let renderCounts: XDROverlayRenderCounts
}

struct XDROverlayRuntimeSnapshot {
    let generatedAt: Date
    let lifecycle: XDROverlayLifecycleSnapshot
    let overlays: [XDROverlayRuntimeRecord]
}

@MainActor
protocol XDROverlayManaging: AnyObject {
    var diagnosticSnapshot: XDROverlayRuntimeSnapshot { get }

    func activate(displayID: LocalDisplayID, screen: NSScreen, multiplier: Double) -> Bool
    func update(displayID: LocalDisplayID, screen: NSScreen, multiplier: Double)
    func reassertAll(reason: XDROverlayReassertionReason)
    func deactivate(displayID: LocalDisplayID)
    func deactivateAll()
}

@MainActor
final class XDROverlayController: XDROverlayManaging {
    private var overlays: [LocalDisplayID: XDROverlay] = [:]
    private var lifecycleAudit = XDROverlayLifecycleAudit()

    var diagnosticSnapshot: XDROverlayRuntimeSnapshot {
        XDROverlayRuntimeSnapshot(
            generatedAt: Date(),
            lifecycle: lifecycleAudit.snapshot(),
            overlays: overlays.map { displayID, overlay in
                overlay.runtimeRecord(displayID: displayID)
            }.sorted { $0.displayID.rawValue < $1.displayID.rawValue }
        )
    }

    func activate(displayID: LocalDisplayID, screen: NSScreen, multiplier: Double) -> Bool {
        if let overlay = overlays[displayID] {
            lifecycleAudit.recordActivation(
                displayID: displayID,
                instanceID: overlay.instanceID,
                at: Date()
            )
            applyUpdate(overlay.update(screen: screen, multiplier: multiplier), to: displayID)
            PulseLog.display.notice(
                "Reused the XDR overlay for \(displayID.rawValue, privacy: .public); instance \(overlay.instanceID.uuidString, privacy: .public)"
            )
            return true
        }
        guard let overlay = XDROverlay(screen: screen, multiplier: multiplier) else { return false }
        overlays[displayID] = overlay
        lifecycleAudit.recordActivation(
            displayID: displayID,
            instanceID: overlay.instanceID,
            at: Date()
        )
        PulseLog.display.info(
            "Created XDR overlay \(overlay.instanceID.uuidString, privacy: .public) for \(displayID.rawValue, privacy: .public) at \(XDROverlayRenderPolicy.framesPerSecond, privacy: .public) fps"
        )
        return true
    }

    func update(displayID: LocalDisplayID, screen: NSScreen, multiplier: Double) {
        guard let overlay = overlays[displayID] else { return }
        applyUpdate(overlay.update(screen: screen, multiplier: multiplier), to: displayID)
    }

    func reassertAll(reason: XDROverlayReassertionReason) {
        let timestamp = Date()
        for (displayID, overlay) in overlays {
            let visibilityRestored = overlay.reassert()
            lifecycleAudit.recordReassertion(displayID: displayID, reason: reason, at: timestamp)
            if visibilityRestored {
                lifecycleAudit.recordVisibilityRestore(displayID: displayID, at: timestamp)
            }
            PulseLog.display.debug(
                "Reasserted XDR overlay \(overlay.instanceID.uuidString, privacy: .public) after \(reason.rawValue, privacy: .public); visibility restored: \(visibilityRestored, privacy: .public)"
            )
        }
    }

    func deactivate(displayID: LocalDisplayID) {
        guard let overlay = overlays.removeValue(forKey: displayID) else { return }
        lifecycleAudit.recordDeactivation(displayID: displayID, at: Date())
        overlay.close()
        PulseLog.display.info(
            "Destroyed XDR overlay \(overlay.instanceID.uuidString, privacy: .public) for \(displayID.rawValue, privacy: .public)"
        )
    }

    func deactivateAll() {
        let current = overlays
        overlays = [:]
        let timestamp = Date()
        for (displayID, overlay) in current {
            lifecycleAudit.recordDeactivation(displayID: displayID, at: timestamp)
            overlay.close()
            PulseLog.display.info(
                "Destroyed XDR overlay \(overlay.instanceID.uuidString, privacy: .public) for \(displayID.rawValue, privacy: .public) during teardown"
            )
        }
    }

    private func applyUpdate(_ result: XDROverlayUpdateResult, to displayID: LocalDisplayID) {
        lifecycleAudit.recordUpdate(
            displayID: displayID,
            geometryChanged: result.geometryChanged,
            multiplierChanged: result.multiplierChanged,
            at: Date()
        )
        if result.visibilityRestored {
            lifecycleAudit.recordVisibilityRestore(displayID: displayID, at: Date())
            PulseLog.display.notice(
                "Restored visibility for XDR overlay on \(displayID.rawValue, privacy: .public)"
            )
        }
    }
}

private struct XDROverlayUpdateResult {
    let geometryChanged: Bool
    let multiplierChanged: Bool
    let visibilityRestored: Bool
}

@MainActor
private final class XDROverlay {
    let instanceID = UUID()

    private let window: NSWindow
    private let view: MTKView
    private let renderer: StaticMetalRenderer
    private var multiplier: Double

    init?(screen: NSScreen, multiplier: Double) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = StaticMetalRenderer(device: device) else {
            return nil
        }
        self.multiplier = multiplier
        self.renderer = renderer

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .readOnly
        window.alphaValue = 0
        self.window = window

        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = Self.clearColor(multiplier)
        view.preferredFramesPerSecond = XDROverlayRenderPolicy.framesPerSecond
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = renderer
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.compositingFilter = "multiply"
        Self.configureEDR(layer: view.layer, multiplier: multiplier)
        self.view = view

        window.contentView = view
        window.orderFrontRegardless()
        view.draw()
        CATransaction.flush()
        window.alphaValue = 1

        // Once the first drawable is present, keep the EDR surface alive at a
        // modest cadence. Periodically replacing one paused drawable caused
        // the visible disappear/return cycle over changing content.
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    func update(screen: NSScreen, multiplier: Double) -> XDROverlayUpdateResult {
        // NSScreen instances are rediscovered every poll. Stable display
        // identity is established by LocalDisplayID, so object inequality is
        // not a screen change and must not trigger a drawable presentation.
        let geometryChanged = window.frame != screen.frame
        if geometryChanged {
            window.setFrame(screen.frame, display: false)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
        }

        let multiplierChanged = abs(self.multiplier - multiplier) > 0.001
        if multiplierChanged {
            self.multiplier = multiplier
            view.clearColor = Self.clearColor(multiplier)
            Self.configureEDR(layer: view.layer, multiplier: multiplier)
        }

        let visibilityRestored = !window.isVisible
        if visibilityRestored { window.orderFrontRegardless() }
        return XDROverlayUpdateResult(
            geometryChanged: geometryChanged,
            multiplierChanged: multiplierChanged,
            visibilityRestored: visibilityRestored
        )
    }

    /// Re-apply WindowServer-facing attributes only after an actual lifecycle
    /// transition. The continuous MTKView loop presents the configured surface;
    /// forcing an additional drawable here can itself make the effect blink.
    func reassert() -> Bool {
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        view.layer?.compositingFilter = "multiply"
        Self.configureEDR(layer: view.layer, multiplier: multiplier)
        let visibilityRestored = !window.isVisible
        if visibilityRestored { window.orderFrontRegardless() }
        return visibilityRestored
    }

    func runtimeRecord(displayID: LocalDisplayID) -> XDROverlayRuntimeRecord {
        XDROverlayRuntimeRecord(
            displayID: displayID,
            instanceID: instanceID,
            multiplier: multiplier,
            frame: window.frame,
            isVisible: window.isVisible,
            targetFramesPerSecond: view.preferredFramesPerSecond,
            renderCounts: renderer.renderCounts
        )
    }

    func close() {
        view.isPaused = true
        view.delegate = nil
        view.releaseDrawables()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private static func clearColor(_ multiplier: Double) -> MTLClearColor {
        MTLClearColor(red: multiplier, green: multiplier, blue: multiplier, alpha: 1)
    }

    private static func configureEDR(layer: CALayer?, multiplier: Double) {
        guard let layer else { return }
        if #available(macOS 26, *) {
            layer.preferredDynamicRange = .high
            layer.contentsHeadroom = multiplier
        } else {
            layer.wantsExtendedDynamicRangeContent = true
        }
    }
}

private final class StaticMetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let counts = OSAllocatedUnfairLock(initialState: XDROverlayRenderCounts())

    var renderCounts: XDROverlayRenderCounts { counts.withLock { $0 } }

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
            let drawable = view.currentDrawable
        else {
            counts.withLock { $0.failedFrameCount += 1 }
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        counts.withLock { $0.presentedFrameCount += 1 }
    }
}
