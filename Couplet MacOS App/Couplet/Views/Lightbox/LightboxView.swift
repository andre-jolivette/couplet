import SwiftUI
import AppKit

struct LightboxView: View {

    @EnvironmentObject var engine: EngineController
    @ObservedObject var vm: LightboxViewModel
    let allPairs: [DisplayPair]
    let collections: [CollectionItem]
    let onDecision: (Int, PairDecision) -> Void
    let onAddToCollection: (Int, Int) -> Void
    let onAnchor: (Int) async -> [DisplayPair]
    let onDismiss: () -> Void

    @State private var showExportSheet = false
    @State private var showCollectionPicker = false

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            VStack(spacing: 0) {

            // Image row — uses GeometryReader so it fills all remaining space.
            // Chevrons are fixed 48px; images split the rest equally.
            GeometryReader { geo in
                let chevronW: CGFloat = 48
                let gap: CGFloat = 12
                let metaH: CGFloat = 30    // reserved for filename text below each image
                // Clamp to avoid negative/zero frames during layout transitions
                let availW = max(200, geo.size.width - chevronW * 2 - gap)
                let availH = max(100, geo.size.height - 24 - metaH)
                let paneW = availW / 2

                HStack(spacing: 0) {
                    chevronButton(direction: .left, width: chevronW)

                    HStack(spacing: gap) {
                        if let pair = vm.currentPair {
                            imagePaneButton(
                                color: pair.colorA, filename: pair.filenameA,
                                date: pair.captureDateA, imageID: pair.imageAID,
                                pairCount: pair.pairCountA,
                                thumbnailURL: pair.thumbnailURLA,
                                sourcePath: pair.pathA, folderPath: pair.folderPathA,
                                width: paneW, height: availH
                            )
                            imagePaneButton(
                                color: pair.colorB, filename: pair.filenameB,
                                date: pair.captureDateB, imageID: pair.imageBID,
                                pairCount: pair.pairCountB,
                                thumbnailURL: pair.thumbnailURLB,
                                sourcePath: pair.pathB, folderPath: pair.folderPathB,
                                width: paneW, height: availH
                            )
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 12)

                    chevronButton(direction: .right, width: chevronW)
                }
            }

            actionBar

            if vm.isAnchored {
                anchorStripAboveFilmstrip
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: vm.isAnchored)
            }

            filmstrip
            } // end main VStack

            // Info rail — slides in from right
            if vm.showInfoRail, let pair = vm.currentPair {
                LightboxInfoRail(pair: pair)
                    .id(pair.id)  // reset @State (collapsed captions) on pair change
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        } // end outer HStack
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onContinuousHover { phase in
            if case .active = phase { vm.showControls() }
        }
        .onKeyPress(.rightArrow)        { Task { @MainActor in vm.goNext() };               return .handled }
        .onKeyPress(.leftArrow)         { Task { @MainActor in vm.goPrevious() };           return .handled }
        .onKeyPress(KeyEquivalent("d")) { Task { @MainActor in vm.goNext() };               return .handled }
        .onKeyPress(KeyEquivalent("a")) { Task { @MainActor in vm.goPrevious() };           return .handled }
        .onKeyPress(KeyEquivalent("l")) { Task { @MainActor in handleDecision(.liked) };    return .handled }
        .onKeyPress(KeyEquivalent("x")) { Task { @MainActor in handleDecision(.rejected) }; return .handled }
        .onKeyPress(KeyEquivalent("i")) { Task { @MainActor in vm.toggleInfoPin() };        return .handled }
        .onKeyPress(.space)             { Task { @MainActor in vm.toggleControls() };       return .handled }
        .onKeyPress(.escape)            { Task { @MainActor in onDismiss() };               return .handled }
        .overlay(alignment: .bottom) {
            if let message = vm.toastMessage {
                toastView(message: message).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            if let pair = vm.currentPair {
                ExportSheet(pair: pair)
            }
        }
        // Hidden button captures ⌘E when the lightbox is in the view hierarchy
        .background {
            Button { showExportSheet = true } label: { EmptyView() }
                .keyboardShortcut("e", modifiers: .command)
                .frame(width: 0, height: 0)
                .clipped()
        }
    }

    // MARK: - Decision

    private func handleDecision(_ decision: PairDecision) {
        guard let id = vm.currentPair?.id else { return }
        onDecision(id, decision)
        vm.syncDecision(id: id, decision: decision)
        vm.showControls()
    }

    private func lightboxScorePill(_ label: String, value: Float, color: Color, resting: Bool) -> some View {
        let opacity: Double = resting ? 0.25 : Double(max(0.35, min(1.0, value)))
        return HStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold))
            Text(String(format: "%.2f", value)).font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(opacity * 0.30)))
        .foregroundColor(color.opacity(opacity))
    }

    // MARK: - Top bar

    private var topBar: some View {
        let resting = !vm.controlsVisible
        let fgOpacity: Double    = resting ? 0.25 : 0.85
        let mutedOpacity: Double = resting ? 0.15 : 0.40

        return HStack(spacing: 12) {
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pairs")
                        .font(.system(size: 13))
                }
                .foregroundColor(.white.opacity(fgOpacity))
                .frame(minWidth: 60, minHeight: 36)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if vm.pairCount > 0 {
                Text("Pair \(vm.currentIndex + 1) of \(vm.pairCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(mutedOpacity))
            }

            Spacer()

            if let pair = vm.currentPair {
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) { vm.showInfoRail.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        lightboxScorePill("A", value: pair.aestheticScore,
                                          color: PairingModality.aesthetic.swiftColor, resting: resting)
                        lightboxScorePill("G", value: pair.geometricScore,
                                          color: PairingModality.geometric.swiftColor, resting: resting)
                        lightboxScorePill("T", value: pair.thematicScore,
                                          color: PairingModality.thematic.swiftColor, resting: resting)
                        Text(String(format: "%.3f", pair.compositeScore))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(mutedOpacity))
                        Image(systemName: vm.showInfoRail ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(resting ? 0.25 : 0.70))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(vm.showInfoRail ? Color.white.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.50))
        .animation(.easeOut(duration: 0.25), value: vm.controlsVisible)
    }

    // MARK: - Image pane

    private func imagePaneButton(
        color: NSColor, filename: String, date: Date?,
        imageID: Int, pairCount: Int, thumbnailURL: URL?,
        sourcePath: String, folderPath: String,
        width: CGFloat, height: CGFloat
    ) -> some View {
        let isAnchor = vm.anchorImageID == imageID
        let resting = !vm.controlsVisible
        let metaOpacity: Double = resting ? 0.20 : 0.50

        return VStack(spacing: 0) {
            Button {
                vm.toggleAnchor(imageID: imageID, filename: filename,
                                color: color, onFetch: onAnchor, allPairs: allPairs)
            } label: {
                ZStack(alignment: .topTrailing) {
                    // .fit ensures the full image is always visible — no cropping.
                    // Negative space appears above/below for portrait images,
                    // left/right for landscape images wider than the pane.
                    LightboxImageView(
                        thumbnailURL: thumbnailURL,
                        imageID: imageID,
                        sourcePath: sourcePath,
                        folderPath: folderPath
                    )
                    .frame(width: width, height: height)
                    .background(Color(white: 0.08))  // dark letterbox background
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                    if isAnchor {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white, lineWidth: 2)
                            .frame(width: width, height: height)
                    }
                    if isAnchor {
                        Text("Anchor")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.20)))
                            .padding(8)
                    }
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)

            // Metadata below image — outside the Button so text is selectable.
            // MetaLabel uses a single NSTextField for unified selection and a
            // tall frame so the user does not need to click precisely on the glyphs.
            HStack(alignment: .center, spacing: 8) {
                MetaLabel(
                    dateString: date.map { dateFormatter.string(from: $0) },
                    filename: filename,
                    baseOpacity: metaOpacity
                )
                .frame(maxWidth: .infinity, minHeight: 30)
                // Pair count badge — shows total pairs for this image in the
                // current folder context. Updates when imagePairCounts refreshes.
                if pairCount > 0 {
                    Text("\(pairCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(metaOpacity * 0.8))
                }
            }
            .frame(width: width)
            .padding(.top, 2)
        }
        .opacity(vm.isAnchored && !isAnchor ? 0.65 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isAnchor)
        .animation(.easeOut(duration: 0.2), value: vm.isAnchored)
        .animation(.easeOut(duration: 0.25), value: resting)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        let resting = !vm.controlsVisible
        let iconOpacity: Double  = resting ? 0.25 : 0.85
        let labelOpacity: Double = resting ? 0.15 : 0.35

        return HStack(spacing: 8) {
            if let pair = vm.currentPair {
                Text(pair.modality == .thematic ? pair.thematicRationale : pair.rationale)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(resting ? 0.15 : 0.50))
                    .lineLimit(1)
            }
            Spacer()
            if let pair = vm.currentPair {
                actionButton(icon: pair.decision == .liked ? "heart.fill" : "heart",
                             label: "L", activeColor: .pink,
                             isActive: pair.decision == .liked,
                             iconOpacity: iconOpacity, labelOpacity: labelOpacity) {
                    handleDecision(.liked)
                }
                actionButton(icon: pair.decision == .rejected ? "eye.slash.fill" : "eye.slash",
                             label: "X", activeColor: .orange,
                             isActive: pair.decision == .rejected,
                             iconOpacity: iconOpacity, labelOpacity: labelOpacity) {
                    handleDecision(.rejected)
                }
                Rectangle()
                    .fill(Color.white.opacity(resting ? 0.07 : 0.18))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 8)
                Button {
                    showCollectionPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(iconOpacity))
                        Text("⌘A").font(.system(size: 10))
                            .foregroundColor(.white.opacity(labelOpacity))
                    }
                    .frame(minWidth: 44, minHeight: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showCollectionPicker) {
                    CollectionPickerPopover(
                        collections: collections,
                        onSelect: { collectionID in
                            guard let pair = vm.currentPair else { return }
                            onAddToCollection(pair.id, collectionID)
                            showCollectionPicker = false
                        }
                    )
                }

                Divider().frame(height: 18).opacity(resting ? 0.10 : 0.25)

                actionButton(icon: "square.and.arrow.up", label: "⌘E",
                             activeColor: .blue, isActive: false,
                             iconOpacity: iconOpacity, labelOpacity: labelOpacity) {
                    showExportSheet = true
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black.opacity(0.55))
        .animation(.easeOut(duration: 0.25), value: vm.controlsVisible)
    }

    private func actionButton(
        icon: String, label: String, activeColor: Color,
        isActive: Bool, iconOpacity: Double, labelOpacity: Double,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundColor(isActive ? activeColor : .white.opacity(iconOpacity))
                Text(label).font(.system(size: 10))
                    .foregroundColor(.white.opacity(labelOpacity))
            }
            .frame(minWidth: 44, minHeight: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Anchor strip (above filmstrip)

    private var anchorStripAboveFilmstrip: some View {
        let anchorCount = engine.imagePairCounts[vm.anchorImageID ?? -1, default: 0]
        return HStack(spacing: 10) {
            if let color = vm.anchorColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: color))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.white, lineWidth: 1.5))
            }
            Text("Showing \(anchorCount) pairs for")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
            Text(vm.anchorFilename ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.80)).lineLimit(1)
            Spacer()
            Button(action: { vm.releaseAnchor(allPairs: allPairs) }) {
                Text("Release")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.70))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color.white.opacity(0.05))
    }

    // Compact anchor strip below topBar (when set from clicking an image)
    private var anchorStrip: some View { anchorStripAboveFilmstrip }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(vm.pairs.enumerated()), id: \.element.id) { idx, pair in
                        filmstripTile(pair: pair, index: idx)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.black.opacity(0.60))
            .frame(height: 88)
            .clipped()
            .onChange(of: vm.currentIndex) { _, newIndex in
                guard vm.pairs.indices.contains(newIndex) else { return }
                let pairID = vm.pairs[newIndex].id
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(pairID, anchor: .center)
                }
            }
        }
    }

    private func filmstripTile(pair: DisplayPair, index: Int) -> some View {
        // Compare by ID, not by index — index can drift if the array is reordered
        // or if LazyHStack rendering order doesn't match array order exactly.
        let isCurrent = pair.id == vm.currentPair?.id
        let tileW: CGFloat = isCurrent ? 68 : 56
        let tileH: CGFloat = isCurrent ? 58 : 48

        return Button {
            vm.jumpTo(pairID: pair.id)
        } label: {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 1) {
                    ThumbnailView(url: pair.thumbnailURLA, fallbackColor: pair.colorA)
                        .frame(width: (tileW - 1) / 2, height: tileH)
                        .clipped()
                    ThumbnailView(url: pair.thumbnailURLB, fallbackColor: pair.colorB)
                        .frame(width: (tileW - 1) / 2, height: tileH)
                        .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            isCurrent ? Color.white : Color.white.opacity(0.15),
                            lineWidth: isCurrent ? 2 : 1
                        )
                )

                if pair.decision == .liked {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color.pink.opacity(0.85)))
                        .padding(3)
                }
            }
            .frame(width: tileW, height: tileH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(pair.id)
        .animation(.easeOut(duration: 0.15), value: isCurrent)
    }

    // MARK: - Chevrons — always visible, outside image area

    enum ChevronDirection { case left, right }

    private func chevronButton(direction: ChevronDirection, width: CGFloat) -> some View {
        let canGo = direction == .left ? vm.canGoPrevious : vm.canGoNext
        return Button {
            direction == .left ? vm.goPrevious() : vm.goNext()
        } label: {
            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(canGo ? 0.80 : 0.18))
                .frame(width: 32, height: 44)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(canGo ? 0.10 : 0.03)))
                .frame(width: width)
                .contentShape(Rectangle().size(width: width, height: 1000))
        }
        .buttonStyle(.plain)
        .disabled(!canGo)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Toast

    private func toastView(message: String) -> some View {
        Text(message)
            .font(.system(size: 13)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .padding(.bottom, 100)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.3), value: vm.toastMessage)
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Selectable metadata label

/// Date + separator + filename rendered in a single NSTextView so:
/// - the whole line is selectable as one unit
/// - selectedTextAttributes only sets a subtle background tint, leaving
///   text color unchanged (NSTextField promotes selected text to full opacity)
/// - the frame is tall enough (~30pt) that the user does not need to click
///   precisely on the text glyphs to start a drag
private struct MetaLabel: NSViewRepresentable {
    let dateString: String?
    let filename: String
    let baseOpacity: Double

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.18)]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        apply(to: tv)
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) { apply(to: tv) }

    private func apply(to tv: NSTextView) {
        let font = NSFont.systemFont(ofSize: 11)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let s = NSMutableAttributedString()
        if let d = dateString {
            s.append(NSAttributedString(string: d, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(baseOpacity),
                .font: font, .paragraphStyle: para
            ]))
            s.append(NSAttributedString(string: "  |  ", attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(baseOpacity * 0.5),
                .font: font, .paragraphStyle: para
            ]))
        }
        s.append(NSAttributedString(string: filename, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(baseOpacity),
            .font: font, .paragraphStyle: para
        ]))
        tv.textStorage?.setAttributedString(s)
    }
}

// MARK: - Collection picker popover

private struct CollectionPickerPopover: View {
    let collections: [CollectionItem]
    let onSelect: (Int) -> Void

    @State private var hoveredID: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to Collection")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if collections.isEmpty {
                Text("No collections — create one in the sidebar.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            } else {
                ForEach(collections) { c in
                    Button(action: { onSelect(c.id) }) {
                        HStack {
                            Text(c.name)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(hoveredID == c.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredID = $0 ? c.id : nil }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(minWidth: 200)
    }
}
