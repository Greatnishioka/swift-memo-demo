import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

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
    @State private var paperOpacity = 0.58
    @State private var paperBrightness = 0.18
    @State private var isDropTargeted = false
    @State private var isTracingContour = false
    @State private var tracePoints: [CGPoint] = []
    @State private var appliedContour: [CGPoint]?
    @State private var roughContour: [CGPoint]?
    @State private var subjectImage: NSImage?
    @State private var didUseDetectedContour = false
    @State private var contourPaddingPixels = 18.0

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

                            memoPaperLayer(image: memoImage, imageRect: imageRect, contour: paddedContour)

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
                    openCutoutWindow()
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
        if let contour = PreprocessedContourExtractor.detectContour(in: memoImage, guidedBy: tracePoints) {
            appliedContour = contour
            subjectImage = nil
            didUseDetectedContour = true
        } else if let extraction = SubjectMaskExtractor.extractSubject(in: memoImage, guidedBy: tracePoints) {
            appliedContour = extraction.contour
            subjectImage = nil
            didUseDetectedContour = true
        } else {
            appliedContour = ContourDetector.detectContour(in: memoImage, guidedBy: tracePoints) ?? tracePoints
            didUseDetectedContour = appliedContour != tracePoints
            subjectImage = nil
        }
        isTracingContour = false
    }

    private func openCutoutWindow() {
        guard let memoImage, let appliedContour else {
            return
        }
        let contour = ContourPadding.expanded(
            appliedContour,
            imageSize: memoImage.size,
            paddingPixels: contourPaddingPixels
        )
        let bounds = normalizedBounds(for: contour)
        let cutoutImage = CutoutImageRenderer.render(
            image: memoImage,
            contour: contour,
            bounds: bounds,
            opacity: paperOpacity,
            brightness: paperBrightness
        ) ?? memoImage

        CutoutWindowManager.shared.openWindow(
            image: cutoutImage,
            contour: contour,
            bounds: bounds,
            text: memoText,
            opacity: paperOpacity
        )
    }

    private func resetContour() {
        tracePoints = []
        appliedContour = nil
        roughContour = nil
        subjectImage = nil
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
        guard points.count >= 3, paddingPixels > 0, imageSize.width > 0, imageSize.height > 0 else {
            return points
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

final class CutoutWindowManager {
    static let shared = CutoutWindowManager()

    private var windows: [NSWindow] = []

    private init() {}

    func openWindow(
        image: NSImage,
        contour: [CGPoint],
        bounds: CGRect,
        text: String,
        opacity: Double
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
                opacity: opacity
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

                    TextEditor(text: $text)
                        .font(.system(size: max(17, size.width * 0.06), weight: .regular, design: .rounded))
                        .foregroundStyle(.primary)
                        .scrollContentBackground(.hidden)
                        .padding(size.width * 0.12)
                        .background(Color.clear)
                }
                .frame(width: size.width, height: size.height)
                .mask {
                    BoundedContourShape(points: contour, bounds: bounds)
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
