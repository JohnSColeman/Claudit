import SwiftUI
import AppKit
import ClauditCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        if let path = ProcessInfo.processInfo.environment["CLAUDIT_SNAPSHOT"] {
            snapshot(to: path)      // dev aid: render the popover to a PNG and quit
            return
        }
        controller = StatusController()
    }
}

extension AppDelegate {
    /// Renders the popover contents offscreen once data has loaded. Used to check layout without a screen.
    func snapshot(to path: String) {
        let store = UsageStore()
        store.start()
        Task { @MainActor in
            while store.isLoading { try? await Task.sleep(nanoseconds: 200_000_000) }
            if ProcessInfo.processInfo.environment["CLAUDIT_SNAPSHOT_EDITOR"] != nil {
                let host = NSHostingView(rootView: PriceEditorView(store: store, close: {}))
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            for (name, r) in [("today", store.today), ("week", store.week), ("month", store.month)] {
                print("\(name): \(Money.format(r?.total.total ?? 0)) over \(r?.prompts.count ?? 0) prompts, from \(r?.interval.start.description ?? "-")")
            }
            if ProcessInfo.processInfo.environment["CLAUDIT_SNAPSHOT_REAL"] != nil {
                // Real controls (ScrollView, segmented pickers) rendered offscreen.
                let host = NSHostingView(rootView: UsagePopover(store: store, onHover: { _ in }))
                host.frame = NSRect(x: 0, y: 0, width: 410, height: 580)
                let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            let view = UsagePopover(store: store, onHover: { _ in }, flat: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, ProcessInfo.processInfo.environment["CLAUDIT_DARK"] != nil ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
