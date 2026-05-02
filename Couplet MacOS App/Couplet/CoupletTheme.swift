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

// MARK: - Window Configurator
// Uses viewDidMoveToWindow — guaranteed to fire with a non-nil window,
// unlike .onAppear which can race against the window being ready.
// titlebarAppearsTransparent = true stops macOS painting its own material
// over the title bar area; backgroundColor gives it our exact zinc-950 colour
// from the very first frame.
struct WindowConfigurator: NSViewRepresentable {
    /// Closure fired when the sidebar toggle in the title bar is tapped.
    let onToggleSidebar: () -> Void
    /// Mirrors ContentView's sidebarVisible so the titlebar border line tracks it.
    let sidebarVisible: Bool

    func makeNSView(context: Context) -> ConfigView {
        ConfigView(onToggleSidebar: onToggleSidebar)
    }

    func updateNSView(_ nsView: ConfigView, context: Context) {
        nsView.onToggleSidebar = onToggleSidebar
        if let window = nsView.window {
            updateTitlebarSidebarBorder(in: window, visible: sidebarVisible)
        }
    }

    final class ConfigView: NSView {
        var onToggleSidebar: () -> Void
        private var hasInstalledAccessory = false

        init(onToggleSidebar: @escaping () -> Void) {
            self.onToggleSidebar = onToggleSidebar
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            installSidebarToggleAccessoryIfNeeded(on: window)
            let appColor = NSColor(red: 14/255, green: 14/255, blue: 16/255, alpha: 1)
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                installSolidTitlebar(in: window, color: appColor)
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window, queue: .main
                ) { [weak window] _ in
                    guard let w = window else { return }
                    installSolidTitlebar(in: w, color: appColor)
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: window, queue: .main
                ) { [weak window] _ in
                    guard let w = window else { return }
                    installSolidTitlebar(in: w, color: appColor)
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
            guard !hasInstalledAccessory else { return }
            hasInstalledAccessory = true

            let icon = TitlebarSidebarToggleIcon { [weak self] in
                self?.onToggleSidebar()
            }
            let hosting = NSHostingView(rootView: icon)
            hosting.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
            // Clear the hosting view's own background so it doesn't paint
            // over the window's backgroundColor in the title bar area.
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = hosting
            accessory.layoutAttribute = .leading

            window.addTitlebarAccessoryViewController(accessory)
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

private func installSolidTitlebar(in window: NSWindow, color: NSColor) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = color

    guard let closeButton = window.standardWindowButton(.closeButton),
          let titlebarView = closeButton.superview else { return }

    // Update existing cover if already installed.
    if let existing = titlebarView.subviews.first(where: { $0 is SolidTitlebarCover }) as? SolidTitlebarCover {
        existing.fillColor = color.cgColor
        return  // border line is already installed from the first call
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

    // Sidebar border — 1px vertical line aligned with the SwiftUI sidebar's trailing edge.
    // Coordinate-convert x=192 from contentView into titlebarView space so the line
    // is pixel-exact even if the two view hierarchies have different x origins.
    let borderX = window.contentView.map {
        $0.convert(CGPoint(x: 192, y: 0), to: titlebarView).x
    } ?? 192

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
}

/// Shows or hides the sidebar border line in the titlebar when the sidebar is toggled.
private func updateTitlebarSidebarBorder(in window: NSWindow, visible: Bool) {
    guard let closeButton = window.standardWindowButton(.closeButton),
          let titlebarView = closeButton.superview else { return }
    titlebarView.subviews.first(where: { $0 is TitlebarSidebarBorderLine })?.isHidden = !visible
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

