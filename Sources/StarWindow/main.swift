import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum AppDefaults {
    static let contourDebugLogging = true
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
    static let lineColorContourRayCount = 260
    static let lineColorContourMinimumPointRatio = 0.34
    static let lineColorContourMinimumSaturation: CGFloat = 0.075
    static let lineColorContourMinimumLuminance: CGFloat = 0.48
    static let lineColorContourMaximumSeedDistance: CGFloat = 0.20
    static let lineColorContourMinimumBackgroundDistance: CGFloat = 0.13
    static let lineColorContourMaximumInwardSearchDistance: CGFloat = 0.22
    static let detailedExtractionColorDistanceThreshold: CGFloat = 0.10
    static let detailedExtractionBoundarySampleStep = 6
    static let detailedExtractionApplyStep = 2
}

struct MemoPreviewConfiguration {
    var paperOpacity = AppDefaults.paperOpacity
    var paperBrightness = AppDefaults.paperBrightness
    var contourPaddingPixels = AppDefaults.contourPaddingPixels
    var contourBlurRadius = 0.0
    var contourBlurMode = ContourBlurMode.both
    var editedContour: [CGPoint]?
    var textPath: [CGPoint]?
    var brushSizePixels = 18.0
}

enum ContourBlurMode: String, CaseIterable, Identifiable {
    case outside = "外側"
    case inside = "内側"
    case both = "両側"

    var id: String { rawValue }
}

enum MemoPreviewTool: String, CaseIterable, Identifiable {
    case move = "確認"
    case pencil = "輪郭ペン"
    case eraser = "輪郭消しゴム"

    var id: String { rawValue }
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
    @State private var isDropTargeted = false
    @State private var isTracingContour = false
    @State private var tracePoints: [CGPoint] = []
    @State private var appliedContour: [CGPoint]?
    @State private var roughContour: [CGPoint]?
    @State private var subjectImage: NSImage?
    @State private var didUseDetectedContour = false
    @State private var contourSelectionCandidates: [DisplayContourCandidate] = []
    @State private var selectedContourCandidateID: DisplayContourCandidate.ID?
    @State private var memoPreviewConfiguration = MemoPreviewConfiguration()
    @State private var isShowingMemoPreview = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)

            if !contourSelectionCandidates.isEmpty {
                candidateSelectionBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
            }

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

                            memoPaperLayer(image: memoImage, imageRect: imageRect, contour: nil)

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
        .sheet(isPresented: $isShowingMemoPreview) {
            if let memoImage, let appliedContour {
                MemoCreationPreviewSheet(
                    image: memoImage,
                    baseContour: appliedContour,
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

    private var candidateSelectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("候補")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(contourSelectionCandidates) { candidate in
                    Button {
                        selectContourCandidate(candidate)
                    } label: {
                        HStack(spacing: 5) {
                            if candidate.isRecommended {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }

                            Text(candidate.title)
                                .lineLimit(1)

                            if let score = candidate.score {
                                Text(String(format: "%.1f", Double(score)))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(candidate.id == selectedContourCandidateID ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(candidate.id == selectedContourCandidateID ? Color.accentColor : Color.primary)
                    .help(candidate.helpText)
                }
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
            }
        }
    }

    private func memoPaperLayer(image: NSImage, imageRect: CGRect, contour: [CGPoint]?) -> some View {
        ZStack {
            Color.white

            Image(nsImage: image)
                .resizable()
                .scaledToFit()
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
            contourSelectionCandidates = []
            selectedContourCandidateID = nil
        }
    }

    private func applyTrace() {
        guard let memoImage, tracePoints.count >= 3 else {
            return
        }

        roughContour = tracePoints
        let candidates = contourCandidates(in: memoImage, guide: tracePoints)
        let displayCandidates = displayCandidates(from: candidates, guide: tracePoints)

        contourSelectionCandidates = displayCandidates
        logContourCandidates(displayCandidates, guide: tracePoints)

        if let initialCandidate = displayCandidates.first(where: \.isRecommended) ?? displayCandidates.first {
            selectContourCandidate(initialCandidate)
        }
        isTracingContour = false
    }

    private func displayCandidates(from candidates: [ContourCandidate], guide: [CGPoint]) -> [DisplayContourCandidate] {
        let scoredCandidates = ContourCandidateSelector.scoredCandidates(from: candidates, guide: guide)
        let recommendedID = scoredCandidates
            .filter { $0.score >= CGFloat(AppDefaults.minimumAutoCandidateScore) }
            .max { first, second in first.score < second.score }?
            .candidate
            .displayID
        var displayCandidates = candidates.enumerated().map { index, candidate in
            let score = scoredCandidates.first { $0.candidate.displayID == candidate.displayID }?.score
            let contour = candidate.smoothsContour ? ContourSmoother.polished(candidate.contour) : candidate.contour

            return DisplayContourCandidate(
                id: candidate.displayID,
                title: candidate.source.displayName,
                helpText: candidate.source.helpText,
                contour: contour,
                score: score,
                isRecommended: candidate.displayID == recommendedID,
                didUseDetectedContour: true,
                sortIndex: index
            )
        }

        displayCandidates.sort { first, second in
            if first.isRecommended != second.isRecommended {
                return first.isRecommended
            }

            switch (first.score, second.score) {
            case let (firstScore?, secondScore?):
                if firstScore != secondScore {
                    return firstScore > secondScore
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            return first.sortIndex < second.sortIndex
        }

        displayCandidates.append(
            DisplayContourCandidate(
                id: "hand-trace",
                title: "手描き",
                helpText: "なぞった線をそのまま整えて使います",
                contour: ContourSmoother.polished(ContourSmoother.densify(guide)),
                score: nil,
                isRecommended: recommendedID == nil,
                didUseDetectedContour: false,
                sortIndex: displayCandidates.count
            )
        )

        return displayCandidates
    }

    private func selectContourCandidate(_ candidate: DisplayContourCandidate) {
        selectedContourCandidateID = candidate.id
        appliedContour = candidate.contour
        didUseDetectedContour = candidate.didUseDetectedContour
        subjectImage = nil
        logSelectedContourCandidate(candidate)
    }

    private func logContourCandidates(_ candidates: [DisplayContourCandidate], guide: [CGPoint]) {
        guard AppDefaults.contourDebugLogging else {
            return
        }

        print("---- Contour candidates ----")
        print("guide: \(contourDebugSummary(for: guide, guide: guide))")

        for candidate in candidates {
            let marker = candidate.isRecommended ? "*" : " "
            let scoreText = candidate.score.map { String(format: "%.3f", Double($0)) } ?? "-"
            print("\(marker) \(candidate.title): score=\(scoreText) \(contourDebugSummary(for: candidate.contour, guide: guide))")
        }

        print("----------------------------")
    }

    private func logSelectedContourCandidate(_ candidate: DisplayContourCandidate) {
        guard AppDefaults.contourDebugLogging else {
            return
        }

        let scoreText = candidate.score.map { String(format: "%.3f", Double($0)) } ?? "-"
        print("Selected contour candidate: \(candidate.title) score=\(scoreText)")
    }

    private func contourDebugSummary(for points: [CGPoint], guide: [CGPoint]) -> String {
        let bounds = debugBounds(for: points)
        let guideBounds = debugBounds(for: guide)
        let areaRatio = debugPolygonArea(points) / max(0.0001, debugPolygonArea(guide))
        let overlap = debugOverlapRatio(bounds, with: guideBounds)
        let inside = debugInsideRatio(points, guide: guide)
        let topProfile = debugTopProfile(for: points)

        return String(
            format: "points=%d bounds=(%.3f,%.3f %.3fx%.3f) areaRatio=%.3f overlap=%.3f inside=%.3f topRange=%.3f topSlope=%.3f",
            points.count,
            Double(bounds.minX),
            Double(bounds.minY),
            Double(bounds.width),
            Double(bounds.height),
            Double(areaRatio),
            Double(overlap),
            Double(inside),
            Double(topProfile.range),
            Double(topProfile.slope)
        )
    }

    private func debugTopProfile(for points: [CGPoint]) -> (range: CGFloat, slope: CGFloat) {
        guard points.count >= 3 else {
            return (0, 0)
        }

        let bounds = debugBounds(for: points)
        let upperLimit = bounds.minY + bounds.height * 0.35
        let topPoints = points.filter { $0.y <= upperLimit }

        guard topPoints.count >= 3,
              let minY = topPoints.map(\.y).min(),
              let maxY = topPoints.map(\.y).max()
        else {
            return (0, 0)
        }

        let left = topPoints.min { first, second in first.x < second.x } ?? .zero
        let right = topPoints.max { first, second in first.x < second.x } ?? .zero
        let slope = abs(right.y - left.y) / max(0.0001, abs(right.x - left.x))

        return (maxY - minY, slope)
    }

    private func debugBounds(for points: [CGPoint]) -> CGRect {
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

    private func debugPolygonArea(_ points: [CGPoint]) -> CGFloat {
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

    private func debugOverlapRatio(_ rect: CGRect, with otherRect: CGRect) -> CGFloat {
        let intersection = rect.intersection(otherRect)
        guard !intersection.isNull, rect.width > 0, rect.height > 0 else {
            return 0
        }

        return intersection.width * intersection.height / (rect.width * rect.height)
    }

    private func debugInsideRatio(_ points: [CGPoint], guide: [CGPoint]) -> CGFloat {
        guard !points.isEmpty else {
            return 0
        }

        let insideCount = points.filter { debugContains($0, in: guide) }.count
        return CGFloat(insideCount) / CGFloat(points.count)
    }

    private func debugContains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
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

        if let lineColorContour = LineColorContourExtractor.detectContour(in: image, guidedBy: guide) {
            candidates.append(
                ContourCandidate(
                    contour: lineColorContour,
                    source: .lineColorContour,
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
    }

    private func openCutoutWindow(configuration: MemoPreviewConfiguration = MemoPreviewConfiguration()) {
        guard let memoImage, let appliedContour else {
            return
        }
        let maskContour = configuration.editedContour ?? ContourPadding.expanded(
            appliedContour,
            imageSize: memoImage.size,
            paddingPixels: configuration.contourPaddingPixels - AppDefaults.contourMaskInsetPixels
        )
        let bounds = normalizedBounds(for: maskContour)
        let cutoutImage = CutoutImageRenderer.renderCrop(
            image: memoImage,
            bounds: bounds,
            opacity: configuration.paperOpacity,
            brightness: configuration.paperBrightness
        ) ?? memoImage

        CutoutWindowManager.shared.openWindow(
            image: cutoutImage,
            contour: maskContour,
            bounds: bounds,
            text: memoText,
            opacity: configuration.paperOpacity,
            contourBlurRadius: configuration.contourBlurRadius,
            contourBlurMode: configuration.contourBlurMode,
            textPath: configuration.textPath
        )
    }

    private func resetContour() {
        tracePoints = []
        appliedContour = nil
        roughContour = nil
        subjectImage = nil
        didUseDetectedContour = false
        isTracingContour = false
        contourSelectionCandidates = []
        selectedContourCandidateID = nil
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

        return appliedContour
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

enum LineColorContourExtractor {
    static func detectContour(in image: NSImage, guidedBy guide: [CGPoint]) -> [CGPoint]? {
        guard
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

        let guideBounds = normalizedBounds(for: guide).insetBy(dx: -0.02, dy: -0.02).clampedToUnit()
        guard guideBounds.width > 0.04, guideBounds.height > 0.04 else {
            return nil
        }

        let center = centerPoint(for: guide, bounds: guideBounds)
        let samplePoints = resampledClosedPath(guide, targetCount: max(80, AppDefaults.lineColorContourRayCount))
        var hits: [(point: CGPoint, distanceFromGuide: CGFloat)] = []

        for guidePoint in samplePoints {
            if let hit = firstLineColorHitFromGuide(
                bitmap: bitmap,
                width: width,
                height: height,
                guidePoint: guidePoint,
                center: center,
                guide: guide,
                guideBounds: guideBounds
            ) {
                hits.append(hit)
            }
        }

        let minimumPoints = Int(CGFloat(samplePoints.count) * AppDefaults.lineColorContourMinimumPointRatio)
        guard hits.count >= minimumPoints else {
            return nil
        }

        let filteredHits = removeInwardDistanceOutliers(hits)
        guard filteredHits.count >= max(12, minimumPoints / 2) else {
            return nil
        }

        let simplified = simplify(filteredHits.map(\.point), minimumDistance: 0.006)
        guard simplified.count >= 8 else {
            return nil
        }

        return ContourSmoother.densify(simplified, maxSegmentLength: 0.014)
    }

    private static func firstLineColorHitFromGuide(
        bitmap: NSBitmapImageRep,
        width: Int,
        height: Int,
        guidePoint: CGPoint,
        center: CGPoint,
        guide: [CGPoint],
        guideBounds: CGRect
    ) -> (point: CGPoint, distanceFromGuide: CGFloat)? {
        let vectorToCenter = CGPoint(x: center.x - guidePoint.x, y: center.y - guidePoint.y)
        let distanceToCenter = hypot(vectorToCenter.x, vectorToCenter.y)
        guard distanceToCenter > 0.0001 else {
            return nil
        }

        let direction = CGPoint(x: vectorToCenter.x / distanceToCenter, y: vectorToCenter.y / distanceToCenter)
        let maximumDistance = min(
            distanceToCenter,
            max(0.035, AppDefaults.lineColorContourMaximumInwardSearchDistance)
        )
        let steps = 180
        let backgroundColor = averageStartColor(
            bitmap: bitmap,
            width: width,
            height: height,
            guidePoint: guidePoint,
            direction: direction,
            maximumDistance: maximumDistance,
            guide: guide,
            guideBounds: guideBounds
        )
        var seedColor: LineColorSample?
        var firstMatchingPoint: CGPoint?
        var firstMatchingDistance: CGFloat = 0

        for stepIndex in 0...steps {
            let distance = CGFloat(stepIndex) / CGFloat(steps) * maximumDistance
            let point = CGPoint(
                x: guidePoint.x + direction.x * distance,
                y: guidePoint.y + direction.y * distance
            )

            guard guideBounds.contains(point) else {
                if seedColor != nil {
                    break
                }
                continue
            }

            guard let color = color(at: point, bitmap: bitmap, width: width, height: height) else {
                continue
            }

            if let seedColor {
                if color.distance(to: seedColor) <= AppDefaults.lineColorContourMaximumSeedDistance {
                    continue
                }

                break
            }

            guard
                distance > 0.004,
                isLineColorSeed(color),
                backgroundColor.map({ color.distance(to: $0) >= AppDefaults.lineColorContourMinimumBackgroundDistance }) ?? true
            else {
                continue
            }

            seedColor = color
            firstMatchingPoint = point
            firstMatchingDistance = distance
        }

        guard let firstMatchingPoint else {
            return nil
        }

        return (firstMatchingPoint, firstMatchingDistance)
    }

    private static func averageStartColor(
        bitmap: NSBitmapImageRep,
        width: Int,
        height: Int,
        guidePoint: CGPoint,
        direction: CGPoint,
        maximumDistance: CGFloat,
        guide: [CGPoint],
        guideBounds: CGRect
    ) -> LineColorSample? {
        var colors: [LineColorSample] = []
        let sampleCount = 8
        let sampleDistance = min(maximumDistance, 0.018)

        for index in 0..<sampleCount {
            let distance = CGFloat(index) / CGFloat(max(1, sampleCount - 1)) * sampleDistance
            let point = CGPoint(
                x: guidePoint.x + direction.x * distance,
                y: guidePoint.y + direction.y * distance
            )

            guard guideBounds.contains(point),
                  let color = color(at: point, bitmap: bitmap, width: width, height: height)
            else {
                continue
            }

            colors.append(color)
        }

        return LineColorSample.average(colors)
    }

    private static func isLineColorSeed(_ color: LineColorSample) -> Bool {
        color.saturation >= AppDefaults.lineColorContourMinimumSaturation
            && color.luminance >= AppDefaults.lineColorContourMinimumLuminance
            && color.maximumComponent < 0.985
    }

    private static func removeInwardDistanceOutliers(
        _ hits: [(point: CGPoint, distanceFromGuide: CGFloat)]
    ) -> [(point: CGPoint, distanceFromGuide: CGFloat)] {
        guard hits.count >= 12 else {
            return hits
        }

        let sortedDistances = hits.map(\.distanceFromGuide).sorted()
        let median = sortedDistances[sortedDistances.count / 2]
        let tolerance = max(0.03, median * 1.25)

        return hits.filter { abs($0.distanceFromGuide - median) <= tolerance }
    }

    private static func color(at point: CGPoint, bitmap: NSBitmapImageRep, width: Int, height: Int) -> LineColorSample? {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))

        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return nil
        }

        return LineColorSample(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent
        )
    }

    private static func centerPoint(for guide: [CGPoint], bounds: CGRect) -> CGPoint {
        guard !guide.isEmpty else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }

        let sum = guide.reduce(CGPoint.zero) { partialResult, point in
            CGPoint(x: partialResult.x + point.x, y: partialResult.y + point.y)
        }

        return CGPoint(
            x: max(bounds.minX, min(bounds.maxX, sum.x / CGFloat(guide.count))),
            y: max(bounds.minY, min(bounds.maxY, sum.y / CGFloat(guide.count)))
        )
    }

    private static func resampledClosedPath(_ points: [CGPoint], targetCount: Int) -> [CGPoint] {
        guard points.count >= 2, targetCount > 0 else {
            return points
        }

        let segmentLengths = points.indices.map { index in
            let current = points[index]
            let next = points[(index + 1) % points.count]
            return hypot(next.x - current.x, next.y - current.y)
        }
        let perimeter = segmentLengths.reduce(0, +)
        guard perimeter > 0 else {
            return points
        }

        return (0..<targetCount).map { sampleIndex in
            let targetDistance = CGFloat(sampleIndex) / CGFloat(targetCount) * perimeter
            var accumulated: CGFloat = 0

            for index in points.indices {
                let length = segmentLengths[index]
                if accumulated + length >= targetDistance {
                    let current = points[index]
                    let next = points[(index + 1) % points.count]
                    let t = length > 0 ? (targetDistance - accumulated) / length : 0

                    return CGPoint(
                        x: current.x + (next.x - current.x) * t,
                        y: current.y + (next.y - current.y) * t
                    )
                }

                accumulated += length
            }

            return points.last ?? .zero
        }
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

private struct LineColorSample {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var maximumComponent: CGFloat {
        max(red, green, blue)
    }

    var minimumComponent: CGFloat {
        min(red, green, blue)
    }

    var saturation: CGFloat {
        let maximum = maximumComponent
        guard maximum > 0 else {
            return 0
        }

        return (maximum - minimumComponent) / maximum
    }

    var luminance: CGFloat {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    func distance(to other: LineColorSample) -> CGFloat {
        let redDelta = red - other.red
        let greenDelta = green - other.green
        let blueDelta = blue - other.blue

        return sqrt(redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
    }

    static func average(_ colors: [LineColorSample]) -> LineColorSample? {
        guard !colors.isEmpty else {
            return nil
        }

        let total = colors.reduce(LineColorSample(red: 0, green: 0, blue: 0)) { partialResult, color in
            LineColorSample(
                red: partialResult.red + color.red,
                green: partialResult.green + color.green,
                blue: partialResult.blue + color.blue
            )
        }
        let count = CGFloat(colors.count)

        return LineColorSample(
            red: total.red / count,
            green: total.green / count,
            blue: total.blue / count
        )
    }
}

struct DisplayContourCandidate: Identifiable {
    let id: String
    let title: String
    let helpText: String
    let contour: [CGPoint]
    let score: CGFloat?
    let isRecommended: Bool
    let didUseDetectedContour: Bool
    let sortIndex: Int
}

struct ContourCandidate {
    let contour: [CGPoint]
    let source: ContourCandidateSource
    let minimumAreaRatio: CGFloat
    let smoothsContour: Bool

    var displayID: String {
        source.id
    }
}

enum ContourCandidateSource {
    case subjectMask
    case preprocessedContour
    case backgroundDifference
    case lineColorContour
    case coloredRectangle
    case rectangularGuide
    case rawVisionContour

    var id: String {
        switch self {
        case .subjectMask:
            return "subject-mask"
        case .preprocessedContour:
            return "preprocessed-contour"
        case .backgroundDifference:
            return "background-difference"
        case .lineColorContour:
            return "line-color-contour"
        case .coloredRectangle:
            return "colored-rectangle"
        case .rectangularGuide:
            return "rectangular-guide"
        case .rawVisionContour:
            return "raw-vision-contour"
        }
    }

    var displayName: String {
        switch self {
        case .subjectMask:
            return "被写体"
        case .preprocessedContour:
            return "前処理"
        case .backgroundDifference:
            return "背景差分"
        case .lineColorContour:
            return "線色"
        case .coloredRectangle:
            return "色矩形"
        case .rectangularGuide:
            return "矩形補正"
        case .rawVisionContour:
            return "Vision"
        }
    }

    var helpText: String {
        switch self {
        case .subjectMask:
            return "Vision の被写体マスクから作った候補です"
        case .preprocessedContour:
            return "画像を二値化寄りに前処理してから輪郭検出した候補です"
        case .backgroundDifference:
            return "ガイド周辺の背景色との差から作った候補です"
        case .lineColorContour:
            return "なぞった線の近くから内側へ探した明るい有彩色の枠線候補です"
        case .coloredRectangle:
            return "色付きの矩形領域として検出した候補です"
        case .rectangularGuide:
            return "なぞった範囲を矩形として整えた候補です"
        case .rawVisionContour:
            return "Vision の通常輪郭検出から作った候補です"
        }
    }

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
        case .lineColorContour:
            return 0.08
        case .coloredRectangle:
            return -0.04
        case .rectangularGuide:
            return -0.18
        }
    }
}

enum ContourCandidateSelector {
    static func bestCandidate(from candidates: [ContourCandidate], guide: [CGPoint]) -> ContourCandidate? {
        scoredCandidates(from: candidates, guide: guide)
            .filter { $0.score >= CGFloat(AppDefaults.minimumAutoCandidateScore) }
            .max { first, second in first.score < second.score }?
            .candidate
    }

    static func scoredCandidates(from candidates: [ContourCandidate], guide: [CGPoint]) -> [(candidate: ContourCandidate, score: CGFloat)] {
        candidates
            .compactMap { candidate -> (candidate: ContourCandidate, score: CGFloat)? in
                guard let score = score(candidate, guide: guide) else {
                    return nil
                }

                return (candidate, score)
            }
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
    private static let thresholdValues = [0.30, 0.36, 0.42, 0.50]

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

        let candidates = preprocessVariants(ciImage).flatMap { preprocessedImage -> [(points: [CGPoint], score: CGFloat)] in
            let croppedImage = preprocessedImage
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

            return [true, false].compactMap { detectsDarkOnLight -> (points: [CGPoint], score: CGFloat)? in
                let request = VNDetectContoursRequest()
                request.revision = VNDetectContourRequestRevision1
                request.contrastAdjustment = 1.0
                request.detectsDarkOnLight = detectsDarkOnLight
                request.maximumImageDimension = 768

                let handler = VNImageRequestHandler(ciImage: croppedImage, orientation: .up, options: [:])

                do {
                    try handler.perform([request])
                } catch {
                    return nil
                }

                guard let observation = request.results?.first as? VNContoursObservation else {
                    return nil
                }

                return bestContourPoints(
                    in: observation,
                    cropRect: cropRect,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    guide: guide
                )
            }
        }

        guard let bestCandidate = candidates.max(by: { $0.score < $1.score }) else {
            return nil
        }

        let simplified = simplify(bestCandidate.points, minimumDistance: 0.008)

        guard simplified.count >= 8 else {
            return nil
        }

        return simplified
    }

    private static func preprocessVariants(_ image: CIImage) -> [CIImage] {
        let morphology = CIFilter(name: "CIMorphologyMinimum")
        morphology?.setValue(image, forKey: kCIInputImageKey)
        morphology?.setValue(5, forKey: kCIInputRadiusKey)

        guard let morphImage = morphology?.outputImage else {
            return [image]
        }

        var images: [CIImage] = thresholdValues.compactMap { thresholdValue in
            let threshold = CIFilter(name: "CIColorThreshold")
            threshold?.setValue(morphImage, forKey: kCIInputImageKey)
            threshold?.setValue(thresholdValue, forKey: "inputThreshold")
            return threshold?.outputImage
        }

        let controls = CIFilter(name: "CIColorControls")
        controls?.setValue(morphImage, forKey: kCIInputImageKey)
        controls?.setValue(0, forKey: kCIInputSaturationKey)
        controls?.setValue(1.7, forKey: kCIInputContrastKey)

        if let controlledImage = controls?.outputImage {
            images.append(controlledImage)
        }

        if images.isEmpty {
            images.append(morphImage)
        }

        return images
    }

    private static func bestContourPoints(
        in observation: VNContoursObservation,
        cropRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        guide: [CGPoint]
    ) -> (points: [CGPoint], score: CGFloat)? {
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

                guard cropArea >= minArea, cropArea <= maxArea else {
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

                let edgePenalty: CGFloat = touchesCropEdge ? 0.72 : 1
                let score = CGFloat(contour.normalizedPoints.count) * insideRatio * guideOverlap * edgePenalty
                return (points, score)
            }
            .max { first, second in first.score < second.score }
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
    let text: String
    @Binding var configuration: MemoPreviewConfiguration
    let onCancel: () -> Void
    let onCreate: (MemoPreviewConfiguration) -> Void
    @State private var selectedTool = MemoPreviewTool.move
    @State private var draftPath: [CGPoint] = []
    @State private var rasterMask: RasterContourMask?
    @State private var rasterMaskImage: NSImage?
    @State private var isDisplayRangeEditing = false
    @State private var usesStraightLine = false
    @State private var straightLineStart: CGPoint?
    @State private var straightLineEnd: CGPoint?
    @State private var hoverLocation: CGPoint?
    @State private var previewZoom = 1.0
    @State private var lastPreviewZoom = 1.0
    @State private var isTextPathEditing = false
    @State private var textPathDraft: [CGPoint] = []
    @State private var isDetailedExtractionEditing = false
    @State private var detailedExtractionPath: [CGPoint] = []

    private var adjustedContour: [CGPoint] {
        configuration.editedContour ?? ContourPadding.expanded(
            baseContour,
            imageSize: image.size,
            paddingPixels: configuration.contourPaddingPixels - AppDefaults.contourMaskInsetPixels
        )
    }

    private var adjustedBounds: CGRect {
        normalizedBounds(for: adjustedContour)
    }

    private var previewImage: NSImage {
        CutoutImageRenderer.renderCrop(
            image: image,
            bounds: adjustedBounds,
            opacity: configuration.paperOpacity,
            brightness: configuration.paperBrightness
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

                ScrollView(.vertical) {
                    controls
                        .padding(16)
                }
                .frame(width: 300)
            }
        }
        .frame(width: 860, height: 640)
    }

    private var memoPreview: some View {
        GeometryReader { proxy in
            let previewSize = fittedSize(imageSize: previewImage.size, containerSize: proxy.size, zoom: previewZoom)
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
                        if let rasterMaskImage {
                            Image(nsImage: rasterMaskImage)
                                .resizable()
                                .frame(width: previewRect.width, height: previewRect.height)
                                .blur(radius: configuration.contourBlurRadius)
                        } else {
                            ContourMaskView(
                                points: adjustedContour,
                                bounds: adjustedBounds,
                                blurRadius: configuration.contourBlurRadius,
                                mode: configuration.contourBlurMode
                            )
                        }
                    }
                    .position(x: previewRect.midX, y: previewRect.midY)
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)

                BoundedContourShape(points: adjustedContour, bounds: adjustedBounds)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                    .frame(width: previewRect.width, height: previewRect.height)
                    .position(x: previewRect.midX, y: previewRect.midY)

                if let textPath = configuration.textPath {
                    BoundedContourShape(points: textPath, bounds: adjustedBounds)
                        .fill(Color.orange.opacity(0.08))
                        .overlay {
                            BoundedContourShape(points: textPath, bounds: adjustedBounds)
                                .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        }
                        .frame(width: previewRect.width, height: previewRect.height)
                        .position(x: previewRect.midX, y: previewRect.midY)
                }

                if textPathDraft.count > 0 {
                    NormalizedPreviewPath(points: textPathDraft, bounds: adjustedBounds)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: previewRect.width, height: previewRect.height)
                        .position(x: previewRect.midX, y: previewRect.midY)

                    ForEach(Array(textPathDraft.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                            .position(previewPoint(point, in: previewRect, bounds: adjustedBounds))
                    }
                }

                if detailedExtractionPath.count > 0 {
                    NormalizedPreviewPath(points: detailedExtractionPath, bounds: adjustedBounds)
                        .stroke(.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 4]))
                        .frame(width: previewRect.width, height: previewRect.height)
                        .position(x: previewRect.midX, y: previewRect.midY)

                    ForEach(Array(detailedExtractionPath.enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(.purple)
                            .frame(width: 8, height: 8)
                            .position(previewPoint(point, in: previewRect, bounds: adjustedBounds))
                    }
                }

                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(4)
                        .frame(
                            width: 0.62 * previewRect.width,
                            alignment: .leading
                        )
                        .position(
                            x: previewRect.midX,
                            y: previewRect.midY
                        )
                }

                if draftPath.count > 1 {
                    NormalizedPreviewPath(points: draftPath, bounds: adjustedBounds)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: previewRect.width, height: previewRect.height)
                        .position(x: previewRect.midX, y: previewRect.midY)
                }

                if let straightLineStart, let straightLineEnd {
                    NormalizedPreviewPath(points: [straightLineStart, straightLineEnd], bounds: adjustedBounds)
                        .stroke(selectedTool == .eraser ? .red : .blue, style: StrokeStyle(lineWidth: max(2, configuration.brushSizePixels / 4), lineCap: .round))
                        .frame(width: previewRect.width, height: previewRect.height)
                        .position(x: previewRect.midX, y: previewRect.midY)
                }

                if isDisplayRangeEditing,
                   (selectedTool == .pencil || selectedTool == .eraser),
                   let hoverLocation,
                   previewRect.contains(hoverLocation) {
                    Circle()
                        .stroke(selectedTool == .eraser ? .red : .blue, lineWidth: 2)
                        .background(Circle().fill((selectedTool == .eraser ? Color.red : Color.blue).opacity(0.08)))
                        .frame(
                            width: brushDisplayDiameter(in: previewRect, bounds: adjustedBounds),
                            height: brushDisplayDiameter(in: previewRect, bounds: adjustedBounds)
                        )
                        .position(hoverLocation)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(editGesture(in: previewRect, bounds: adjustedBounds))
            .simultaneousGesture(zoomGesture())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("表示") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledSlider(
                        title: "薄さ",
                        value: $configuration.paperOpacity,
                        range: 0.2...1.0,
                        suffix: ""
                    )

                    labeledSlider(
                        title: "明度",
                        value: $configuration.paperBrightness,
                        range: -0.15...0.45,
                        suffix: ""
                    )

                    labeledSlider(
                        title: "余白",
                        value: $configuration.contourPaddingPixels,
                        range: 0...80,
                        suffix: "px"
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("輪郭") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledSlider(
                        title: "ぼかし",
                        value: $configuration.contourBlurRadius,
                        range: 0...14,
                        suffix: "px"
                    )

                    Picker("ぼかし方向", selection: $configuration.contourBlurMode) {
                        ForEach(ContourBlurMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        if isDisplayRangeEditing {
                            saveDisplayRangeEdits()
                        } else {
                            startDisplayRangeEditing()
                        }
                    } label: {
                        Label(isDisplayRangeEditing ? "表示範囲を保存" : "表示範囲修正", systemImage: isDisplayRangeEditing ? "checkmark.circle" : "paintbrush")
                    }

                    Picker("編集ツール", selection: $selectedTool) {
                        ForEach(MemoPreviewTool.allCases) { tool in
                            Text(tool.rawValue).tag(tool)
                        }
                    }
                    .disabled(!isDisplayRangeEditing && selectedTool != .move)

                    Toggle("直線", isOn: $usesStraightLine)
                        .disabled(!isDisplayRangeEditing || (selectedTool != .pencil && selectedTool != .eraser))

                    labeledSlider(
                        title: "ブラシ",
                        value: $configuration.brushSizePixels,
                        range: 3...80,
                        suffix: "px"
                    )
                    .disabled(selectedTool != .pencil && selectedTool != .eraser)

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            if isDetailedExtractionEditing {
                                applyDetailedExtraction()
                            } else {
                                startDetailedExtraction()
                            }
                        } label: {
                            Label(isDetailedExtractionEditing ? "詳細抽出を適用" : "部分詳細抽出", systemImage: isDetailedExtractionEditing ? "checkmark.circle" : "scope")
                        }

                        if isDetailedExtractionEditing {
                            Text("複雑な縁だけを囲み、始点付近をクリックするとその範囲だけ再抽出します。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("輪郭リセット") {
                            configuration.editedContour = nil
                            rasterMask = nil
                            rasterMaskImage = nil
                            isDisplayRangeEditing = false
                            isDetailedExtractionEditing = false
                            detailedExtractionPath = []
                        }
                        Button("下書きクリア") {
                            draftPath = []
                            straightLineStart = nil
                            straightLineEnd = nil
                            detailedExtractionPath = []
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("テキスト表示域") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("指定開始後、プレビュー上をクリックして点を置いてください。点は直線で結ばれます。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button {
                        if isTextPathEditing {
                            saveTextPathDraft()
                        } else {
                            startTextPathEditing()
                        }
                    } label: {
                        Label(isTextPathEditing ? "テキスト範囲を保存" : "テキスト範囲指定", systemImage: isTextPathEditing ? "checkmark.circle" : "point.topleft.down.curvedto.point.bottomright.up")
                    }

                    HStack {
                        Button("1点戻す") {
                            if !textPathDraft.isEmpty {
                                textPathDraft.removeLast()
                            }
                        }
                        .disabled(!isTextPathEditing || textPathDraft.isEmpty)

                        Button("下書きクリア") {
                            textPathDraft = []
                        }
                        .disabled(!isTextPathEditing && textPathDraft.isEmpty)
                    }

                    Button("テキスト範囲リセット") {
                        configuration.textPath = nil
                        textPathDraft = []
                        isTextPathEditing = false
                    }
                }
                .padding(.vertical, 4)
            }

            Text("表示範囲修正中はラスターマスクだけを編集します。保存時に輪郭パスへ変換します。")
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

    private func fittedSize(imageSize: CGSize, containerSize: CGSize, zoom: Double = 1) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return containerSize
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height) * 0.86 * CGFloat(zoom)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(x: minX, y: minY, width: max(0.01, maxX - minX), height: max(0.01, maxY - minY))
    }

    private func editGesture(in previewRect: CGRect, bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isTextPathEditing, !isDetailedExtractionEditing, selectedTool != .move, previewRect.contains(value.location) else {
                    return
                }

                let point = normalizedPoint(value.location, previewRect: previewRect, bounds: bounds)

                switch selectedTool {
                case .pencil:
                    guard isDisplayRangeEditing else { return }
                    if usesStraightLine {
                        updateStraightLine(to: point)
                    } else {
                        paintMask(at: point, mode: .draw)
                    }
                case .eraser:
                    guard isDisplayRangeEditing else { return }
                    if usesStraightLine {
                        updateStraightLine(to: point)
                    } else {
                        paintMask(at: point, mode: .erase)
                    }
                case .move:
                    break
                }
            }
            .onEnded { value in
                if isTextPathEditing {
                    guard previewRect.contains(value.location) else {
                        return
                    }

                    let point = normalizedPoint(value.location, previewRect: previewRect, bounds: bounds)
                    if shouldCloseTextPath(with: point) {
                        saveTextPathDraft()
                        return
                    }

                    appendTextPathPoint(point)
                    return
                }

                if isDetailedExtractionEditing {
                    guard previewRect.contains(value.location) else {
                        return
                    }

                    let point = normalizedPoint(value.location, previewRect: previewRect, bounds: bounds)
                    if shouldCloseDetailedExtractionPath(with: point) {
                        applyDetailedExtraction()
                        return
                    }

                    appendDetailedExtractionPoint(point)
                    return
                }

                switch selectedTool {
                case .pencil, .eraser:
                    guard isDisplayRangeEditing else { return }
                    if usesStraightLine {
                        commitStraightLine()
                    }
                case .move:
                    break
                }

                draftPath = []
            }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                previewZoom = min(4, max(0.45, lastPreviewZoom * value))
            }
            .onEnded { _ in
                lastPreviewZoom = previewZoom
            }
    }

    private func startDisplayRangeEditing() {
        rasterMask = RasterContourMask(contour: adjustedContour)
        rasterMaskImage = rasterMask?.maskImage(in: adjustedBounds)
        isDisplayRangeEditing = true
        isDetailedExtractionEditing = false
        detailedExtractionPath = []
        if selectedTool == .move {
            selectedTool = .pencil
        }
    }

    private func saveDisplayRangeEdits() {
        commitRasterMask()
        isDisplayRangeEditing = false
        rasterMask = nil
        rasterMaskImage = nil
        straightLineStart = nil
        straightLineEnd = nil
        isDetailedExtractionEditing = false
        detailedExtractionPath = []
    }

    private func startTextPathEditing() {
        isTextPathEditing = true
        isDetailedExtractionEditing = false
        detailedExtractionPath = []
        selectedTool = .move
        textPathDraft = configuration.textPath ?? []
    }

    private func startDetailedExtraction() {
        if rasterMask == nil {
            rasterMask = RasterContourMask(contour: adjustedContour)
            rasterMaskImage = rasterMask?.maskImage(in: adjustedBounds)
        }

        isDisplayRangeEditing = true
        isTextPathEditing = false
        textPathDraft = []
        isDetailedExtractionEditing = true
        selectedTool = .move
        detailedExtractionPath = []
    }

    private func applyDetailedExtraction() {
        guard detailedExtractionPath.count >= 3 else {
            isDetailedExtractionEditing = false
            detailedExtractionPath = []
            return
        }

        if rasterMask == nil {
            rasterMask = RasterContourMask(contour: adjustedContour)
        }

        rasterMask?.refineRegion(
            image: image,
            roi: detailedExtractionPath,
            keepInteriorFilled: true
        )
        rasterMaskImage = rasterMask?.maskImage(in: adjustedBounds)
        isDetailedExtractionEditing = false
        detailedExtractionPath = []
    }

    private func saveTextPathDraft() {
        guard textPathDraft.count >= 3 else {
            isTextPathEditing = false
            textPathDraft = []
            return
        }

        configuration.textPath = ContourSmoother.polished(textPathDraft)
        isTextPathEditing = false
        textPathDraft = []
    }

    private func appendTextPathPoint(_ point: CGPoint) {
        guard let lastPoint = textPathDraft.last else {
            textPathDraft.append(point)
            return
        }

        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 0.006 {
            textPathDraft.append(point)
        }
    }

    private func shouldCloseTextPath(with point: CGPoint) -> Bool {
        guard let firstPoint = textPathDraft.first, textPathDraft.count >= 3 else {
            return false
        }

        return hypot(point.x - firstPoint.x, point.y - firstPoint.y) <= 0.025
    }

    private func appendDetailedExtractionPoint(_ point: CGPoint) {
        guard let lastPoint = detailedExtractionPath.last else {
            detailedExtractionPath.append(point)
            return
        }

        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 0.006 {
            detailedExtractionPath.append(point)
        }
    }

    private func shouldCloseDetailedExtractionPath(with point: CGPoint) -> Bool {
        guard let firstPoint = detailedExtractionPath.first, detailedExtractionPath.count >= 3 else {
            return false
        }

        return hypot(point.x - firstPoint.x, point.y - firstPoint.y) <= 0.025
    }

    private func appendDraftPoint(_ point: CGPoint) {
        guard let lastPoint = draftPath.last else {
            draftPath.append(point)
            return
        }

        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 0.004 {
            draftPath.append(point)
        }
    }

    private func paintMask(at point: CGPoint, mode: RasterContourMask.PaintMode) {
        if rasterMask == nil {
            rasterMask = RasterContourMask(contour: adjustedContour)
        }

        rasterMask?.paintCircle(
            at: point,
            radiusPixels: CGFloat(configuration.brushSizePixels) / 2,
            mode: mode
        )

        rasterMaskImage = rasterMask?.maskImage(in: adjustedBounds)
    }

    private func updateStraightLine(to point: CGPoint) {
        if straightLineStart == nil {
            straightLineStart = point
        }

        straightLineEnd = point
    }

    private func commitStraightLine() {
        guard let straightLineStart, let straightLineEnd else {
            return
        }

        if rasterMask == nil {
            rasterMask = RasterContourMask(contour: adjustedContour)
        }

        rasterMask?.paintLine(
            from: straightLineStart,
            to: straightLineEnd,
            radiusPixels: CGFloat(configuration.brushSizePixels) / 2,
            mode: selectedTool == .eraser ? .erase : .draw
        )
        rasterMaskImage = rasterMask?.maskImage(in: adjustedBounds)
        self.straightLineStart = nil
        self.straightLineEnd = nil
    }

    private func commitRasterMask() {
        guard let rasterMask, let contour = rasterMask.contourPoints() else {
            rasterMaskImage = nil
            return
        }

        configuration.editedContour = ContourSmoother.polished(contour)
        rasterMaskImage = nil
    }

    private func brushDisplayDiameter(in previewRect: CGRect, bounds: CGRect) -> CGFloat {
        let normalizedDiameter = CGFloat(configuration.brushSizePixels) / CGFloat(RasterContourMask.defaultResolution)
        let scale = min(previewRect.width / max(0.0001, bounds.width), previewRect.height / max(0.0001, bounds.height))

        return max(4, normalizedDiameter * scale)
    }

    private func previewPoint(_ point: CGPoint, in previewRect: CGRect, bounds: CGRect) -> CGPoint {
        CGPoint(
            x: previewRect.minX + (point.x - bounds.minX) / bounds.width * previewRect.width,
            y: previewRect.minY + (point.y - bounds.minY) / bounds.height * previewRect.height
        )
    }

    private func normalizedPoint(_ location: CGPoint, previewRect: CGRect, bounds: CGRect) -> CGPoint {
        let localX = max(0, min(1, (location.x - previewRect.minX) / previewRect.width))
        let localY = max(0, min(1, (location.y - previewRect.minY) / previewRect.height))

        return CGPoint(
            x: bounds.minX + localX * bounds.width,
            y: bounds.minY + localY * bounds.height
        )
    }
}

struct RasterContourMask {
    static let defaultResolution = 640

    enum PaintMode {
        case draw
        case erase
    }

    let width: Int
    let height: Int
    private var pixels: [UInt8]

    init(contour: [CGPoint], resolution: Int = RasterContourMask.defaultResolution) {
        width = resolution
        height = resolution
        pixels = Array(repeating: 0, count: resolution * resolution)

        guard contour.count >= 3 else {
            return
        }

        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )

                if contains(point, in: contour) {
                    pixels[y * width + x] = 255
                }
            }
        }
    }

    mutating func paintCircle(at point: CGPoint, radiusPixels: CGFloat, mode: PaintMode) {
        let centerX = Int((point.x * CGFloat(width)).rounded())
        let centerY = Int((point.y * CGFloat(height)).rounded())
        let radius = max(1, Int(radiusPixels.rounded()))
        let radiusSquared = radius * radius
        let value: UInt8 = mode == .draw ? 255 : 0
        let minX = max(0, centerX - radius)
        let maxX = min(width - 1, centerX + radius)
        let minY = max(0, centerY - radius)
        let maxY = min(height - 1, centerY + radius)

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = x - centerX
                let dy = y - centerY

                if dx * dx + dy * dy <= radiusSquared {
                    pixels[y * width + x] = value
                }
            }
        }
    }

    mutating func paintLine(from start: CGPoint, to end: CGPoint, radiusPixels: CGFloat, mode: PaintMode) {
        let startX = start.x * CGFloat(width)
        let startY = start.y * CGFloat(height)
        let endX = end.x * CGFloat(width)
        let endY = end.y * CGFloat(height)
        let distance = hypot(endX - startX, endY - startY)
        let steps = max(1, Int(ceil(distance / max(1, radiusPixels * 0.45))))

        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(
                x: (startX + (endX - startX) * t) / CGFloat(width),
                y: (startY + (endY - startY) * t) / CGFloat(height)
            )

            paintCircle(at: point, radiusPixels: radiusPixels, mode: mode)
        }
    }

    mutating func refineRegion(image: NSImage, roi: [CGPoint], keepInteriorFilled: Bool) {
        guard roi.count >= 3,
              let sampler = ImageColorSampler(image: image)
        else {
            return
        }

        let roiBounds = normalizedBounds(for: roi)
        let minX = max(0, Int(floor(roiBounds.minX * CGFloat(width))))
        let maxX = min(width - 1, Int(ceil(roiBounds.maxX * CGFloat(width))))
        let minY = max(0, Int(floor(roiBounds.minY * CGFloat(height))))
        let maxY = min(height - 1, Int(ceil(roiBounds.maxY * CGFloat(height))))
        let localWidth = max(1, maxX - minX + 1)
        let localHeight = max(1, maxY - minY + 1)
        let threshold = AppDefaults.detailedExtractionColorDistanceThreshold

        guard let backgroundColor = estimatedBackgroundColor(
            sampler: sampler,
            roi: roi,
            bounds: roiBounds
        ) else {
            return
        }

        var inside = Array(repeating: false, count: localWidth * localHeight)
        var background = Array(repeating: false, count: localWidth * localHeight)

        for y in minY...maxY {
            for x in minX...maxX {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )
                let index = (y - minY) * localWidth + (x - minX)

                guard contains(point, in: roi) else {
                    continue
                }

                let color = sampler.color(at: point)
                inside[index] = true
                background[index] = color.distance(to: backgroundColor) <= threshold
            }
        }

        let outside = floodBackground(
            inside: inside,
            background: background,
            width: localWidth,
            height: localHeight
        )

        for y in minY...maxY {
            for x in minX...maxX {
                let index = (y - minY) * localWidth + (x - minX)

                guard inside[index] else {
                    continue
                }

                pixels[y * width + x] = outside[index] ? 0 : 255
            }
        }
    }

    func contourPoints(rayCount: Int = 240) -> [CGPoint]? {
        guard let bounds = filledBounds() else {
            return nil
        }

        let center = CGPoint(
            x: CGFloat(bounds.midX) / CGFloat(width),
            y: CGFloat(bounds.midY) / CGFloat(height)
        )
        let maximumRadius = hypot(CGFloat(bounds.width), CGFloat(bounds.height)) / CGFloat(max(width, height)) * 0.72
        var points: [CGPoint] = []

        for index in 0..<rayCount {
            let angle = CGFloat(index) / CGFloat(rayCount) * 2 * .pi
            var bestPoint: CGPoint?

            for step in 0...320 {
                let radius = CGFloat(step) / 320 * maximumRadius
                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )

                guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else {
                    continue
                }

                if isFilled(point) {
                    bestPoint = point
                }
            }

            if let bestPoint {
                points.append(bestPoint)
            }
        }

        guard points.count >= rayCount / 3 else {
            return nil
        }

        return points
    }

    func maskImage(in bounds: CGRect) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let outputWidth = max(1, Int((bounds.width * CGFloat(width)).rounded()))
        let outputHeight = max(1, Int((bounds.height * CGFloat(height)).rounded()))
        let image = NSImage(size: NSSize(width: outputWidth, height: outputHeight))

        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let normalizedPoint = CGPoint(
                    x: bounds.minX + (CGFloat(x) + 0.5) / CGFloat(outputWidth) * bounds.width,
                    y: bounds.minY + (CGFloat(y) + 0.5) / CGFloat(outputHeight) * bounds.height
                )

                guard isFilled(normalizedPoint) else {
                    continue
                }

                NSColor.white.setFill()
                CGRect(x: x, y: outputHeight - y - 1, width: 1, height: 1).fill()
            }
        }

        return image
    }

    private func estimatedBackgroundColor(
        sampler: ImageColorSampler,
        roi: [CGPoint],
        bounds: CGRect
    ) -> SampledColor? {
        let step = AppDefaults.detailedExtractionBoundarySampleStep
        let minX = max(0, Int(floor(bounds.minX * CGFloat(width))))
        let maxX = min(width - 1, Int(ceil(bounds.maxX * CGFloat(width))))
        let minY = max(0, Int(floor(bounds.minY * CGFloat(height))))
        let maxY = min(height - 1, Int(ceil(bounds.maxY * CGFloat(height))))
        let boundaryDistance = max(0.006, min(bounds.width, bounds.height) * 0.08)
        var colors: [SampledColor] = []

        guard minX <= maxX, minY <= maxY else {
            return nil
        }

        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(width),
                    y: (CGFloat(y) + 0.5) / CGFloat(height)
                )

                guard contains(point, in: roi),
                      distanceToPolygon(point, polygon: roi) <= boundaryDistance
                else {
                    continue
                }

                colors.append(sampler.color(at: point))
            }
        }

        guard !colors.isEmpty else {
            return nil
        }

        return SampledColor.average(colors)
    }

    private func floodBackground(
        inside: [Bool],
        background: [Bool],
        width: Int,
        height: Int
    ) -> [Bool] {
        var visited = Array(repeating: false, count: width * height)
        var queue: [Int] = []
        var cursor = 0

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return
            }

            let index = y * width + x
            guard inside[index], background[index], !visited[index] else {
                return
            }

            visited[index] = true
            queue.append(index)
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }

        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width

            enqueue(x + 1, y)
            enqueue(x - 1, y)
            enqueue(x, y + 1)
            enqueue(x, y - 1)
        }

        return visited
    }

    private func isFilled(_ point: CGPoint) -> Bool {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))

        return pixels[y * width + x] > 0
    }

    private func filledBounds() -> CGRect? {
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var hasPixel = false

        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                hasPixel = true
            }
        }

        guard hasPixel else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    private func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1

        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    private func distanceToPolygon(_ point: CGPoint, polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 2 else {
            return .greatestFiniteMagnitude
        }

        var distance = CGFloat.greatestFiniteMagnitude
        var previous = polygon[polygon.count - 1]

        for current in polygon {
            distance = min(distance, distanceToSegment(point, start: previous, end: current))
            previous = current
        }

        return distance
    }

    private func distanceToSegment(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + dx * t, y: start.y + dy * t)

        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
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

private struct SampledColor {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    func distance(to other: SampledColor) -> CGFloat {
        let redDiff = red - other.red
        let greenDiff = green - other.green
        let blueDiff = blue - other.blue

        return sqrt(redDiff * redDiff + greenDiff * greenDiff + blueDiff * blueDiff)
    }

    static func average(_ colors: [SampledColor]) -> SampledColor {
        guard !colors.isEmpty else {
            return SampledColor(red: 1, green: 1, blue: 1)
        }

        let totals = colors.reduce((red: CGFloat(0), green: CGFloat(0), blue: CGFloat(0))) { result, color in
            (
                red: result.red + color.red,
                green: result.green + color.green,
                blue: result.blue + color.blue
            )
        }
        let count = CGFloat(colors.count)

        return SampledColor(
            red: totals.red / count,
            green: totals.green / count,
            blue: totals.blue / count
        )
    }
}

private final class ImageColorSampler {
    private let bitmap: NSBitmapImageRep
    private let width: Int
    private let height: Int

    init?(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        bitmap = NSBitmapImageRep(cgImage: cgImage)
        width = bitmap.pixelsWide
        height = bitmap.pixelsHigh
    }

    func color(at normalizedPoint: CGPoint) -> SampledColor {
        let x = min(width - 1, max(0, Int(normalizedPoint.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(normalizedPoint.y * CGFloat(height))))
        let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .white

        return SampledColor(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent
        )
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
        contourBlurMode: ContourBlurMode,
        textPath: [CGPoint]?
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
                contourBlurMode: contourBlurMode,
                textPath: textPath
            ),
            contour: contour,
            bounds: bounds,
            interactionContour: textPath
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
    private let interactionContour: [CGPoint]?
    private let normalizedBounds: CGRect

    init(rootView: Content, contour: [CGPoint], bounds: CGRect, interactionContour: [CGPoint]? = nil) {
        self.contour = contour
        self.interactionContour = interactionContour
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
        self.interactionContour = nil
        self.normalizedBounds = .unit
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard contains(point, in: contour) else {
            return nil
        }

        if let interactionContour, !contains(point, in: interactionContour) {
            return nil
        }

        return super.hitTest(point)
    }

    private func contains(_ point: CGPoint, in points: [CGPoint]) -> Bool {
        guard !points.isEmpty, bounds.contains(point) else {
            return false
        }

        return contourPath(points: points, in: bounds).contains(point)
    }

    private func contourPath(points: [CGPoint], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let localPoints = points.map { point in
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
    let contourBlurMode: ContourBlurMode
    let textPath: [CGPoint]?

    private var textEditingContour: [CGPoint] {
        textPath ?? contour
    }

    private var textEditingBounds: CGRect {
        normalizedBounds(for: textEditingContour)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let textFrame = rect(for: textEditingBounds, in: size)

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Color.white
                        .frame(width: size.width, height: size.height)

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: size.width, height: size.height)

                    ShapedTextEditor(
                        text: $text,
                        contour: textEditingContour,
                        bounds: textEditingBounds,
                        fontSize: max(17, size.width * 0.06)
                    )
                    .frame(width: textFrame.width, height: textFrame.height)
                    .position(x: textFrame.midX, y: textFrame.midY)
                }
                .frame(width: size.width, height: size.height)
                .mask {
                    ContourMaskView(
                        points: contour,
                        bounds: bounds,
                        blurRadius: contourBlurRadius,
                        mode: contourBlurMode
                    )
                }
            }
            .background(Color.clear)
        }
    }

    private func normalizedBounds(for points: [CGPoint]) -> CGRect {
        let minX = points.map(\.x).min() ?? bounds.minX
        let maxX = points.map(\.x).max() ?? bounds.maxX
        let minY = points.map(\.y).min() ?? bounds.minY
        let maxY = points.map(\.y).max() ?? bounds.maxY

        return CGRect(
            x: minX,
            y: minY,
            width: max(0.01, maxX - minX),
            height: max(0.01, maxY - minY)
        )
    }

    private func rect(for normalizedRect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: (normalizedRect.minX - bounds.minX) / bounds.width * size.width,
            y: (normalizedRect.minY - bounds.minY) / bounds.height * size.height,
            width: normalizedRect.width / bounds.width * size.width,
            height: normalizedRect.height / bounds.height * size.height
        )
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

struct ContourMaskView: View {
    let points: [CGPoint]
    let bounds: CGRect
    let blurRadius: Double
    let mode: ContourBlurMode

    var body: some View {
        let shape = BoundedContourShape(points: points, bounds: bounds)

        Group {
            if blurRadius <= 0 {
                shape
            } else {
                switch mode {
                case .outside:
                    shape.blur(radius: blurRadius)
                case .inside:
                    shape
                        .blur(radius: blurRadius)
                        .mask(shape)
                case .both:
                    shape.blur(radius: blurRadius)
                }
            }
        }
    }
}

struct NormalizedPreviewPath: Shape {
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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = ShapedNSTextView()
        textView.onLayout = { textView in
            let visibleSize = textView.enclosingScrollView?.contentSize ?? textView.bounds.size
            textView.textContainer?.containerSize = CGSize(width: visibleSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.exclusionPaths = TextExclusionPathBuilder.paths(
                contour: contour,
                bounds: bounds,
                size: visibleSize,
                fontSize: fontSize
            )
        }
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ShapedNSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.font = .systemFont(ofSize: fontSize, weight: .regular)
        let visibleSize = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: visibleSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = CGSize(width: visibleSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? visibleSize.height
        textView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: visibleSize.width, height: max(visibleSize.height, usedHeight + fontSize * 2))
        )
        textView.textContainer?.exclusionPaths = TextExclusionPathBuilder.paths(
            contour: contour,
            bounds: bounds,
            size: visibleSize,
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            selectAll(nil)
        case "c":
            copy(nil)
        case "v":
            paste(nil)
        case "x":
            cut(nil)
        case "z":
            undoManager?.undo()
        default:
            return super.performKeyEquivalent(with: event)
        }

        return true
    }

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
        let horizontalInset = max(6, size.width * 0.025)
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
