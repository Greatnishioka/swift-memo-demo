import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum AppDefaults {
    static let paperOpacity = 0.2
    static let paperBrightness = 0.1
    static let contourPaddingPixels = 60.0
    static let contourMaskInsetPixels = 3.0
    static let contourSmoothingIterations = 3
    static let contourSmoothingStrength = 0.35
    static let contourSpikeRemovalIterations = 2
    static let contourSpikeAngleDegrees = 48.0
    static let contourSpikeDistanceMultiplier = 2.15
    static let contourStraighteningEnabled = true
    static let contourStraighteningWindow = 7
    static let contourStraighteningAngleDegrees = 10.0
    static let contourStraighteningMinimumRun = 30
    static let contourStraighteningStrength = 0.86
    static let contourCurveSmoothingIterations = 2
    static let contourCurveSmoothingAmount = 0.24
    static let minimumDetectionGuideOverlap = 0.62
    static let minimumDetectionAreaRatio = 0.55
    static let minimumAutoCandidateScore = 2.05
    static let preferGuidedBackgroundContour = true
    static let guidedContourRayCount = 220
    static let guidedContourMinimumPointRatio = 0.45
    static let guidedContourMinimumAreaRatio = 0.18
    static let guidedForegroundBackgroundDistance = 26.0
    static let guidedForegroundMinimumDarknessDelta = 16.0
    static let preferRectangularGuideContour = true
    static let preferColoredRectangleInRectangularGuide = true
    static let coloredRectangleMinimumFillRatio = 0.18
    static let coloredRectangleMinimumSideRatio = 0.45
    static let coloredRectangleWhiteThreshold = 242
    static let coloredRectangleSaturationThreshold = 10
    static let coloredRectangleDarkThreshold = 35
    static let rectangularGuideFillRatio = 0.78
    static let rectangularGuideSideCoverage = 0.58
    static let rectangularContourPointsPerSide = 18
}

struct MemoPreviewConfiguration {
    var contourBlurRadius = 0.0
    var contourAdjustmentPixels = 0.0
    var usesManualTextArea = false
    var textArea = CGRect(x: 0.16, y: 0.18, width: 0.68, height: 0.64)
}

@main
struct MemoPaperApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()

        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var delegateRetainer: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        delegateRetainer = self

        let size = NSSize(width: 560, height: 760)
        let hostingView = NSHostingView(rootView: MemoPaperView())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Memo Paper"
        window.contentView = hostingView
        window.setFrame(NSRect(origin: centeredOrigin(for: size), size: size), display: true)
        window.minSize = NSSize(width: 420, height: 560)
        window.backgroundColor = .windowBackgroundColor
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func centeredOrigin(for size: NSSize) -> NSPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        return NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
    }
}

struct MemoPaperView: View {
    @State private var memoImage: NSImage?
    @State private var memoText = ""
    @State private var paperOpacity = AppDefaults.paperOpacity
    @State private var paperBrightness = AppDefaults.paperBrightness
    @State private var isDropTargeted = false
    @State private var isTracingContour = false
    @State private var tracePoints: [CGPoint] = []
    @State private var appliedContour: [CGPoint]?
    @State private var roughContour: [CGPoint]?
    @State private var subjectImage: NSImage?
    @State private var didUseDetectedContour = false
    @State private var contourPaddingPixels = AppDefaults.contourPaddingPixels
    @State private var previewCutoutImage: NSImage?
    @State private var memoPreviewConfiguration = MemoPreviewConfiguration()
    @State private var isShowingMemoPreview = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)

            ZStack {
                Color(nsColor: .textBackgroundColor)

                if let memoImage {
                    GeometryReader { proxy in
                        let imageRect = aspectFitRect(
                            imageSize: memoImage.size,
                            containerSize: proxy.size
                        )

                        ZStack {
                            let paddedContour = effectiveContour(for: memoImage)
                            let maskContour = effectiveMaskContour(for: memoImage)
                            let displayImage = previewCutoutImage ?? memoImage

                            memoPaperLayer(image: displayImage, imageRect: imageRect, contour: maskContour)

                            if isTracingContour {
                                tracingLayer(imageRect: imageRect)
                            } else if let paddedContour {
                                NormalizedContourShape(points: paddedContour, imageRect: imageRect)
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                            } else if let roughContour {
                                NormalizedContourShape(points: roughContour, imageRect: imageRect)
                                    .stroke(.gray.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(isTracingContour ? traceGesture(in: imageRect) : nil)
                    }
                    .padding(22)
                } else {
                    emptyState
                }

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10, 8]))
                        .padding(24)
                }
            }
            .onDrop(
                of: [.fileURL, .image],
                isTargeted: $isDropTargeted,
                perform: loadDroppedItems
            )
        }
        .frame(minWidth: 420, minHeight: 560)
        .onChange(of: contourPaddingPixels) { _, _ in
            refreshPreviewCutout()
        }
        .sheet(isPresented: $isShowingMemoPreview) {
            if let memoImage, let appliedContour {
                MemoCreationPreviewSheet(
                    image: memoImage,
                    baseContour: appliedContour,
                    basePaddingPixels: contourPaddingPixels,
                    opacity: paperOpacity,
                    brightness: paperBrightness,
                    text: memoText,
                    configuration: $memoPreviewConfiguration,
                    onCancel: {
                        isShowingMemoPreview = false
                    },
                    onCreate: { configuration in
                        isShowingMemoPreview = false
                        openCutoutWindow(configuration: configuration)
                    }
                )
            }
        }
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    selectImage()
                } label: {
                    Label("画像を選択", systemImage: "photo")
                }

                Button {
                    memoText = ""
                } label: {
                    Label("本文クリア", systemImage: "eraser")
                }
                .disabled(memoText.isEmpty)

                Button {
                    toggleTracing()
                } label: {
                    Label(isTracingContour ? "なぞり終了" : "輪郭をなぞる", systemImage: "lasso")
                }
                .disabled(memoImage == nil)

                Button {
                    applyTrace()
                } label: {
                    Label("被写体抽出", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(tracePoints.count < 3)

                Button {
                    resetContour()
                } label: {
                    Label("輪郭リセット", systemImage: "arrow.counterclockwise")
                }
                .disabled(tracePoints.isEmpty && appliedContour == nil)

                Button {
                    isShowingMemoPreview = true
                } label: {
                    Label("メモ化", systemImage: "macwindow")
                }
                .disabled(memoImage == nil || appliedContour == nil)

                Divider()
                    .frame(height: 24)

                controlSlider(
                    title: "薄さ",
                    value: $paperOpacity,
                    range: 0.2...1.0,
                    icon: "circle.lefthalf.filled"
                )

                controlSlider(
                    title: "明度",
                    value: $paperBrightness,
                    range: -0.15...0.45,
                    icon: "sun.max"
                )

                paddingSlider
            }
        }
    }

    private var paddingSlider: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .frame(width: 18)

            Text("余白")
                .font(.system(size: 12, weight: .medium))

            Slider(value: $contourPaddingPixels, in: 0...80, step: 1)
                .frame(width: 110)

            Text("\(Int(contourPaddingPixels.rounded()))px")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func memoPaperLayer(image: NSImage, imageRect: CGRect, contour: [CGPoint]?) -> some View {
        ZStack {
            Color.white

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .brightness(paperBrightness)
                .opacity(paperOpacity)
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)

            TextEditor(text: $memoText)
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 86)
                .padding(.vertical, 118)
                .background(Color.clear)
                .disabled(isTracingContour)
        }
        .frame(width: imageRect.width, height: imageRect.height)
        .position(x: imageRect.midX, y: imageRect.midY)
        .mask {
            if let contour {
                LocalNormalizedContourShape(points: contour)
            } else {
                Rectangle()
            }
        }
    }

    private func tracingLayer(imageRect: CGRect) -> some View {
        ZStack {
            Color.black.opacity(0.06)
                .frame(width: imageRect.width, height: imageRect.height)
                .position(x: imageRect.midX, y: imageRect.midY)

            if tracePoints.count > 1 {
                NormalizedContourShape(points: tracePoints, imageRect: imageRect, closesPath: false)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            ForEach(Array(tracePoints.enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(.blue)
                    .frame(width: 7, height: 7)
                    .position(denormalize(point, in: imageRect))
            }

            VStack(spacing: 6) {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 24, weight: .semibold))

                Text("画像上でメモの外周をドラッグ")
                    .font(.system(size: 14, weight: .semibold))

                Text("囲めたら「被写体抽出」を押します")
                    .font(.system(size: 12))
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .position(x: imageRect.midX, y: imageRect.minY + 62)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)

            Text("画像を選択、またはここにドラッグ")
                .font(.system(size: 18, weight: .semibold))

            Text("読み取ったメモ用紙の写真を背景として使えます")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func controlSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        icon: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Slider(value: value, in: range)
                .frame(width: 110)
        }
    }

    private func selectImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        loadImage(from: url)
    }

    private func loadDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard
                    let data = item as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }

                DispatchQueue.main.async {
                    loadImage(from: url)
                }
            }

            return true
        }

        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else {
                    return
                }

                DispatchQueue.main.async {
                    memoImage = image
                    resetContour()
                }
            }

            return true
        }

        return false
    }

    private func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            return
        }

        memoImage = image
        resetContour()
    }

    private func toggleTracing() {
        isTracingContour.toggle()

        if isTracingContour {
            tracePoints = []
            didUseDetectedContour = false
        }
    }

    private func applyTrace() {
        guard let memoImage, tracePoints.count >= 3 else {
            return
        }

        roughContour = tracePoints
        let candidates = contourCandidates(in: memoImage, guide: tracePoints)

        if let selected = ContourCandidateSelector.bestCandidate(from: candidates, guide: tracePoints) {
            appliedContour = selected.smoothsContour ? ContourSmoother.polished(selected.contour) : selected.contour
            didUseDetectedContour = true
            subjectImage = nil
            refreshPreviewCutout()
        } else {
            appliedContour = ContourSmoother.polished(ContourSmoother.densify(tracePoints))
            didUseDetectedContour = false
            subjectImage = nil
            refreshPreviewCutout()
        }
        isTracingContour = false
    }

    private func contourCandidates(in image: NSImage, guide: [CGPoint]) -> [ContourCandidate] {
        var candidates: [ContourCandidate] = []

        if let extraction = SubjectMaskExtractor.extractSubject(in: image, guidedBy: guide) {
            candidates.append(
                ContourCandidate(
                    contour: extraction.contour,
                    source: .subjectMask,
                    minimumAreaRatio: AppDefaults.minimumDetectionAreaRatio,
                    smoothsContour: true
                )
            )
        }

        if let contour = PreprocessedContourExtractor.detectContour(in: image, guidedBy: guide) {
            candidates.append(
                ContourCandidate(
                    contour: contour,
                    source: .preprocessedContour,
                    minimumAreaRatio: AppDefaults.minimumDetectionAreaRatio,
                    smoothsContour: true
                )
            )
        }

        if let guidedContour = GuidedBackgroundContourExtractor.detectContour(in: image, guidedBy: guide) {
            candidates.append(
                ContourCandidate(
                    contour: guidedContour,
                    source: .backgroundDifference,
                    minimumAreaRatio: AppDefaults.guidedContourMinimumAreaRatio,
                    smoothsContour: true
                )
            )
        }

        if let coloredRectangle = ColoredPaperRectangleExtractor.detectContour(in: image, guidedBy: guide) {
            candidates.append(
                ContourCandidate(
                    contour: coloredRectangle,
                    source: .coloredRectangle,
                    minimumAreaRatio: AppDefaults.guidedContourMinimumAreaRatio,
                    smoothsContour: false
                )
            )
        }

        if let rectangularContour = RectangularGuideContour.detectContour(from: guide) {
            candidates.append(
                ContourCandidate(
                    contour: rectangularContour,
                    source: .rectangularGuide,
                    minimumAreaRatio: AppDefaults.guidedContourMinimumAreaRatio,
                    smoothsContour: false
                )
            )
        }

        if let contour = ContourDetector.detectContour(in: image, guidedBy: guide) {
            candidates.append(
                ContourCandidate(
                    contour: contour,
                    source: .rawVisionContour,
                    minimumAreaRatio: AppDefaults.minimumDetectionAreaRatio,
                    smoothsContour: true
                )
            )
        }

        return candidates
    }

    private func applyDetectedContour(
        _ contour: [CGPoint]?,
        fallback: [CGPoint],
        minimumAreaRatio: CGFloat = AppDefaults.minimumDetectionAreaRatio
    ) {
        guard
            let contour,
            ContourQualityValidator.isAcceptable(contour, guide: fallback, minimumAreaRatio: minimumAreaRatio)
        else {
            appliedContour = ContourSmoother.polished(ContourSmoother.densify(fallback))
            didUseDetectedContour = false
            subjectImage = nil
            return
        }

        appliedContour = ContourSmoother.polished(contour)
        didUseDetectedContour = true
        subjectImage = nil
        refreshPreviewCutout()
    }

    private func openCutoutWindow(configuration: MemoPreviewConfiguration = MemoPreviewConfiguration()) {
        guard let memoImage, let appliedContour else {
            return
        }
        let adjustedPadding = contourPaddingPixels
            + configuration.contourAdjustmentPixels
            - AppDefaults.contourMaskInsetPixels
        let maskContour = ContourPadding.expanded(
            appliedContour,
            imageSize: memoImage.size,
            paddingPixels: adjustedPadding
        )
        let bounds = normalizedBounds(for: maskContour)
        let cutoutImage = CutoutImageRenderer.renderCrop(
            image: memoImage,
            bounds: bounds,
            opacity: paperOpacity,
            brightness: paperBrightness
        ) ?? memoImage

        CutoutWindowManager.shared.openWindow(
            image: cutoutImage,
            contour: maskContour,
            bounds: bounds,
            text: memoText,
            opacity: paperOpacity,
            contourBlurRadius: configuration.contourBlurRadius,
            textArea: configuration.usesManualTextArea ? configuration.textArea : nil
        )
    }

    private func resetContour() {
        tracePoints = []
        appliedContour = nil
        roughContour = nil
        subjectImage = nil
        previewCutoutImage = nil
        didUseDetectedContour = false
        isTracingContour = false
    }

    private func traceGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageRect.contains(value.location) else {
                    return
                }

                let point = normalize(value.location, in: imageRect)
                guard shouldAppendTracePoint(point) else {
                    return
                }

                tracePoints.append(point)
            }
    }

    private func shouldAppendTracePoint(_ point: CGPoint) -> Bool {
        guard let lastPoint = tracePoints.last else {
            return true
        }

        let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        return distance > 0.006
    }

    private func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2
        )

        return CGRect(origin: origin, size: size)
    }

    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: max(0, min(1, (point.x - rect.minX) / rect.width)),
            y: max(0, min(1, (point.y - rect.minY) / rect.height))
        )
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }

    private func effectiveContour(for image: NSImage) -> [CGPoint]? {
        guard let appliedContour else {
            return nil
        }

        return ContourPadding.expanded(
            appliedContour,
            imageSize: image.size,
            paddingPixels: contourPaddingPixels
        )
    }

    private func effectiveMaskContour(for image: NSImage) -> [CGPoint]? {
        guard let appliedContour else {
            return nil
        }

        return ContourPadding.expanded(
            appliedContour,
            imageSize: image.size,
            paddingPixels: contourPaddingPixels - AppDefaults.contourMaskInsetPixels
        )
    }

    private func refreshPreviewCutout() {
        guard let memoImage, let maskContour = effectiveMaskContour(for: memoImage) else {
            previewCutoutImage = nil
            return
        }

        previewCutoutImage = CutoutImageRenderer.renderFullSizeMask(
            image: memoImage,
            contour: maskContour,
            opacity: 1,
            brightness: 0
        )
    }

    private func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        )
    }
}

enum CutoutImageRenderer {
    static func renderCrop(
        image: NSImage,
        bounds: CGRect,
        opacity: Double,
        brightness: Double
    ) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let imageSize = image.size
        let outputSize = NSSize(
            width: max(1, bounds.width * imageSize.width),
            height: max(1, bounds.height * imageSize.height)
        )
        let outputImage = NSImage(size: outputSize)

        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        let outputRect = NSRect(origin: .zero, size: outputSize)
        let sourceRect = NSRect(
            x: bounds.minX * imageSize.width,
            y: (1 - bounds.maxY) * imageSize.height,
            width: bounds.width * imageSize.width,
            height: bounds.height * imageSize.height
        )

        image.draw(
            in: outputRect,
            from: sourceRect,
            operation: .sourceOver,
            fraction: max(0, min(1, opacity))
        )

        if brightness != 0 {
            let alpha = min(0.45, abs(brightness))
            (brightness > 0 ? NSColor.white : NSColor.black)
                .withAlphaComponent(alpha)
                .setFill()
            outputRect.fill()
        }

        return outputImage
    }

    static func renderFullSizeMask(
        image: NSImage,
        contour: [CGPoint],
        opacity: Double,
        brightness: Double
    ) -> NSImage? {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let outputImage = NSImage(size: imageSize)

        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return nil
        }

        let outputRect = NSRect(origin: .zero, size: imageSize)
        context.clear(outputRect)
        context.saveGState()
        context.addPath(cgPath(for: contour, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), size: imageSize))
        context.clip()

        image.draw(
            in: outputRect,
            from: NSRect(origin: .zero, size: imageSize),
            operation: .sourceOver,
            fraction: max(0, min(1, opacity))
        )

        if brightness != 0 {
            let alpha = min(0.45, abs(brightness))
            (brightness > 0 ? NSColor.white : NSColor.black)
                .withAlphaComponent(alpha)
                .setFill()
            outputRect.fill()
        }

        context.restoreGState()

        return outputImage
    }

    static func render(
        image: NSImage,
        contour: [CGPoint],
        bounds: CGRect,
        opacity: Double,
        brightness: Double
    ) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let imageSize = image.size
        let outputSize = NSSize(
            width: max(1, bounds.width * imageSize.width),
            height: max(1, bounds.height * imageSize.height)
        )
        let outputImage = NSImage(size: outputSize)

        outputImage.lockFocus()
        defer { outputImage.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return nil
        }

        context.saveGState()
        context.addPath(cgPath(for: contour, bounds: bounds, size: outputSize))
        context.clip()

        NSColor.white.setFill()
        NSRect(origin: .zero, size: outputSize).fill()

        let sourceRect = NSRect(
            x: bounds.minX * imageSize.width,
            y: (1 - bounds.maxY) * imageSize.height,
            width: bounds.width * imageSize.width,
            height: bounds.height * imageSize.height
        )
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1
        )

        if brightness != 0 {
            let alpha = min(0.45, abs(brightness))
            (brightness > 0 ? NSColor.white : NSColor.black)
                .withAlphaComponent(alpha)
                .setFill()
            NSRect(origin: .zero, size: outputSize).fill()
        }

        NSColor.white
            .withAlphaComponent(max(0, min(1, 1 - opacity)))
            .setFill()
        NSRect(origin: .zero, size: outputSize).fill()

        context.restoreGState()

        return outputImage
    }

    private static func cgPath(for contour: [CGPoint], bounds: CGRect, size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let localPoints = contour.map { point in
            CGPoint(
                x: (point.x - bounds.minX) / bounds.width * size.width,
                y: (1 - (point.y - bounds.minY) / bounds.height) * size.height
            )
        }

        guard let firstPoint = localPoints.first else {
            return path
        }

        path.move(to: firstPoint)

        for point in localPoints.dropFirst() {
            path.addLine(to: point)
        }

        path.closeSubpath()
        return path
    }
}

struct NormalizedContourShape: Shape {
    let points: [CGPoint]
    let imageRect: CGRect
    var closesPath = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let firstPoint = points.first else {
            return path
        }

        path.move(to: denormalize(firstPoint))

        for point in points.dropFirst() {
            path.addLine(to: denormalize(point))
        }

        if closesPath {
            path.closeSubpath()
        }

        return path
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }
}

struct LocalNormalizedContourShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let firstPoint = points.first else {
            return path
        }

        path.move(to: denormalize(firstPoint, in: rect))

        for point in points.dropFirst() {
            path.addLine(to: denormalize(point, in: rect))
        }

        path.closeSubpath()
        return path
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }
}

enum ContourPadding {
    static func expanded(
        _ points: [CGPoint],
        imageSize: CGSize,
        paddingPixels: CGFloat
    ) -> [CGPoint] {
        guard points.count >= 3, paddingPixels != 0, imageSize.width > 0, imageSize.height > 0 else {
            return points
        }

        if RectangularGuideContour.isRectangleLikeContour(points) {
            let normalizedDX = paddingPixels / imageSize.width
            let normalizedDY = paddingPixels / imageSize.height
            return RectangularGuideContour.rectangularContour(
                for: normalizedBounds(for: points).insetBy(dx: -normalizedDX, dy: -normalizedDY).clampedToUnit()
            )
        }

        let pixelPoints = points.map { point in
            CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
        }
        let center = centroid(of: pixelPoints)

        return pixelPoints.map { point in
            let vector = CGPoint(x: point.x - center.x, y: point.y - center.y)
            let length = max(0.001, hypot(vector.x, vector.y))
            let expandedPoint = CGPoint(
                x: point.x + vector.x / length * paddingPixels,
                y: point.y + vector.y / length * paddingPixels
            )

            return CGPoint(
                x: expandedPoint.x / imageSize.width,
                y: expandedPoint.y / imageSize.height
            )
        }
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else {
            return .zero
        }

        let sum = points.reduce(CGPoint.zero) { partialResult, point in
            CGPoint(x: partialResult.x + point.x, y: partialResult.y + point.y)
        }

        return CGPoint(
            x: sum.x / CGFloat(points.count),
            y: sum.y / CGFloat(points.count)
        )
    }

    private static func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }
}

enum RectangularGuideContour {
    static func detectContour(from guide: [CGPoint]) -> [CGPoint]? {
        guard AppDefaults.preferRectangularGuideContour, isRectangleLikeGuide(guide) else {
            return nil
        }

        return rectangularContour(for: bounds(for: guide))
    }

    static func isRectangleLikeContour(_ points: [CGPoint]) -> Bool {
        guard points.count >= 8 else {
            return false
        }

        let pointCount = AppDefaults.rectangularContourPointsPerSide
        guard points.count >= pointCount * 4 - 4 else {
            return false
        }

        let bounds = bounds(for: points)
        guard bounds.width > 0.01, bounds.height > 0.01 else {
            return false
        }

        let tolerance = max(0.003, min(bounds.width, bounds.height) * 0.025)
        let nearSides = points.filter { point in
            abs(point.x - bounds.minX) <= tolerance
                || abs(point.x - bounds.maxX) <= tolerance
                || abs(point.y - bounds.minY) <= tolerance
                || abs(point.y - bounds.maxY) <= tolerance
        }

        return CGFloat(nearSides.count) / CGFloat(points.count) > 0.9
    }

    static func rectangularContour(for rect: CGRect) -> [CGPoint] {
        let rect = rect.clampedToUnit()
        let segments = max(2, AppDefaults.rectangularContourPointsPerSide)
        var points: [CGPoint] = []

        appendLine(
            from: CGPoint(x: rect.minX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.minY),
            segments: segments,
            to: &points
        )
        appendLine(
            from: CGPoint(x: rect.maxX, y: rect.minY),
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            segments: segments,
            to: &points
        )
        appendLine(
            from: CGPoint(x: rect.maxX, y: rect.maxY),
            to: CGPoint(x: rect.minX, y: rect.maxY),
            segments: segments,
            to: &points
        )
        appendLine(
            from: CGPoint(x: rect.minX, y: rect.maxY),
            to: CGPoint(x: rect.minX, y: rect.minY),
            segments: segments,
            to: &points
        )

        return points
    }

    static func isRectangleLikeGuide(_ guide: [CGPoint]) -> Bool {
        guard guide.count >= 4 else {
            return false
        }

        let guideBounds = bounds(for: guide)
        guard guideBounds.width > 0.04, guideBounds.height > 0.04 else {
            return false
        }

        let boundsArea = guideBounds.width * guideBounds.height
        let fillRatio = polygonArea(guide) / max(0.0001, boundsArea)
        guard fillRatio >= AppDefaults.rectangularGuideFillRatio else {
            return false
        }

        if guide.count <= 12 {
            return true
        }

        let tolerance = max(0.012, min(guideBounds.width, guideBounds.height) * 0.09)
        let topCoverage = sideCoverage(
            guide.filter { abs($0.y - guideBounds.minY) <= tolerance }.map(\.x),
            span: guideBounds.width
        )
        let bottomCoverage = sideCoverage(
            guide.filter { abs($0.y - guideBounds.maxY) <= tolerance }.map(\.x),
            span: guideBounds.width
        )
        let leftCoverage = sideCoverage(
            guide.filter { abs($0.x - guideBounds.minX) <= tolerance }.map(\.y),
            span: guideBounds.height
        )
        let rightCoverage = sideCoverage(
            guide.filter { abs($0.x - guideBounds.maxX) <= tolerance }.map(\.y),
            span: guideBounds.height
        )
        let minimumCoverage = AppDefaults.rectangularGuideSideCoverage

        return topCoverage >= minimumCoverage
            && bottomCoverage >= minimumCoverage
            && leftCoverage >= minimumCoverage
            && rightCoverage >= minimumCoverage
    }

    private static func appendLine(
        from start: CGPoint,
        to end: CGPoint,
        segments: Int,
        to points: inout [CGPoint]
    ) {
        for index in 0..<segments {
            let t = CGFloat(index) / CGFloat(segments)
            points.append(
                CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
            )
        }
    }

    private static func sideCoverage(_ values: [CGFloat], span: CGFloat) -> CGFloat {
        guard let minValue = values.min(), let maxValue = values.max(), span > 0 else {
            return 0
        }

        return (maxValue - minValue) / span
    }

    private static func bounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else {
            return 0
        }

        var area: CGFloat = 0

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }

        return abs(area / 2)
    }
}

enum ColoredPaperRectangleExtractor {
    static func detectContour(in image: NSImage, guidedBy guide: [CGPoint]) -> [CGPoint]? {
        guard
            AppDefaults.preferColoredRectangleInRectangularGuide,
            RectangularGuideContour.isRectangleLikeGuide(guide),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else {
            return nil
        }

        let guideBounds = normalizedBounds(for: guide).insetBy(dx: -0.02, dy: -0.02).clampedToUnit()
        let scanRect = pixelRect(for: guideBounds, width: width, height: height)
        guard scanRect.width > 8, scanRect.height > 8 else {
            return nil
        }

        let sampleStep = max(1, min(width, height) / 700)
        var rowCounts: [Int: Int] = [:]
        var columnCounts: [Int: Int] = [:]
        var sampledRows = Set<Int>()
        var sampledColumns = Set<Int>()
        var coloredPixelCount = 0

        for y in stride(from: Int(scanRect.minY), to: Int(scanRect.maxY), by: sampleStep) {
            sampledRows.insert(y)

            for x in stride(from: Int(scanRect.minX), to: Int(scanRect.maxX), by: sampleStep) {
                sampledColumns.insert(x)

                guard isColoredPaperPixel(bitmap: bitmap, x: x, y: y) else {
                    continue
                }

                rowCounts[y, default: 0] += 1
                columnCounts[x, default: 0] += 1
                coloredPixelCount += 1
            }
        }

        let totalSamples = max(1, sampledRows.count * sampledColumns.count)
        let fillRatio = CGFloat(coloredPixelCount) / CGFloat(totalSamples)
        guard fillRatio >= AppDefaults.coloredRectangleMinimumFillRatio else {
            return nil
        }

        let minimumRowCount = max(2, Int(CGFloat(sampledColumns.count) * 0.12))
        let minimumColumnCount = max(2, Int(CGFloat(sampledRows.count) * 0.12))
        let acceptedRows = rowCounts.filter { $0.value >= minimumRowCount }.map(\.key)
        let acceptedColumns = columnCounts.filter { $0.value >= minimumColumnCount }.map(\.key)

        guard
            let minX = acceptedColumns.min(),
            let maxX = acceptedColumns.max(),
            let minY = acceptedRows.min(),
            let maxY = acceptedRows.max()
        else {
            return nil
        }

        let normalizedRect = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + sampleStep) / CGFloat(width),
            height: CGFloat(maxY - minY + sampleStep) / CGFloat(height)
        ).clampedToUnit()

        let sideRatio = min(
            normalizedRect.width / max(0.0001, guideBounds.width),
            normalizedRect.height / max(0.0001, guideBounds.height)
        )
        guard sideRatio >= AppDefaults.coloredRectangleMinimumSideRatio else {
            return nil
        }

        return RectangularGuideContour.rectangularContour(for: normalizedRect)
    }

    private static func isColoredPaperPixel(bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return false
        }

        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let saturation = maximum - minimum
        let darkness = 255 - maximum
        let isNearWhite = red >= AppDefaults.coloredRectangleWhiteThreshold
            && green >= AppDefaults.coloredRectangleWhiteThreshold
            && blue >= AppDefaults.coloredRectangleWhiteThreshold

        return !isNearWhite
            && (saturation >= AppDefaults.coloredRectangleSaturationThreshold
                || darkness >= AppDefaults.coloredRectangleDarkThreshold)
    }

    private static func pixelRect(for normalizedRect: CGRect, width: Int, height: Int) -> CGRect {
        let minX = max(0, Int(floor(normalizedRect.minX * CGFloat(width))))
        let maxX = min(width, Int(ceil(normalizedRect.maxX * CGFloat(width))))
        let minY = max(0, Int(floor(normalizedRect.minY * CGFloat(height))))
        let maxY = min(height, Int(ceil(normalizedRect.maxY * CGFloat(height))))

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }
}

struct ContourCandidate {
    let contour: [CGPoint]
    let source: ContourCandidateSource
    let minimumAreaRatio: CGFloat
    let smoothsContour: Bool
}

enum ContourCandidateSource {
    case subjectMask
    case preprocessedContour
    case backgroundDifference
    case coloredRectangle
    case rectangularGuide
    case rawVisionContour

    var bias: CGFloat {
        switch self {
        case .subjectMask:
            return 0.55
        case .preprocessedContour:
            return 0.24
        case .rawVisionContour:
            return 0.12
        case .backgroundDifference:
            return 0
        case .coloredRectangle:
            return -0.04
        case .rectangularGuide:
            return -0.18
        }
    }
}

enum ContourCandidateSelector {
    static func bestCandidate(from candidates: [ContourCandidate], guide: [CGPoint]) -> ContourCandidate? {
        candidates
            .compactMap { candidate -> (candidate: ContourCandidate, score: CGFloat)? in
                guard let score = score(candidate, guide: guide) else {
                    return nil
                }

                return (candidate, score)
            }
            .filter { $0.score >= CGFloat(AppDefaults.minimumAutoCandidateScore) }
            .max { first, second in first.score < second.score }?
            .candidate
    }

    private static func score(_ candidate: ContourCandidate, guide: [CGPoint]) -> CGFloat? {
        guard candidate.contour.count >= 8, guide.count >= 3 else {
            return nil
        }

        let contourBounds = bounds(for: candidate.contour)
        let guideBounds = bounds(for: guide)
        let guideArea = max(0.0001, polygonArea(guide))
        let contourArea = polygonArea(candidate.contour)
        let areaRatio = contourArea / guideArea
        let guideDiagonal = max(0.0001, hypot(guideBounds.width, guideBounds.height))
        let centerDistance = distance(center(of: contourBounds), center(of: guideBounds)) / guideDiagonal
        let overlap = overlapRatio(contourBounds, with: guideBounds)
        let inside = insideRatio(candidate.contour, guide: guide)

        guard
            overlap >= AppDefaults.minimumDetectionGuideOverlap,
            inside >= 0.58,
            areaRatio >= candidate.minimumAreaRatio,
            areaRatio <= 1.48,
            centerDistance <= 0.28
        else {
            return nil
        }

        let centerScore = max(0, 1 - centerDistance / 0.28)
        let areaScore = areaFitScore(areaRatio)
        let compactnessPenalty = compactnessPenalty(for: candidate, contourArea: contourArea, contourBounds: contourBounds)

        return overlap * 0.95
            + inside * 0.75
            + centerScore * 0.55
            + areaScore * 0.55
            + candidate.source.bias
            - compactnessPenalty
    }

    private static func areaFitScore(_ areaRatio: CGFloat) -> CGFloat {
        if areaRatio < 0.35 {
            return max(0, areaRatio / 0.35)
        }

        if areaRatio > 1.0 {
            return max(0, 1 - (areaRatio - 1.0) / 0.48)
        }

        return 1
    }

    private static func compactnessPenalty(
        for candidate: ContourCandidate,
        contourArea: CGFloat,
        contourBounds: CGRect
    ) -> CGFloat {
        guard candidate.source == .backgroundDifference else {
            return 0
        }

        let boundsArea = max(0.0001, contourBounds.width * contourBounds.height)
        let fillRatio = contourArea / boundsArea

        if fillRatio > 0.78 {
            return 0.18
        }

        return 0
    }

    private static func bounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else {
            return 0
        }

        var area: CGFloat = 0

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }

        return abs(area / 2)
    }

    private static func overlapRatio(_ rect: CGRect, with otherRect: CGRect) -> CGFloat {
        let intersection = rect.intersection(otherRect)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else {
            return 0
        }

        return intersection.width * intersection.height / (rect.width * rect.height)
    }

    private static func insideRatio(_ points: [CGPoint], guide: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else {
            return 0
        }

        let insideCount = points.filter { contains($0, in: guide) }.count
        return CGFloat(insideCount) / CGFloat(points.count)
    }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var isInside = false
        var previousIndex = polygon.count - 1

        for currentIndex in polygon.indices {
            let current = polygon[currentIndex]
            let previous = polygon[previousIndex]
            let intersects = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x

            if intersects {
                isInside.toggle()
            }

            previousIndex = currentIndex
        }

        return isInside
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}

enum GuidedBackgroundContourExtractor {
    static func detectContour(in image: NSImage, guidedBy guide: [CGPoint]) -> [CGPoint]? {
        guard
            AppDefaults.preferGuidedBackgroundContour,
            guide.count >= 3,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else {
            return nil
        }

        let guideBounds = normalizedBounds(for: guide).insetBy(dx: -0.035, dy: -0.035).clampedToUnit()
        let scanRect = pixelRect(for: guideBounds, width: width, height: height)
        guard scanRect.width > 8, scanRect.height > 8 else {
            return nil
        }

        let sampleStep = max(1, min(width, height) / 650)
        guard let background = estimateBackgroundColor(
            bitmap: bitmap,
            guide: guide,
            scanRect: scanRect,
            width: width,
            height: height,
            step: sampleStep
        ) else {
            return nil
        }

        guard let foregroundBounds = foregroundBounds(
            bitmap: bitmap,
            background: background,
            guide: guide,
            scanRect: scanRect,
            width: width,
            height: height,
            step: sampleStep
        ) else {
            return nil
        }

        let center = CGPoint(x: foregroundBounds.midX, y: foregroundBounds.midY)
        let rays = max(32, AppDefaults.guidedContourRayCount)
        var contour: [CGPoint] = []

        for rayIndex in 0..<rays {
            let angle = CGFloat(rayIndex) / CGFloat(rays) * 2 * .pi
            if let point = edgePoint(
                bitmap: bitmap,
                background: background,
                center: center,
                angle: angle,
                guide: guide,
                scanBounds: guideBounds,
                width: width,
                height: height
            ) {
                contour.append(point)
            }
        }

        let minimumPoints = Int(CGFloat(rays) * AppDefaults.guidedContourMinimumPointRatio)
        guard contour.count >= minimumPoints else {
            return nil
        }

        let simplified = simplify(contour, minimumDistance: 0.006)
        guard simplified.count >= 8 else {
            return nil
        }

        return ContourSmoother.densify(simplified, maxSegmentLength: 0.014)
    }

    private static func edgePoint(
        bitmap: NSBitmapImageRep,
        background: RGBColor,
        center: CGPoint,
        angle: CGFloat,
        guide: [CGPoint],
        scanBounds: CGRect,
        width: Int,
        height: Int
    ) -> CGPoint? {
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let maxRadius = max(scanBounds.width, scanBounds.height) * 0.85
        var lastForegroundPoint: CGPoint?

        for stepIndex in 0...260 {
            let radius = CGFloat(stepIndex) / 260 * maxRadius
            let point = CGPoint(
                x: center.x + direction.x * radius,
                y: center.y + direction.y * radius
            )

            guard scanBounds.contains(point), contains(point, in: guide) else {
                if lastForegroundPoint != nil {
                    break
                }
                continue
            }

            let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
            let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))

            if isForegroundPixel(bitmap: bitmap, x: x, y: y, background: background) {
                lastForegroundPoint = point
            }
        }

        return lastForegroundPoint
    }

    private static func foregroundBounds(
        bitmap: NSBitmapImageRep,
        background: RGBColor,
        guide: [CGPoint],
        scanRect: CGRect,
        width: Int,
        height: Int,
        step: Int
    ) -> CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        var foregroundCount = 0

        for y in stride(from: Int(scanRect.minY), to: Int(scanRect.maxY), by: step) {
            for x in stride(from: Int(scanRect.minX), to: Int(scanRect.maxX), by: step) {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )

                guard contains(point, in: guide),
                      isForegroundPixel(bitmap: bitmap, x: x, y: y, background: background)
                else {
                    continue
                }

                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
                foregroundCount += 1
            }
        }

        guard foregroundCount >= 24, minX.isFinite, minY.isFinite else {
            return nil
        }

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }

    private static func estimateBackgroundColor(
        bitmap: NSBitmapImageRep,
        guide: [CGPoint],
        scanRect: CGRect,
        width: Int,
        height: Int,
        step: Int
    ) -> RGBColor? {
        var samples: [RGBColor] = []

        for y in stride(from: Int(scanRect.minY), to: Int(scanRect.maxY), by: step) {
            for x in stride(from: Int(scanRect.minX), to: Int(scanRect.maxX), by: step) {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )

                guard !contains(point, in: guide),
                      let color = rgbColor(bitmap: bitmap, x: x, y: y)
                else {
                    continue
                }

                samples.append(color)
            }
        }

        if samples.count < 12 {
            samples = borderSamples(bitmap: bitmap, scanRect: scanRect, step: step)
        }

        guard !samples.isEmpty else {
            return nil
        }

        samples.sort { $0.luminance > $1.luminance }
        return averageColor(Array(samples.prefix(max(1, samples.count / 2))))
    }

    private static func borderSamples(bitmap: NSBitmapImageRep, scanRect: CGRect, step: Int) -> [RGBColor] {
        var samples: [RGBColor] = []
        let minX = Int(scanRect.minX)
        let maxX = max(minX, Int(scanRect.maxX) - 1)
        let minY = Int(scanRect.minY)
        let maxY = max(minY, Int(scanRect.maxY) - 1)

        for x in stride(from: minX, through: maxX, by: step) {
            if let top = rgbColor(bitmap: bitmap, x: x, y: minY) {
                samples.append(top)
            }
            if let bottom = rgbColor(bitmap: bitmap, x: x, y: maxY) {
                samples.append(bottom)
            }
        }

        for y in stride(from: minY, through: maxY, by: step) {
            if let left = rgbColor(bitmap: bitmap, x: minX, y: y) {
                samples.append(left)
            }
            if let right = rgbColor(bitmap: bitmap, x: maxX, y: y) {
                samples.append(right)
            }
        }

        return samples
    }

    private static func isForegroundPixel(
        bitmap: NSBitmapImageRep,
        x: Int,
        y: Int,
        background: RGBColor
    ) -> Bool {
        guard let color = rgbColor(bitmap: bitmap, x: x, y: y) else {
            return false
        }

        let distance = color.distance(to: background)
        let darknessDelta = background.luminance - color.luminance

        return distance >= CGFloat(AppDefaults.guidedForegroundBackgroundDistance)
            || darknessDelta >= CGFloat(AppDefaults.guidedForegroundMinimumDarknessDelta)
    }

    private static func averageColor(_ colors: [RGBColor]) -> RGBColor? {
        guard !colors.isEmpty else {
            return nil
        }

        let total = colors.reduce(RGBColor.zero) { partialResult, color in
            RGBColor(
                red: partialResult.red + color.red,
                green: partialResult.green + color.green,
                blue: partialResult.blue + color.blue
            )
        }
        let count = CGFloat(colors.count)

        return RGBColor(red: total.red / count, green: total.green / count, blue: total.blue / count)
    }

    private static func rgbColor(bitmap: NSBitmapImageRep, x: Int, y: Int) -> RGBColor? {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return nil
        }

        return RGBColor(
            red: color.redComponent * 255,
            green: color.greenComponent * 255,
            blue: color.blueComponent * 255
        )
    }

    private static func pixelRect(for normalizedRect: CGRect, width: Int, height: Int) -> CGRect {
        let minX = max(0, Int(floor(normalizedRect.minX * CGFloat(width))))
        let maxX = min(width, Int(ceil(normalizedRect.maxX * CGFloat(width))))
        let minY = max(0, Int(floor(normalizedRect.minY * CGFloat(height))))
        let maxY = min(height, Int(ceil(normalizedRect.maxY * CGFloat(height))))

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private static func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }

    private static func simplify(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        var simplified: [CGPoint] = []

        for point in points {
            guard let lastPoint = simplified.last else {
                simplified.append(point)
                continue
            }

            if hypot(point.x - lastPoint.x, point.y - lastPoint.y) >= minimumDistance {
                simplified.append(point)
            }
        }

        return simplified
    }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var isInside = false
        var previousIndex = polygon.count - 1

        for currentIndex in polygon.indices {
            let current = polygon[currentIndex]
            let previous = polygon[previousIndex]
            let intersects = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x

            if intersects {
                isInside.toggle()
            }

            previousIndex = currentIndex
        }

        return isInside
    }
}

struct RGBColor {
    static let zero = RGBColor(red: 0, green: 0, blue: 0)

    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var luminance: CGFloat {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    func distance(to other: RGBColor) -> CGFloat {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue

        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }
}

enum ContourSmoother {
    static func polished(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 8 else {
            return points
        }

        let cleaned = removeSpikes(from: densify(points, maxSegmentLength: 0.012))
        let straightened = straightenLineRuns(cleaned)
        let rounded = roundCorners(straightened)

        return smooth(rounded)
    }

    static func densify(_ points: [CGPoint], maxSegmentLength: CGFloat = 0.018) -> [CGPoint] {
        guard points.count >= 2 else {
            return points
        }

        var result: [CGPoint] = []

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let distance = hypot(next.x - current.x, next.y - current.y)
            let steps = max(1, Int(ceil(distance / maxSegmentLength)))

            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(
                    CGPoint(
                        x: current.x + (next.x - current.x) * t,
                        y: current.y + (next.y - current.y) * t
                    )
                )
            }
        }

        return result
    }

    private static func removeSpikes(from points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 8, AppDefaults.contourSpikeRemovalIterations > 0 else {
            return points
        }

        var result = points

        for _ in 0..<AppDefaults.contourSpikeRemovalIterations {
            let medianLength = medianSegmentLength(result)
            let maximumDistance = max(0.004, medianLength * CGFloat(AppDefaults.contourSpikeDistanceMultiplier))
            let minimumCosine = cos(CGFloat(AppDefaults.contourSpikeAngleDegrees) * .pi / 180)

            result = result.indices.map { index in
                let previous = result[(index - 1 + result.count) % result.count]
                let current = result[index]
                let next = result[(index + 1) % result.count]
                let previousVector = CGPoint(x: previous.x - current.x, y: previous.y - current.y)
                let nextVector = CGPoint(x: next.x - current.x, y: next.y - current.y)
                let previousLength = hypot(previousVector.x, previousVector.y)
                let nextLength = hypot(nextVector.x, nextVector.y)

                guard previousLength > 0.0001, nextLength > 0.0001 else {
                    return current
                }

                let cosine = (previousVector.x * nextVector.x + previousVector.y * nextVector.y) / (previousLength * nextLength)
                let isSharpPoint = cosine < -minimumCosine
                let isLongJump = previousLength > maximumDistance || nextLength > maximumDistance

                guard isSharpPoint || isLongJump else {
                    return current
                }

                return CGPoint(
                    x: (previous.x + next.x) / 2,
                    y: (previous.y + next.y) / 2
                )
            }
        }

        return result
    }

    private static func straightenLineRuns(_ points: [CGPoint]) -> [CGPoint] {
        guard
            AppDefaults.contourStraighteningEnabled,
            points.count >= max(8, AppDefaults.contourStraighteningMinimumRun)
        else {
            return points
        }

        let halfWindow = max(2, AppDefaults.contourStraighteningWindow / 2)
        let maximumAngle = CGFloat(AppDefaults.contourStraighteningAngleDegrees) * .pi / 180
        let straightFlags = points.indices.map { index in
            isLocallyStraight(points, at: index, halfWindow: halfWindow, maximumAngle: maximumAngle)
        }
        var result = points
        var visited = Array(repeating: false, count: points.count)

        for startIndex in points.indices where straightFlags[startIndex] && !visited[startIndex] {
            let run = straightRun(
                from: startIndex,
                flags: straightFlags,
                visited: &visited
            )

            guard run.count >= AppDefaults.contourStraighteningMinimumRun else {
                continue
            }

            let runPoints = run.map { points[$0] }
            let line = bestFitLine(for: runPoints)
            let strength = max(0, min(1, AppDefaults.contourStraighteningStrength))

            for index in run {
                let projected = project(points[index], onto: line)
                result[index] = CGPoint(
                    x: points[index].x * (1 - strength) + projected.x * strength,
                    y: points[index].y * (1 - strength) + projected.y * strength
                )
            }
        }

        return result
    }

    private static func isLocallyStraight(
        _ points: [CGPoint],
        at index: Int,
        halfWindow: Int,
        maximumAngle: CGFloat
    ) -> Bool {
        let previous = points[(index - halfWindow + points.count) % points.count]
        let current = points[index]
        let next = points[(index + halfWindow) % points.count]
        let incoming = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
        let outgoing = CGPoint(x: next.x - current.x, y: next.y - current.y)
        let incomingLength = hypot(incoming.x, incoming.y)
        let outgoingLength = hypot(outgoing.x, outgoing.y)

        guard incomingLength > 0.0001, outgoingLength > 0.0001 else {
            return false
        }

        let dot = incoming.x * outgoing.x + incoming.y * outgoing.y
        let cosine = max(-1, min(1, dot / (incomingLength * outgoingLength)))
        let angle = acos(cosine)

        return angle <= maximumAngle
    }

    private static func straightRun(
        from startIndex: Int,
        flags: [Bool],
        visited: inout [Bool]
    ) -> [Int] {
        let count = flags.count
        var run: [Int] = []
        var index = startIndex

        while flags[index], !visited[index] {
            visited[index] = true
            run.append(index)
            index = (index + 1) % count

            if index == startIndex {
                break
            }
        }

        return run
    }

    private static func bestFitLine(for points: [CGPoint]) -> (origin: CGPoint, direction: CGPoint) {
        let center = centroid(of: points)
        var xx: CGFloat = 0
        var xy: CGFloat = 0
        var yy: CGFloat = 0

        for point in points {
            let dx = point.x - center.x
            let dy = point.y - center.y
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
        }

        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let direction = CGPoint(x: cos(angle), y: sin(angle))

        return (center, direction)
    }

    private static func project(
        _ point: CGPoint,
        onto line: (origin: CGPoint, direction: CGPoint)
    ) -> CGPoint {
        let vector = CGPoint(x: point.x - line.origin.x, y: point.y - line.origin.y)
        let amount = vector.x * line.direction.x + vector.y * line.direction.y

        return CGPoint(
            x: line.origin.x + line.direction.x * amount,
            y: line.origin.y + line.direction.y * amount
        )
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else {
            return .zero
        }

        let sum = points.reduce(CGPoint.zero) { partialResult, point in
            CGPoint(x: partialResult.x + point.x, y: partialResult.y + point.y)
        }

        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func roundCorners(_ points: [CGPoint]) -> [CGPoint] {
        guard
            points.count >= 4,
            AppDefaults.contourCurveSmoothingIterations > 0,
            AppDefaults.contourCurveSmoothingAmount > 0
        else {
            return points
        }

        var result = points
        let amount = max(0, min(0.48, AppDefaults.contourCurveSmoothingAmount))

        for _ in 0..<AppDefaults.contourCurveSmoothingIterations {
            var rounded: [CGPoint] = []
            rounded.reserveCapacity(result.count * 2)

            for index in result.indices {
                let current = result[index]
                let next = result[(index + 1) % result.count]

                rounded.append(
                    CGPoint(
                        x: current.x * (1 - amount) + next.x * amount,
                        y: current.y * (1 - amount) + next.y * amount
                    )
                )
                rounded.append(
                    CGPoint(
                        x: current.x * amount + next.x * (1 - amount),
                        y: current.y * amount + next.y * (1 - amount)
                    )
                )
            }

            result = rounded
        }

        return result
    }

    private static func medianSegmentLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else {
            return 0
        }

        let lengths = points.indices.map { index in
            let current = points[index]
            let next = points[(index + 1) % points.count]
            return hypot(next.x - current.x, next.y - current.y)
        }.sorted()

        return lengths[lengths.count / 2]
    }

    static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        guard
            points.count >= 4,
            AppDefaults.contourSmoothingIterations > 0,
            AppDefaults.contourSmoothingStrength > 0
        else {
            return points
        }

        var result = points
        let strength = max(0, min(1, AppDefaults.contourSmoothingStrength))

        for _ in 0..<AppDefaults.contourSmoothingIterations {
            result = result.indices.map { index in
                let previous = result[(index - 1 + result.count) % result.count]
                let current = result[index]
                let next = result[(index + 1) % result.count]
                let average = CGPoint(
                    x: (previous.x + current.x + next.x) / 3,
                    y: (previous.y + current.y + next.y) / 3
                )

                return CGPoint(
                    x: current.x * (1 - strength) + average.x * strength,
                    y: current.y * (1 - strength) + average.y * strength
                )
            }
        }

        return result
    }
}

enum ContourQualityValidator {
    static func isAcceptable(
        _ contour: [CGPoint],
        guide: [CGPoint],
        minimumAreaRatio: CGFloat = AppDefaults.minimumDetectionAreaRatio
    ) -> Bool {
        guard contour.count >= 8, guide.count >= 3 else {
            return false
        }

        let contourBounds = bounds(for: contour)
        let guideBounds = bounds(for: guide)
        let overlap = overlapRatio(contourBounds, with: guideBounds)
        let areaRatio = polygonArea(contour) / max(0.0001, polygonArea(guide))
        let centerDistance = distance(center(of: contourBounds), center(of: guideBounds))
        let guideDiagonal = max(0.0001, hypot(guideBounds.width, guideBounds.height))

        return overlap >= AppDefaults.minimumDetectionGuideOverlap
            && areaRatio >= minimumAreaRatio
            && areaRatio <= 1.45
            && centerDistance / guideDiagonal <= 0.24
    }

    private static func bounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.0001, maxX - minX),
            height: max(0.0001, maxY - minY)
        )
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else {
            return 0
        }

        var area: CGFloat = 0

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }

        return abs(area / 2)
    }

    private static func overlapRatio(_ rect: CGRect, with otherRect: CGRect) -> CGFloat {
        let intersection = rect.intersection(otherRect)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else {
            return 0
        }

        return intersection.width * intersection.height / (rect.width * rect.height)
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}

struct SubjectExtraction {
    let contour: [CGPoint]
    let image: NSImage
}

enum PreprocessedContourExtractor {
    static func detectContour(in image: NSImage, guidedBy guide: [CGPoint]) -> [CGPoint]? {
        guard
            guide.count >= 3,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let cropRect = cropRect(for: guide, imageWidth: imageWidth, imageHeight: imageHeight)
        let ciImage = CIImage(cgImage: cgImage)

        guard let preprocessedImage = preprocess(ciImage)?
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        else {
            return nil
        }

        let request = VNDetectContoursRequest()
        request.revision = VNDetectContourRequestRevision1
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 768

        let handler = VNImageRequestHandler(ciImage: preprocessedImage, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard
            let observation = request.results?.first as? VNContoursObservation,
            let points = bestContourPoints(
                in: observation,
                cropRect: cropRect,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                guide: guide
            )
        else {
            return nil
        }

        let simplified = simplify(points, minimumDistance: 0.008)

        guard simplified.count >= 8 else {
            return nil
        }

        return simplified
    }

    private static func preprocess(_ image: CIImage) -> CIImage? {
        let morphology = CIFilter(name: "CIMorphologyMinimum")
        morphology?.setValue(image, forKey: kCIInputImageKey)
        morphology?.setValue(5, forKey: kCIInputRadiusKey)

        guard let morphImage = morphology?.outputImage else {
            return nil
        }

        let threshold = CIFilter(name: "CIColorThreshold")
        threshold?.setValue(morphImage, forKey: kCIInputImageKey)
        threshold?.setValue(0.42, forKey: "inputThreshold")

        if let thresholdImage = threshold?.outputImage {
            return thresholdImage
        }

        let controls = CIFilter(name: "CIColorControls")
        controls?.setValue(morphImage, forKey: kCIInputImageKey)
        controls?.setValue(0, forKey: kCIInputSaturationKey)
        controls?.setValue(1.7, forKey: kCIInputContrastKey)

        return controls?.outputImage
    }

    private static func bestContourPoints(
        in observation: VNContoursObservation,
        cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        guide: [CGPoint]
    ) -> [CGPoint]? {
        let minArea: CGFloat = 0.03
        let maxArea: CGFloat = 0.92

        return observation.topLevelContours
            .compactMap { contour -> (points: [CGPoint], score: CGFloat)? in
                let cropPoints = pathPoints(contour.normalizedPath)
                let cropArea = abs(polygonArea(cropPoints))
                let cropBounds = bounds(for: cropPoints)
                let touchesCropEdge = cropBounds.minX < 0.02
                    || cropBounds.minY < 0.02
                    || cropBounds.maxX > 0.98
                    || cropBounds.maxY > 0.98

                guard cropArea >= minArea, cropArea <= maxArea, !touchesCropEdge else {
                    return nil
                }

                let points = pointsFromVisionPath(
                    contour.normalizedPath,
                    cropRect: cropRect,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    guide: guide
                )
                let insideRatio = insideRatio(points, guide: guide)
                let guideOverlap = overlapRatio(bounds(for: points), with: bounds(for: guide).insetBy(dx: -0.04, dy: -0.04).clampedToUnit())

                guard insideRatio > 0.55, guideOverlap > 0.35 else {
                    return nil
                }

                let score = CGFloat(contour.normalizedPoints.count) * insideRatio * guideOverlap
                return (points, score)
            }
            .max { first, second in first.score < second.score }?
            .points
    }

    private static func cropRect(
        for guide: [CGPoint],
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        let minX = guide.map(\.x).min() ?? 0
        let maxX = guide.map(\.x).max() ?? 1
        let minY = guide.map(\.y).min() ?? 0
        let maxY = guide.map(\.y).max() ?? 1
        let padding: CGFloat = 0.06
        let normalizedRect = CGRect(
            x: max(0, minX - padding),
            y: max(0, minY - padding),
            width: min(1, maxX + padding) - max(0, minX - padding),
            height: min(1, maxY + padding) - max(0, minY - padding)
        )

        return CGRect(
            x: normalizedRect.minX * imageWidth,
            y: (1 - normalizedRect.maxY) * imageHeight,
            width: normalizedRect.width * imageWidth,
            height: normalizedRect.height * imageHeight
        )
    }

    private static func pointsFromVisionPath(
        _ path: CGPath,
        cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        guide: [CGPoint]
    ) -> [CGPoint] {
        let cropPoints = pathPoints(path)
        let nonFlipped = cropPoints.map { point in
            visionCropPointToUI(
                point,
                cropRect: cropRect,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                flipsY: false
            )
        }
        let flipped = cropPoints.map { point in
            visionCropPointToUI(
                point,
                cropRect: cropRect,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                flipsY: true
            )
        }

        let guideBounds = bounds(for: guide).insetBy(dx: -0.04, dy: -0.04).clampedToUnit()
        let nonFlippedScore = overlapRatio(bounds(for: nonFlipped), with: guideBounds) + insideRatio(nonFlipped, guide: guide)
        let flippedScore = overlapRatio(bounds(for: flipped), with: guideBounds) + insideRatio(flipped, guide: guide)

        return flippedScore > nonFlippedScore ? flipped : nonFlipped
    }

    private static func visionCropPointToUI(
        _ point: CGPoint,
        cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        flipsY: Bool
    ) -> CGPoint {
        let imageX = cropRect.minX + point.x * cropRect.width
        let imageYFromBottom = cropRect.minY + point.y * cropRect.height
        let normalizedY = imageYFromBottom / imageHeight

        return CGPoint(
            x: max(0, min(1, imageX / imageWidth)),
            y: max(0, min(1, flipsY ? 1 - normalizedY : normalizedY))
        )
    }

    private static func pathPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee

            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }

        return points
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else {
            return 0
        }

        var area: CGFloat = 0

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }

        return area / 2
    }

    private static func bounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func insideRatio(_ points: [CGPoint], guide: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else {
            return 0
        }

        let insideCount = points.filter { contains($0, in: guide) }.count
        return CGFloat(insideCount) / CGFloat(points.count)
    }

    private static func overlapRatio(_ rect: CGRect, with otherRect: CGRect) -> CGFloat {
        let intersection = rect.intersection(otherRect)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else {
            return 0
        }

        return intersection.width * intersection.height / (rect.width * rect.height)
    }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var isInside = false
        var previousIndex = polygon.count - 1

        for currentIndex in polygon.indices {
            let current = polygon[currentIndex]
            let previous = polygon[previousIndex]
            let intersects = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x

            if intersects {
                isInside.toggle()
            }

            previousIndex = currentIndex
        }

        return isInside
    }

    private static func simplify(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        var simplified: [CGPoint] = []

        for point in points {
            guard let lastPoint = simplified.last else {
                simplified.append(point)
                continue
            }

            let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            if distance >= minimumDistance {
                simplified.append(point)
            }
        }

        return simplified
    }
}

enum SubjectMaskExtractor {
    static func extractSubject(in image: NSImage, guidedBy guide: [CGPoint]) -> SubjectExtraction? {
        guard
            guide.count >= 3,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first else {
            return nil
        }

        let selectedInstances = instancesInsideGuide(observation.instanceMask, guide: guide)
        guard !selectedInstances.isEmpty else {
            return nil
        }

        guard
            let maskedImage = makeImage(from: try? observation.generateMaskedImage(
                ofInstances: selectedInstances,
                from: handler,
                croppedToInstancesExtent: false
            )),
            let maskBuffer = try? observation.generateScaledMaskForImage(
                forInstances: selectedInstances,
                from: handler
            )
        else {
            return nil
        }

        let contour = contourFromMask(maskBuffer, guidedBy: guide)
        guard contour.count >= 8 else {
            return nil
        }

        return SubjectExtraction(contour: contour, image: maskedImage)
    }

    private static func makeImage(from pixelBuffer: CVPixelBuffer?) -> NSImage? {
        guard let pixelBuffer else {
            return nil
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func instancesInsideGuide(_ instanceMask: CVPixelBuffer, guide: [CGPoint]) -> IndexSet {
        CVPixelBufferLockBaseAddress(instanceMask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(instanceMask, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(instanceMask) else {
            return IndexSet()
        }

        let width = CVPixelBufferGetWidth(instanceMask)
        let height = CVPixelBufferGetHeight(instanceMask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(instanceMask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(instanceMask)
        let guideBounds = normalizedBounds(for: guide).clampedToUnit()
        let minX = max(0, Int(guideBounds.minX * CGFloat(width)))
        let maxX = min(width - 1, Int(ceil(guideBounds.maxX * CGFloat(width))))
        let minY = max(0, Int(guideBounds.minY * CGFloat(height)))
        let maxY = min(height - 1, Int(ceil(guideBounds.maxY * CGFloat(height))))
        let step = max(1, min(width, height) / 180)
        var labels = Set<Int>()

        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )

                guard contains(point, in: guide) else {
                    continue
                }

                let label = instanceLabel(
                    baseAddress: baseAddress,
                    bytesPerRow: bytesPerRow,
                    pixelFormat: pixelFormat,
                    x: x,
                    y: y
                )

                if label > 0 {
                    labels.insert(label)
                }
            }
        }

        var instances = IndexSet()
        for label in labels {
            instances.insert(label)
        }

        return instances
    }

    private static func contourFromMask(_ maskBuffer: CVPixelBuffer, guidedBy guide: [CGPoint]) -> [CGPoint] {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(maskBuffer) else {
            return []
        }

        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(maskBuffer)
        let guideBounds = normalizedBounds(for: guide).insetBy(dx: -0.05, dy: -0.05).clampedToUnit()
        let center = CGPoint(x: guideBounds.midX, y: guideBounds.midY)
        let rays = 160

        return (0..<rays).compactMap { rayIndex in
            let angle = CGFloat(rayIndex) / CGFloat(rays) * 2 * .pi
            var bestPoint: CGPoint?

            for step in 0...220 {
                let radius = CGFloat(step) / 220
                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )

                guard guideBounds.contains(point) else {
                    continue
                }

                let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
                let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))

                if maskValue(
                    baseAddress: baseAddress,
                    bytesPerRow: bytesPerRow,
                    pixelFormat: pixelFormat,
                    x: x,
                    y: y
                ) > 0.12 {
                    bestPoint = point
                }
            }

            return bestPoint
        }
    }

    private static func maskValue(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        pixelFormat: OSType,
        x: Int,
        y: Int
    ) -> Float {
        let row = baseAddress.advanced(by: y * bytesPerRow)

        if pixelFormat == kCVPixelFormatType_OneComponent32Float {
            return row.assumingMemoryBound(to: Float.self)[x]
        }

        if pixelFormat == kCVPixelFormatType_OneComponent8 {
            return Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
        }

        if pixelFormat == kCVPixelFormatType_32BGRA {
            return Float(row.assumingMemoryBound(to: UInt8.self)[x * 4 + 3]) / 255
        }

        return 0
    }

    private static func instanceLabel(
        baseAddress: UnsafeMutableRawPointer,
        bytesPerRow: Int,
        pixelFormat: OSType,
        x: Int,
        y: Int
    ) -> Int {
        let row = baseAddress.advanced(by: y * bytesPerRow)

        if pixelFormat == kCVPixelFormatType_OneComponent8 {
            return Int(row.assumingMemoryBound(to: UInt8.self)[x])
        }

        if pixelFormat == kCVPixelFormatType_OneComponent16 {
            return Int(row.assumingMemoryBound(to: UInt16.self)[x])
        }

        if pixelFormat == kCVPixelFormatType_OneComponent32Float {
            return Int(row.assumingMemoryBound(to: Float.self)[x].rounded())
        }

        return 0
    }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else {
            return false
        }

        var isInside = false
        var previousIndex = polygon.count - 1

        for currentIndex in polygon.indices {
            let current = polygon[currentIndex]
            let previous = polygon[previousIndex]
            let intersects = (current.y > point.y) != (previous.y > point.y)
                && point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x

            if intersects {
                isInside.toggle()
            }

            previousIndex = currentIndex
        }

        return isInside
    }

    private static func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        )
    }
}

enum ContourDetector {
    static func detectContour(in image: NSImage, guidedBy guide: [CGPoint]) -> [CGPoint]? {
        guard
            guide.count >= 3,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let cropRect = cropRect(for: guide, imageWidth: imageWidth, imageHeight: imageHeight)

        guard
            cropRect.width >= 8,
            cropRect.height >= 8,
            let croppedImage = cgImage.cropping(to: cropRect.integral)
        else {
            return nil
        }

        let candidates = [false, true].compactMap { detectsDarkOnLight -> [CGPoint]? in
            let request = VNDetectContoursRequest()
            request.contrastAdjustment = 1.0
            request.detectsDarkOnLight = detectsDarkOnLight
            request.maximumImageDimension = 512

            let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            guard
                let observation = request.results?.first as? VNContoursObservation,
                let contour = largestContour(in: observation)
            else {
                return nil
            }

            let points = pointsFromVisionPath(
                contour.normalizedPath,
                cropRect: cropRect,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )

            return simplify(points, minimumDistance: 0.01)
        }

        guard
            let simplified = candidates
                .filter({ $0.count >= 8 })
                .max(by: { abs(polygonArea($0)) < abs(polygonArea($1)) })
        else {
            return nil
        }

        guard simplified.count >= 8 else {
            return nil
        }

        return simplified
    }

    private static func cropRect(
        for guide: [CGPoint],
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        let minX = guide.map(\.x).min() ?? 0
        let maxX = guide.map(\.x).max() ?? 1
        let minY = guide.map(\.y).min() ?? 0
        let maxY = guide.map(\.y).max() ?? 1
        let padding: CGFloat = 0.04
        let normalizedRect = CGRect(
            x: max(0, minX - padding),
            y: max(0, minY - padding),
            width: min(1, maxX + padding) - max(0, minX - padding),
            height: min(1, maxY + padding) - max(0, minY - padding)
        )

        return CGRect(
            x: normalizedRect.minX * imageWidth,
            y: (1 - normalizedRect.maxY) * imageHeight,
            width: normalizedRect.width * imageWidth,
            height: normalizedRect.height * imageHeight
        )
    }

    private static func largestContour(in observation: VNContoursObservation) -> VNContour? {
        var bestContour: VNContour?
        var bestArea: CGFloat = 0

        for contour in observation.topLevelContours {
            let points = pathPoints(contour.normalizedPath)
            let area = abs(polygonArea(points))

            if area > bestArea {
                bestArea = area
                bestContour = contour
            }
        }

        return bestContour
    }

    private static func pointsFromVisionPath(
        _ path: CGPath,
        cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [CGPoint] {
        pathPoints(path).map { point in
            visionCropPointToUI(point, cropRect: cropRect, imageWidth: imageWidth, imageHeight: imageHeight)
        }
    }

    private static func visionCropPointToUI(
        _ point: CGPoint,
        cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGPoint {
        let imageX = cropRect.minX + point.x * cropRect.width
        let imageYFromBottom = cropRect.minY + point.y * cropRect.height

        return CGPoint(
            x: max(0, min(1, imageX / imageWidth)),
            y: max(0, min(1, 1 - imageYFromBottom / imageHeight))
        )
    }

    private static func pathPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee

            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }

        return points
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else {
            return 0
        }

        var area: CGFloat = 0

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }

        return area / 2
    }

    private static func simplify(_ points: [CGPoint], minimumDistance: CGFloat) -> [CGPoint] {
        var simplified: [CGPoint] = []

        for point in points {
            guard let lastPoint = simplified.last else {
                simplified.append(point)
                continue
            }

            let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            if distance >= minimumDistance {
                simplified.append(point)
            }
        }

        return simplified
    }
}

struct MemoCreationPreviewSheet: View {
    let image: NSImage
    let baseContour: [CGPoint]
    let basePaddingPixels: CGFloat
    let opacity: Double
    let brightness: Double
    let text: String
    @Binding var configuration: MemoPreviewConfiguration
    let onCancel: () -> Void
    let onCreate: (MemoPreviewConfiguration) -> Void

    private var adjustedContour: [CGPoint] {
        ContourPadding.expanded(
            baseContour,
            imageSize: image.size,
            paddingPixels: basePaddingPixels
                + configuration.contourAdjustmentPixels
                - AppDefaults.contourMaskInsetPixels
        )
    }

    private var adjustedBounds: CGRect {
        normalizedBounds(for: adjustedContour)
    }

    private var previewImage: NSImage {
        CutoutImageRenderer.renderCrop(
            image: image,
            bounds: adjustedBounds,
            opacity: opacity,
            brightness: brightness
        ) ?? image
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("メモの調整")
                    .font(.system(size: 18, weight: .semibold))

                Spacer()

                Button("キャンセル", action: onCancel)

                Button {
                    onCreate(configuration)
                } label: {
                    Label("作成", systemImage: "macwindow")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.regularMaterial)

            HStack(spacing: 0) {
                memoPreview
                    .frame(minWidth: 420, minHeight: 520)
                    .background(Color(nsColor: .textBackgroundColor))

                Divider()

                controls
                    .frame(width: 300)
                    .padding(16)
            }
        }
        .frame(width: 860, height: 640)
    }

    private var memoPreview: some View {
        GeometryReader { proxy in
            let previewSize = fittedSize(imageSize: previewImage.size, containerSize: proxy.size)
            let previewRect = CGRect(
                x: (proxy.size.width - previewSize.width) / 2,
                y: (proxy.size.height - previewSize.height) / 2,
                width: previewSize.width,
                height: previewSize.height
            )

            ZStack {
                Image(nsImage: previewImage)
                    .resizable()
                    .frame(width: previewRect.width, height: previewRect.height)
                    .mask {
                        BoundedContourShape(points: adjustedContour, bounds: adjustedBounds)
                            .blur(radius: configuration.contourBlurRadius)
                    }
                    .position(x: previewRect.midX, y: previewRect.midY)
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)

                BoundedContourShape(points: adjustedContour, bounds: adjustedBounds)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                    .frame(width: previewRect.width, height: previewRect.height)
                    .position(x: previewRect.midX, y: previewRect.midY)

                if configuration.usesManualTextArea {
                    Rectangle()
                        .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.orange.opacity(0.08))
                        .frame(
                            width: configuration.textArea.width * previewRect.width,
                            height: configuration.textArea.height * previewRect.height
                        )
                        .position(
                            x: previewRect.minX + configuration.textArea.midX * previewRect.width,
                            y: previewRect.minY + configuration.textArea.midY * previewRect.height
                        )
                }

                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(4)
                        .frame(
                            width: (configuration.usesManualTextArea ? configuration.textArea.width : 0.62) * previewRect.width,
                            alignment: .leading
                        )
                        .position(
                            x: previewRect.minX + (configuration.usesManualTextArea ? configuration.textArea.midX : 0.5) * previewRect.width,
                            y: previewRect.minY + (configuration.usesManualTextArea ? configuration.textArea.midY : 0.5) * previewRect.height
                        )
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("輪郭") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledSlider(
                        title: "ぼかし",
                        value: $configuration.contourBlurRadius,
                        range: 0...14,
                        suffix: "px"
                    )

                    labeledSlider(
                        title: "微調整",
                        value: $configuration.contourAdjustmentPixels,
                        range: -28...28,
                        suffix: "px"
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("テキスト表示域") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("手動で指定", isOn: $configuration.usesManualTextArea)

                    labeledSlider(title: "横位置", value: binding(\.textArea.origin.x), range: 0...0.9, suffix: "")
                        .disabled(!configuration.usesManualTextArea)
                    labeledSlider(title: "縦位置", value: binding(\.textArea.origin.y), range: 0...0.9, suffix: "")
                        .disabled(!configuration.usesManualTextArea)
                    labeledSlider(title: "幅", value: binding(\.textArea.size.width), range: 0.18...1.0, suffix: "")
                        .disabled(!configuration.usesManualTextArea)
                    labeledSlider(title: "高さ", value: binding(\.textArea.size.height), range: 0.18...1.0, suffix: "")
                        .disabled(!configuration.usesManualTextArea)
                }
                .padding(.vertical, 4)
            }

            Text("青い線は現在の輪郭です。ぼかしと微調整は作成されるメモに反映されます。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private func labeledSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f")\(suffix)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MemoPreviewConfiguration, CGFloat>) -> Binding<Double> {
        Binding<Double>(
            get: { Double(configuration[keyPath: keyPath]) },
            set: { configuration[keyPath: keyPath] = CGFloat($0) }
        )
    }

    private func fittedSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return containerSize
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height) * 0.86
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(x: minX, y: minY, width: max(0.01, maxX - minX), height: max(0.01, maxY - minY))
    }
}

final class CutoutWindowManager {
    static let shared = CutoutWindowManager()

    private var windows: [NSWindow] = []

    private init() {}

    func openWindow(
        image: NSImage,
        contour: [CGPoint],
        bounds: CGRect,
        text: String,
        opacity: Double,
        contourBlurRadius: Double,
        textArea: CGRect?
    ) {
        guard contour.count >= 3 else {
            return
        }

        let imageAspectRatio = max(0.01, image.size.width / image.size.height)
        let aspectRatio = max(0.4, min(2.5, imageAspectRatio))
        let width: CGFloat = 360
        let height = width / aspectRatio
        let size = NSSize(width: width, height: height)
        let view = CutoutHostingView(
            rootView: CutoutMemoWindowView(
                image: image,
                contour: contour,
                bounds: bounds,
                text: text,
                opacity: opacity,
                contourBlurRadius: contourBlurRadius,
                textArea: textArea
            ),
            contour: contour,
            bounds: bounds
        )

        let window = CutoutMemoWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.setFrame(NSRect(origin: nextWindowOrigin(for: size), size: size), display: true)
        window.makeKeyAndOrderFront(nil)

        windows.append(window)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let window else {
                return
            }

            self?.windows.removeAll { $0 === window }
        }
    }

    private func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        )
    }

    private func nextWindowOrigin(for size: NSSize) -> NSPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let offset = CGFloat((windows.count % 5) * 24)

        return NSPoint(
            x: screenFrame.midX - size.width / 2 + offset,
            y: screenFrame.midY - size.height / 2 - offset
        )
    }
}

final class CutoutMemoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CutoutHostingView<Content: View>: NSHostingView<Content> {
    private let contour: [CGPoint]
    private let normalizedBounds: CGRect

    init(rootView: Content, contour: [CGPoint], bounds: CGRect) {
        self.contour = contour
        self.normalizedBounds = bounds
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required init(rootView: Content) {
        self.contour = []
        self.normalizedBounds = .unit
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsContour(point) else {
            return nil
        }

        return super.hitTest(point)
    }

    private func containsContour(_ point: CGPoint) -> Bool {
        guard !contour.isEmpty, bounds.contains(point) else {
            return false
        }

        return contourPath(in: bounds).contains(point)
    }

    private func contourPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let localPoints = contour.map { point in
            CGPoint(
                x: (point.x - normalizedBounds.minX) / normalizedBounds.width,
                y: (point.y - normalizedBounds.minY) / normalizedBounds.height
            )
        }

        guard let firstPoint = localPoints.first else {
            return path
        }

        path.move(to: denormalize(firstPoint, in: rect))

        for point in localPoints.dropFirst() {
            path.addLine(to: denormalize(point, in: rect))
        }

        path.closeSubpath()
        return path
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }
}

struct CutoutMemoWindowView: View {
    let image: NSImage
    let contour: [CGPoint]
    let bounds: CGRect
    @State var text: String
    let opacity: Double
    let contourBlurRadius: Double
    let textArea: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color.white
                        .frame(width: size.width, height: size.height)

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)

                    if let textArea {
                        TextEditor(text: $text)
                            .font(.system(size: max(17, size.width * 0.06), weight: .regular))
                            .foregroundStyle(.primary)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .frame(
                                width: textArea.width * size.width,
                                height: textArea.height * size.height
                            )
                            .position(
                                x: textArea.midX * size.width,
                                y: textArea.midY * size.height
                            )
                    } else {
                        ShapedTextEditor(
                            text: $text,
                            contour: contour,
                            bounds: bounds,
                            fontSize: max(17, size.width * 0.06)
                        )
                        .frame(width: size.width, height: size.height)
                    }
                }
                .frame(width: size.width, height: size.height)
                .mask {
                    BoundedContourShape(points: contour, bounds: bounds)
                        .blur(radius: contourBlurRadius)
                }
            }
            .background(Color.clear)
        }
    }
}

struct BoundedContourShape: Shape {
    let points: [CGPoint]
    let bounds: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let localPoints = points.map { point in
            CGPoint(
                x: (point.x - bounds.minX) / bounds.width,
                y: (point.y - bounds.minY) / bounds.height
            )
        }

        guard let firstPoint = localPoints.first else {
            return path
        }

        path.move(to: denormalize(firstPoint, in: rect))

        for point in localPoints.dropFirst() {
            path.addLine(to: denormalize(point, in: rect))
        }

        path.closeSubpath()
        return path
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + point.x * rect.width,
            y: rect.minY + point.y * rect.height
        )
    }
}

struct ShapedTextEditor: NSViewRepresentable {
    @Binding var text: String
    let contour: [CGPoint]
    let bounds: CGRect
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = ShapedNSTextView()
        textView.onLayout = { textView in
            textView.textContainer?.containerSize = textView.bounds.size
            textView.textContainer?.exclusionPaths = TextExclusionPathBuilder.paths(
                contour: contour,
                bounds: bounds,
                size: textView.bounds.size,
                fontSize: fontSize
            )
        }
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.font = .systemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor

        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }

        textView.font = .systemFont(ofSize: fontSize, weight: .regular)
        textView.textContainer?.containerSize = textView.bounds.size
        textView.textContainer?.exclusionPaths = TextExclusionPathBuilder.paths(
            contour: contour,
            bounds: bounds,
            size: textView.bounds.size,
            fontSize: fontSize
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text = textView.string
        }
    }
}

final class ShapedNSTextView: NSTextView {
    var onLayout: ((ShapedNSTextView) -> Void)?

    override func layout() {
        super.layout()
        onLayout?(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?(self)
    }
}

enum TextExclusionPathBuilder {
    static func paths(
        contour: [CGPoint],
        bounds: CGRect,
        size: CGSize,
        fontSize: CGFloat
    ) -> [NSBezierPath] {
        guard contour.count >= 3, bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
            return []
        }

        let polygon = contour.map { point in
            CGPoint(
                x: (point.x - bounds.minX) / bounds.width * size.width,
                y: (point.y - bounds.minY) / bounds.height * size.height
            )
        }
        let sliceHeight = max(5, fontSize * 0.45)
        let horizontalInset = max(14, size.width * 0.08)
        let verticalInset = max(10, fontSize * 0.6)
        var paths: [NSBezierPath] = []
        var y: CGFloat = 0

        while y < size.height {
            let bandHeight = min(sliceHeight, size.height - y)
            let sampleY = y + bandHeight / 2
            let intersections = xIntersections(atY: sampleY, polygon: polygon)

            guard intersections.count >= 2 else {
                paths.append(NSBezierPath(rect: CGRect(x: 0, y: y, width: size.width, height: bandHeight)))
                y += bandHeight
                continue
            }

            let left = max(0, (intersections.first ?? 0) + horizontalInset)
            let right = min(size.width, (intersections.last ?? size.width) - horizontalInset)
            let clippedTop = sampleY < verticalInset
            let clippedBottom = sampleY > size.height - verticalInset

            if clippedTop || clippedBottom || right <= left {
                paths.append(NSBezierPath(rect: CGRect(x: 0, y: y, width: size.width, height: bandHeight)))
            } else {
                if left > 0 {
                    paths.append(NSBezierPath(rect: CGRect(x: 0, y: y, width: left, height: bandHeight)))
                }

                if right < size.width {
                    paths.append(NSBezierPath(rect: CGRect(x: right, y: y, width: size.width - right, height: bandHeight)))
                }
            }

            y += bandHeight
        }

        return paths
    }

    private static func xIntersections(atY y: CGFloat, polygon: [CGPoint]) -> [CGFloat] {
        guard polygon.count >= 3 else {
            return []
        }

        var intersections: [CGFloat] = []
        var previous = polygon[polygon.count - 1]

        for current in polygon {
            let crosses = (current.y > y) != (previous.y > y)

            if crosses {
                let ratio = (y - previous.y) / (current.y - previous.y)
                intersections.append(previous.x + ratio * (current.x - previous.x))
            }

            previous = current
        }

        return intersections.sorted()
    }
}

private extension CGRect {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    func clampedToUnit() -> CGRect {
        let minX = max(0, self.minX)
        let minY = max(0, self.minY)
        let maxX = min(1, self.maxX)
        let maxY = min(1, self.maxY)

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        )
    }
}
