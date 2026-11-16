import AppKit
import SwiftUI
import Combine
import ServiceManagement
import ClauditCore

/// Owns the menu bar item. Hovering the item shows the usage popover; clicking pins it open.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let store = UsageStore()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var pinned = false
    private var overPopover = false
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var priceWindow: NSWindow?

    override init() {
        super.init()
        configureButton()
        configurePopover()
        store.$today
            .receive(on: DispatchQueue.main)
            .sink { [weak self] report in self?.updateTitle(report) }
            .store(in: &cancellables)
        store.$excluded.combineLatest(store.$universe)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateIcon() }
            .store(in: &cancellables)
        store.start()
    }

    private func updateIcon() {
        let name = store.isFiltered ? "line.3.horizontal.decrease.circle" : "gauge.with.dots.needle.33percent"
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Claudit")
    }

    // MARK: Status item

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Claudit")
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let area = NSTrackingArea(rect: button.bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        button.addTrackingArea(area)
        updateTitle(nil)
    }

    private func updateTitle(_ report: Report?) {
        guard let button = item.button else { return }
        let text = report.map { " " + Money.format($0.total.total) } ?? " …"
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    @objc private func mouseEntered(_ event: NSEvent) {
        hideWork?.cancel()
        guard !popover.isShown else { return }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPopover() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func mouseExited(_ event: NSEvent) {
        showWork?.cancel()
        scheduleHide()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Edit prices…", action: #selector(openPriceEditor), keyEquivalent: "").target = self
            let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Claudit", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if pinned {
            pinned = false
            popover.close()
        } else {
            pinned = true
            popover.behavior = .transient     // closes on outside click
            if !popover.isShown { showPopover() }
        }
    }

    @objc private func refreshNow() { store.refresh() }

    /// Opens the price editor in its own window (text fields need a window that can take keyboard focus,
    /// which the hover popover can't guarantee).
    @objc private func openPriceEditor() {
        popover.close()
        pinned = false
        priceWindow?.close()
        let view = PriceEditorView(store: store) { [weak self] in self?.priceWindow?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Claudit — Model prices"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        priceWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Claudit: launch-at-login change failed: \(error)")
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Popover

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let view = UsagePopover(store: store,
                                onHover: { [weak self] hovering in self?.popoverHover(hovering) },
                                onEditPrices: { [weak self] in self?.openPriceEditor() },
                                onBeginEditing: { [weak self] in self?.beginTextEntry() })
        popover.contentViewController = NSHostingController(rootView: view)
        // Without this the popover anchors at the 320x320 default, then grows upward off the top of the screen.
        popover.contentSize = NSSize(width: 410, height: 580)
    }

    private func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// The allowance field needs keyboard focus: pin the popover so hover-out doesn't close it mid-edit,
    /// and activate the (menu bar only) app so the popover window can become key.
    private func beginTextEntry() {
        pinned = true
        hideWork?.cancel()
        popover.behavior = .transient
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func popoverHover(_ hovering: Bool) {
        overPopover = hovering
        if hovering { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard !pinned else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned, !self.overPopover else { return }
            self.popover.close()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            self.pinned = false
            self.overPopover = false
            self.popover.behavior = .applicationDefined
        }
    }
}
