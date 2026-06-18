import SwiftUI
import AppKit

// MARK: - Design Tokens
// Zinc-based dark palette. No accent colors in UI chrome.

extension Color {
    static let appBackground      = Color(hex: "#0e0e10") // zinc-950 — app bg
    static let appForeground      = Color(hex: "#bdbdc4") // zinc-300 — primary text
    static let appCard            = Color(hex: "#18181b") // zinc-900 — panel surfaces
    static let appSecondary       = Color(hex: "#27272a") // zinc-800 — hover, active item bg
    static let appMutedForeground = Color(hex: "#71717a") // zinc-500 — dim/secondary text
    static let appPrimary         = Color(hex: "#f4f4f5") // zinc-100 — buttons, active pills
    static let appBorder          = Color(hex: "#27272a") // zinc-800 — borders, inputs

    /// Blue accent used exclusively in the setup flow for human-action rows ("Needs You").
    /// Distinct from the app's default zinc/monochrome palette — nothing else uses blue.
    static let setupAccent        = Color(hex: "#3b82f6") // blue-500
    static let setupSuccess       = Color(hex: "#22c55e") // green-500
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}

// MARK: - Passthrough hosting view
// Used for the filter bar embedded directly in NSTitlebarView. Returning
// mouseDownCanMoveWindow = true lets clicks on the background initiate window
// dragging while SwiftUI controls inside still receive their own events.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    deinit {}
}

// MARK: - Window Configurator
// Uses viewDidMoveToWindow — guaranteed to fire with a non-nil window,
// unlike .onAppear which can race against the window being ready.
//
// Layout strategy for the top chrome band:
//   • An empty NSToolbar (no items) with toolbarStyle = .unifiedCompact gives
//     NSTitlebarView a ~38px combined band — enough for filter controls — without
//     triggering any NSToolbarItem liquid-glass treatment.
//   • SolidTitlebarCover fills the entire band with solid zinc-950.
//   • FilterBarHostingView is inserted directly into NSTitlebarView above the
//     cover, starting at x=193 (right of the sidebar border), giving the filter
//     controls a raw NSView home with no container styling.
struct WindowConfigurator: NSViewRepresentable {
    let onToggleSidebar: () -> Void
    let sidebarVisible: Bool
    let lightboxOpen: Bool
    let filterBarContent: AnyView
    let lightboxTitlebarContent: AnyView

    func makeNSView(context: Context) -> ConfigView {
        ConfigView(onToggleSidebar: onToggleSidebar, filterBarContent: filterBarContent,
                   lightboxTitlebarContent: lightboxTitlebarContent)
    }

    func updateNSView(_ nsView: ConfigView, context: Context) {
        nsView.onToggleSidebar = onToggleSidebar
        if let window = nsView.window {
            updateTitlebarSidebarBorder(in: window, visible: sidebarVisible && !lightboxOpen)
            nsView.updateSidebarToggle(in: window, lightboxOpen: lightboxOpen)
            updateTitlebarBottomBorderLeading(in: window, lightboxOpen: lightboxOpen, sidebarVisible: sidebarVisible)
        }
        nsView.updateTitlebarBars(filterContent: filterBarContent,
                                  lightboxContent: lightboxTitlebarContent,
                                  lightboxOpen: lightboxOpen)
    }

    final class ConfigView: NSView {
        var onToggleSidebar: () -> Void
        private let initialFilterBarContent: AnyView
        private let initialLightboxTitlebarContent: AnyView
        private var filterBarHostingView: PassthroughHostingView<AnyView>?
        private var lightboxBarHostingView: PassthroughHostingView<AnyView>?
        private var hasInstalledSidebarToggle = false
        private var sidebarToggleAccessory: NSTitlebarAccessoryViewController?
        private var hasInstalledFilterBar = false
        private var hasInstalledLightboxBar = false

        init(onToggleSidebar: @escaping () -> Void, filterBarContent: AnyView,
             lightboxTitlebarContent: AnyView) {
            self.onToggleSidebar = onToggleSidebar
            self.initialFilterBarContent = filterBarContent
            self.initialLightboxTitlebarContent = lightboxTitlebarContent
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden

            // Empty toolbar — no items, so no liquid glass — solely to make
            // NSTitlebarView tall enough to hold the filter bar controls.
            let emptyToolbar = NSToolbar(identifier: "com.toastbrigade.Couplet.emptyToolbar")
            emptyToolbar.displayMode = .iconOnly
            emptyToolbar.showsBaselineSeparator = false
            window.toolbar = emptyToolbar
            window.toolbarStyle = .unified

            installSidebarToggleAccessoryIfNeeded(on: window)

            let appColor = NSColor(red: 14/255, green: 14/255, blue: 16/255, alpha: 1)
            DispatchQueue.main.async { [weak window, weak self] in
                guard let window else { return }
                installSolidTitlebar(in: window, color: appColor)
                self?.installFilterBarInTitlebar(in: window)
                self?.installLightboxBarInTitlebar(in: window)
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window, queue: .main
                ) { [weak window, weak self] _ in
                    guard let w = window else { return }
                    installSolidTitlebar(in: w, color: appColor)
                    self?.installFilterBarInTitlebar(in: w)
                    self?.installLightboxBarInTitlebar(in: w)
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: window, queue: .main
                ) { [weak window, weak self] _ in
                    guard let w = window else { return }
                    installSolidTitlebar(in: w, color: appColor)
                    self?.installFilterBarInTitlebar(in: w)
                    self?.installLightboxBarInTitlebar(in: w)
                }
            }
        }

        /// Adds the sidebar toggle as an NSTitlebarAccessoryViewController
        /// with layoutAttribute = .leading. macOS places the accessory directly
        /// after the traffic lights in the title bar — no toolbar wrapping, no
        /// capsule hover styling. This is the only way to render a bare icon
        /// button in the title bar area: putting it in `.toolbar` via
        /// ToolbarItem always applies an NSToolbarItem container background
        /// that cannot be overridden from inside.
        private func installSidebarToggleAccessoryIfNeeded(on window: NSWindow) {
            guard !hasInstalledSidebarToggle else { return }
            hasInstalledSidebarToggle = true

            let icon = TitlebarSidebarToggleIcon { [weak self] in
                self?.onToggleSidebar()
            }
            let hosting = NSHostingView(rootView: icon)
            hosting.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = hosting
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
            sidebarToggleAccessory = accessory
        }

        /// Removes the sidebar toggle accessory from the window when the lightbox
        /// is open (mere hide/alpha=0 still reserves the accessory's event zone in
        /// AppKit's responder chain, blocking clicks on the back button arrow).
        /// Re-adds it when the lightbox closes.
        func updateSidebarToggle(in window: NSWindow, lightboxOpen: Bool) {
            guard let accessory = sidebarToggleAccessory else { return }
            let isInstalled = window.titlebarAccessoryViewControllers.contains { $0 === accessory }
            if lightboxOpen && isInstalled {
                if let idx = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                    window.removeTitlebarAccessoryViewController(at: idx)
                }
            } else if !lightboxOpen && !isInstalled {
                window.addTitlebarAccessoryViewController(accessory)
            }
        }

        /// Inserts FilterBarView as a raw PassthroughHostingView directly into
        /// NSTitlebarView — no NSTitlebarAccessoryViewController, no NSToolbarItem,
        /// no liquid glass. Positioned from x=193 (right of the sidebar border)
        /// to the trailing edge, spanning the full titlebar height.
        private func installFilterBarInTitlebar(in window: NSWindow) {
            guard !hasInstalledFilterBar else { return }
            guard let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarView = closeButton.superview else { return }
            hasInstalledFilterBar = true

            let hosting = PassthroughHostingView(rootView: initialFilterBarContent)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor(red: 14/255, green: 14/255, blue: 16/255, alpha: 1).cgColor
            hosting.translatesAutoresizingMaskIntoConstraints = false

            let solidCover = titlebarView.subviews.first(where: { $0 is SolidTitlebarCover })
            titlebarView.addSubview(hosting, positioned: .above, relativeTo: solidCover)

            NSLayoutConstraint.activate([
                hosting.leadingAnchor .constraint(equalTo: titlebarView.leadingAnchor, constant: 192),
                hosting.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
                hosting.topAnchor     .constraint(equalTo: titlebarView.topAnchor),
                hosting.bottomAnchor  .constraint(equalTo: titlebarView.bottomAnchor),
            ])

            filterBarHostingView = hosting
        }

        /// Inserts LightboxTitlebarView as a PassthroughHostingView directly into
        /// NSTitlebarView, spanning the full width (leading + 0). Internal 80pt padding
        /// inside the SwiftUI view clears the traffic lights and sidebar toggle accessory.
        /// Initially hidden (alpha=0); shown when lightboxOpen is true.
        private func installLightboxBarInTitlebar(in window: NSWindow) {
            guard !hasInstalledLightboxBar else { return }
            guard let closeButton = window.standardWindowButton(.closeButton),
                  let titlebarView = closeButton.superview else { return }
            hasInstalledLightboxBar = true

            let hosting = PassthroughHostingView(rootView: initialLightboxTitlebarContent)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor(red: 14/255, green: 14/255, blue: 16/255, alpha: 1).cgColor
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.isHidden = true

            // Must be above filterBarHostingView, not just above solidCover.
            // addSubview(.above, relativeTo: X) inserts just above X; if we reference
            // solidCover again the filter bar (added first) ends up on top, blocking
            // events in the filter-bar region (x≥192) even when its alpha is 0.
            let reference: NSView = filterBarHostingView
                ?? titlebarView.subviews.first(where: { $0 is SolidTitlebarCover })
                ?? titlebarView
            titlebarView.addSubview(hosting, positioned: .above, relativeTo: reference)

            NSLayoutConstraint.activate([
                hosting.leadingAnchor .constraint(equalTo: titlebarView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
                hosting.topAnchor     .constraint(equalTo: titlebarView.topAnchor),
                hosting.bottomAnchor  .constraint(equalTo: titlebarView.bottomAnchor),
            ])

            lightboxBarHostingView = hosting
        }

        func updateTitlebarBars(filterContent: AnyView, lightboxContent: AnyView, lightboxOpen: Bool) {
            filterBarHostingView?.rootView = filterContent
            filterBarHostingView?.isHidden = lightboxOpen
            lightboxBarHostingView?.rootView = lightboxContent
            lightboxBarHostingView?.isHidden = !lightboxOpen
        }
    }
}

// MARK: - Solid title bar helpers

private final class SolidTitlebarCover: NSView {
    var fillColor: CGColor {
        didSet { layer?.backgroundColor = fillColor }
    }
    init(color: CGColor) {
        self.fillColor = color
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = fillColor }
    override func makeBackingLayer() -> CALayer {
        let l = CALayer()
        l.backgroundColor = fillColor
        return l
    }
}

private final class TitlebarSidebarBorderLine: NSView {}
private final class TitlebarToolsBottomBorder: NSView {
    var leadingConstraint: NSLayoutConstraint?
}

private func installSolidTitlebar(in window: NSWindow, color: NSColor) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = color

    guard let closeButton = window.standardWindowButton(.closeButton),
          let titlebarView = closeButton.superview else { return }

    // Update existing cover if already installed.
    if let existing = titlebarView.subviews.first(where: { $0 is SolidTitlebarCover }) as? SolidTitlebarCover {
        existing.fillColor = color.cgColor
        return
    }

    // The frosted-glass effect comes from NSTitlebarBackgroundView, which is
    // always the bottom-most subview (index 0) of NSTitlebarView. All controls
    // (traffic lights, accessory button) are at higher subview indices. We
    // insert our solid cover at index 1 — above the background but below every
    // control — so no re-stacking is needed.
    guard let bgView = titlebarView.subviews.first else { return }

    let solid = SolidTitlebarCover(color: color.cgColor)
    solid.translatesAutoresizingMaskIntoConstraints = false
    titlebarView.addSubview(solid, positioned: .above, relativeTo: bgView)
    NSLayoutConstraint.activate([
        solid.leadingAnchor .constraint(equalTo: titlebarView.leadingAnchor),
        solid.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
        solid.topAnchor     .constraint(equalTo: titlebarView.topAnchor),
        solid.bottomAnchor  .constraint(equalTo: titlebarView.bottomAnchor),
    ])

    // 1px vertical border at x=191. SwiftUI's .overlay(alignment: .trailing) on the
    // 192pt sidebar places the 1pt rectangle at x=191–192 (trailing edge aligned to
    // x=192, so the rect occupies 191–192). The AppKit line must match that x to avoid
    // a 1pt kink at the titlebar/content boundary.
    let borderX: CGFloat = 191

    let borderLine = TitlebarSidebarBorderLine()
    borderLine.wantsLayer = true
    borderLine.layer?.backgroundColor = NSColor(red: 39/255, green: 39/255, blue: 42/255, alpha: 1).cgColor
    borderLine.translatesAutoresizingMaskIntoConstraints = false
    titlebarView.addSubview(borderLine, positioned: .above, relativeTo: solid)
    NSLayoutConstraint.activate([
        borderLine.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor, constant: borderX),
        borderLine.widthAnchor  .constraint(equalToConstant: 1),
        borderLine.topAnchor    .constraint(equalTo: titlebarView.topAnchor),
        borderLine.bottomAnchor .constraint(equalTo: titlebarView.bottomAnchor),
    ])

    // 1px bottom stroke running from the sidebar edge to the trailing window edge.
    let bottomBorder = TitlebarToolsBottomBorder()
    bottomBorder.wantsLayer = true
    bottomBorder.layer?.backgroundColor = NSColor(red: 39/255, green: 39/255, blue: 42/255, alpha: 1).cgColor
    bottomBorder.translatesAutoresizingMaskIntoConstraints = false
    titlebarView.addSubview(bottomBorder, positioned: .above, relativeTo: solid)
    let bottomBorderLeading = bottomBorder.leadingAnchor.constraint(equalTo: titlebarView.leadingAnchor, constant: 192)
    bottomBorder.leadingConstraint = bottomBorderLeading
    NSLayoutConstraint.activate([
        bottomBorderLeading,
        bottomBorder.trailingAnchor.constraint(equalTo: titlebarView.trailingAnchor),
        bottomBorder.bottomAnchor  .constraint(equalTo: titlebarView.bottomAnchor),
        bottomBorder.heightAnchor  .constraint(equalToConstant: 1),
    ])
}

private func updateTitlebarSidebarBorder(in window: NSWindow, visible: Bool) {
    guard let closeButton = window.standardWindowButton(.closeButton),
          let titlebarView = closeButton.superview else { return }
    titlebarView.subviews.first(where: { $0 is TitlebarSidebarBorderLine })?.isHidden = !visible
}

private func updateTitlebarBottomBorderLeading(in window: NSWindow, lightboxOpen: Bool, sidebarVisible: Bool) {
    guard let closeButton = window.standardWindowButton(.closeButton),
          let titlebarView = closeButton.superview else { return }
    guard let border = titlebarView.subviews.first(where: { $0 is TitlebarToolsBottomBorder })
            as? TitlebarToolsBottomBorder else { return }
    let newConstant: CGFloat = (lightboxOpen || !sidebarVisible) ? 0 : 192
    if border.leadingConstraint?.constant != newConstant {
        border.leadingConstraint?.constant = newConstant
    }
}


// MARK: - Title bar sidebar toggle button

/// Pure-SwiftUI button rendered inside an NSHostingView and attached to the
/// window title bar via NSTitlebarAccessoryViewController. Because it isn't
/// inside `.toolbar`, it gets no NSToolbarItem container and no hover capsule.
private struct TitlebarSidebarToggleIcon: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.appMutedForeground)
                .frame(width: 36, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle Sidebar")
    }
}

