import Foundation
import CoreGraphics

enum RulerKind: String, Codable, CaseIterable, Identifiable {
    case perspective, isometric, vanishing, radial, perspectiveEllipse, straight, parallel, connected, ellipse
    var id: String { rawValue }
    var supportsAxisCycling: Bool { self == .isometric || self == .perspective || self == .vanishing }
    var title: String {
        switch self {
        case .straight: "Straight line"
        case .parallel: "Parallel lines"
        case .connected: "Connected lines"
        case .ellipse: "Ellipse"
        case .perspective: "Perspective"
        case .isometric: "Isometric"
        case .vanishing: "Vanishing lines"
        case .radial: "Radial lines"
        case .perspectiveEllipse: "Perspective ellipse"
        }
    }
}

struct RulerPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

// A pinhole camera: screen axes are X/right and Y/down, with positive Z in front.
// Homogeneous vanishing directions also represent parallel axes without huge coordinates.
struct RulerCameraAxis: Codable, Equatable {
    var azimuth: Double
    var incline: Double
}
enum RulerCameraPlane: String, Codable, CaseIterable { case xy, xz, yz
    var axes: (Int, Int) {
        switch self { case .xy: (0, 1); case .xz: (0, 2); case .yz: (1, 2) }
    }
}

struct RulerCamera: Codable, Equatable {
    var points = 3
    var fieldOfView = 60.0
    var viewRadius = 600.0
    var yaw = 45.0
    var pitch = 20.0
    var roll = 0.0
    var customAxes: [RulerCameraAxis]?
    var worldAxesSettings: [RulerCameraAxis] {
        get { customAxes ?? [RulerCameraAxis(azimuth: 0, incline: 0), RulerCameraAxis(azimuth: 0, incline: 90), RulerCameraAxis(azimuth: 90, incline: 0)] }
        set { customAxes = newValue }
    }
    mutating func enableCustomAxes(_ enabled: Bool) {
        if !enabled { customAxes = nil; return }
        if customAxes == nil { customAxes = worldAxesSettings }
        if points < 3 { if points == 1 { yaw = 0 }; pitch = 0; points = 3 }
    }
    var focalLength: Double { viewRadius / tan(fieldOfView * .pi / 360) }
    var axes: [SIMD3<Double>] {
        let y = (points == 1 ? 0 : yaw) * .pi / 180
        let p = (points < 3 ? 0 : pitch) * .pi / 180, r = roll * .pi / 180
        let world: [SIMD3<Double>]
        if points == 3, let customAxes {
            world = customAxes.map { axis in
                if axis.incline == 90 { return SIMD3(0, 1, 0) }
                if axis.incline == -90 { return SIMD3(0, -1, 0) }
                let azimuth = axis.azimuth * .pi / 180 + y, incline = axis.incline * .pi / 180
                return SIMD3(cos(azimuth) * cos(incline), sin(incline), sin(azimuth) * cos(incline))
            }
        } else { world = [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))] }
        return world.map { v in
            let vy = v.y * cos(p) - v.z * sin(p), vz = v.y * sin(p) + v.z * cos(p)
            return SIMD3(v.x * cos(r) - vy * sin(r), v.x * sin(r) + vy * cos(r), vz)
        }
    }
    func directions(center: CGPoint, anchor: CGPoint) -> [CGPoint] {
        axes.map { CGPoint(x: focalLength * $0.x + (center.x - anchor.x) * $0.z,
                           y: focalLength * $0.y + (center.y - anchor.y) * $0.z) }
    }
    func project(_ point: SIMD3<Double>, center: CGPoint) -> CGPoint? {
        guard point.z > focalLength * 0.01 else { return nil }
        let projected = CGPoint(x: center.x + focalLength * point.x / point.z, y: center.y + focalLength * point.y / point.z)
        return projected.x.isFinite && projected.y.isFinite && abs(projected.x) <= 100000 && abs(projected.y) <= 100000 ? projected : nil
    }
    func validate() throws {
        if let customAxes {
            guard customAxes.count == 3, customAxes.allSatisfy({ $0.azimuth.isFinite && abs($0.azimuth) <= 360 && $0.incline.isFinite && (-90...90).contains($0.incline) }) else {
                throw SettingsError.invalid("Camera axes need three finite azimuths within ±360° and inclines within ±90°.")
            }
        }
        guard (1...3).contains(points), fieldOfView.isFinite, (5...160).contains(fieldOfView),
              viewRadius.isFinite, (20...20000).contains(viewRadius),
              [yaw, pitch, roll].allSatisfy({ $0.isFinite && abs($0) <= 360 }) else {
            throw SettingsError.invalid("Camera needs 1–3 point perspective, FOV 5–160°, radius 20–20,000 points and finite angles within ±360°.")
        }
    }
}
struct RulerMeasurements: Codable, Equatable {
    var visible = false
    var distance = 50.0
    var divisions = 1
    func validate() throws {
        guard distance.isFinite, (2...10000).contains(distance), (1...10).contains(divisions) else {
            throw SettingsError.invalid("Ruler tick distance must be 2–10,000 points, with 1–10 subdivisions.")
        }
    }
}

// Shared unit-plane homography for projected circles and perspective-preserving edits.
struct RulerPlane {
    private let a, b, c, d, e, f, g, h: Double
    init?(_ corners: [RulerPoint]) {
        guard corners.count == 4 else { return nil }
        let p = corners.map(\.cg)
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard abs(cross) > 1e-6 else { return nil }
            if i == 0 { sign = cross }
            guard cross * sign > 0 else { return nil }
        }
        let dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x
        let dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y
        let sx = p[0].x - p[1].x + p[2].x - p[3].x
        let sy = p[0].y - p[1].y + p[2].y - p[3].y
        let det = dx1 * dy2 - dx2 * dy1
        guard abs(det) > 1e-9 else { return nil }
        g = (sx * dy2 - dx2 * sy) / det; h = (dx1 * sy - sx * dy1) / det
        a = p[1].x - p[0].x + g * p[1].x; b = p[3].x - p[0].x + h * p[3].x
        d = p[1].y - p[0].y + g * p[1].y; e = p[3].y - p[0].y + h * p[3].y
        c = p[0].x; f = p[0].y
    }
    func homogeneous(_ point: CGPoint) -> SIMD3<Double> {
        SIMD3(a * point.x + b * point.y + c, d * point.x + e * point.y + f, g * point.x + h * point.y + 1)
    }
    var horizon: SIMD3<Double> { SIMD3(d * h - g * e, g * b - a * h, a * e - d * b) }
    func inverseHomogeneous(_ q: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((e - f * h) * q.x + (c * h - b) * q.y + (b * f - c * e) * q.z,
              (f * g - d) * q.x + (a - c * g) * q.y + (c * d - a * f) * q.z,
              (d * h - e * g) * q.x + (b * g - a * h) * q.y + (a * e - b * d) * q.z)
    }
    func screen(_ point: CGPoint) -> CGPoint? {
        let w = g * point.x + h * point.y + 1
        guard w > 1e-8 else { return nil }
        let result = CGPoint(x: (a * point.x + b * point.y + c) / w,
                             y: (d * point.x + e * point.y + f) / w)
        return result.x.isFinite && result.y.isFinite && abs(result.x) <= 100000 && abs(result.y) <= 100000 ? result : nil
    }
    func unit(_ point: CGPoint) -> CGPoint? {
        let aa = a - point.x * g, bb = b - point.x * h
        let dd = d - point.y * g, ee = e - point.y * h
        let det = aa * ee - bb * dd
        guard abs(det) > 1e-9 else { return nil }
        let u = ((point.x - c) * ee - bb * (point.y - f)) / det
        let v = (aa * (point.y - f) - (point.x - c) * dd) / det
        let result = CGPoint(x: u, y: v)
        return screen(result) != nil ? result : nil
    }
    func rectangle(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) -> [RulerPoint]? {
        guard width > 1e-5, height > 1e-5 else { return nil }
        let points = [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
                      CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)].compactMap(screen)
        return points.count == 4 ? points.map { RulerPoint(x: $0.x, y: $0.y) } : nil
    }
}
enum RulerEllipseMode: String, Codable, CaseIterable { case fixed, concentric, stepped }

// The reference quad stays fixed; offset sections share its plane at another depth.
struct RulerEllipseDepth: Codable, Equatable {
    var enabled = false
    var vanishingPoint = RulerPoint(x: 700, y: -1200)
    var sceneLines: [RulerPoint]?
    var offset = 0.0
    var scale = 1.0
    var step = 25.0
    var tangents = true
    var direction: SIMD3<Double>? {
        sceneLines.map { RulerGeometry.sceneVanishingPoint($0) } ?? SIMD3(vanishingPoint.x, vanishingPoint.y, 1)
    }
    func validate() throws {
        guard [vanishingPoint.x, vanishingPoint.y, offset, scale, step].allSatisfy({ $0.isFinite }),
              abs(vanishingPoint.x) <= 100000, abs(vanishingPoint.y) <= 100000,
              abs(offset) <= 10000, (0.02...20).contains(scale), (2...10000).contains(step),
              direction != nil, sceneLines?.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100000 && abs($0.y) <= 100000 }) ?? true else {
            throw SettingsError.invalid("Ellipse depth needs distinct scene lines or a finite vanishing point, offset within ±10,000, scale 0.02–20 and step 2–10,000.")
        }
    }
}

struct RulerGuideColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

struct RulerRadialSettings: Codable, Equatable {
    var locked = true
    // Perpendicular deviation at 1,000 points is bend * 1,000 points.
    var bend = 0.0
    func validate() throws {
        guard bend.isFinite, (-2...2).contains(bend) else {
            throw SettingsError.invalid("Radial bend must be finite and between -2 and 2.")
        }
    }
}

struct RulerBoxSettings: Codable, Equatable {
    var enabled = false
    var learning: Bool?
    var learnsDimensions: Bool {
        get { learning ?? false }
        set { learning = newValue }
    }
    var extents = [100.0, 100.0, 100.0]
    func validate() throws {
        guard extents.count == 3, extents.allSatisfy({ $0.isFinite && (2...10000).contains(abs($0)) }) else {
            throw SettingsError.invalid("Box construction needs three signed extents from 2 to 10,000 points in magnitude.")
        }
    }
}

// Optional payload preserves older profiles and keeps new construction controls together.
struct RulerConstruction: Codable, Equatable {
    var start = RulerPoint(x: 400, y: 450)
    var end = RulerPoint(x: 1000, y: 450)
    var bounded = false
    var fixed = false
    var spacing = 50.0
    var offset = 0.0
    var tolerance = 0.0
    var angleStep = 15.0
    var attachment = 2 // start, midpoint, end
    var stopAtStart = false
    var resetID = 0
    var radiusX = 300.0
    var radiusY = 200.0
    var circle = false
    var sizing = RulerEllipseMode.fixed
    var radial = false
    var connect = false
    func validate() throws {
        let values = [start.x, start.y, end.x, end.y, spacing, offset, tolerance, angleStep, radiusX, radiusY]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
              hypot(end.x - start.x, end.y - start.y) >= 0.01,
              (2...10000).contains(spacing), abs(offset) <= 10000, (0...100).contains(tolerance),
              (1...180).contains(angleStep), (0...2).contains(attachment),
              (0.01...10000).contains(radiusX), (0.01...10000).contains(radiusY) else {
            throw SettingsError.invalid("Construction needs distinct endpoints, positive radii, spacing 2–10,000, tolerance 0–100 and angle step 1–180°.")
        }
    }
}

struct RulerSettings: Codable, Equatable {
    var construction: RulerConstruction?
    var constructionSettings: RulerConstruction {
        get { construction ?? RulerConstruction() }
        set { construction = newValue }
    }
    var enabled = false
    var visible = true
    var kind = RulerKind.radial
    var accuracy = 0.0
    var opacity = 0.25
    // String keys keep saved JSON readable; absent slots retain platform defaults.
    var guideColors: [String: [RulerGuideColor?]]?
    var guideColorLabels: [String] {
        switch kind {
        case .straight, .parallel, .connected, .ellipse: return ["Construction", "Active segment"]
        case .radial: return ["Radial lines", "Active ray"]
        case .perspectiveEllipse: return depthSettings.enabled ? ["Ellipse", "Construction plane", "Depth and tangents"] : ["Ellipse", "Construction plane"]
        case .isometric: return (1...3).map { "Axis \($0)" }
        case .perspective where camera != nil: return (1...3).map { "Axis \($0)" }
        case .perspective, .vanishing: return (1...vanishingPoints.count).map { "Family \($0)" }
        }
    }
    func guideColor(at index: Int) -> RulerGuideColor? {
        guard let colors = guideColors?[kind.rawValue], colors.indices.contains(index) else { return nil }
        return colors[index]
    }
    mutating func setGuideColor(_ color: RulerGuideColor?, at index: Int) {
        guard (0..<6).contains(index) else { return }
        var all = guideColors ?? [:], colors = all[kind.rawValue] ?? []
        while colors.count <= index { colors.append(nil) }
        colors[index] = color
        while colors.last == .some(nil) { colors.removeLast() }
        if colors.isEmpty { all.removeValue(forKey: kind.rawValue) } else { all[kind.rawValue] = colors }
        guideColors = all.isEmpty ? nil : all
    }
    mutating func resetGuideColors() {
        guideColors?.removeValue(forKey: kind.rawValue)
        if guideColors?.isEmpty == true { guideColors = nil }
    }
    var automaticAxisChanges: Bool?
    var changesAxesAutomatically: Bool {
        get { automaticAxisChanges ?? false }
        set { automaticAxisChanges = newValue }
    }
    var cameraCirclePlane: RulerCameraPlane?
    var cameraCircleDiameter: Double?
    var circlePlane: RulerCameraPlane {
        get { cameraCirclePlane ?? .xz }
        set { cameraCirclePlane = newValue }
    }
    var circleDiameter: Double {
        get { cameraCircleDiameter ?? 100 }
        set { cameraCircleDiameter = newValue }
    }
    func cameraEllipse(at position: CGPoint? = nil) -> RulerSettings? {
        guard kind == .perspective, let camera, (try? camera.validate()) != nil else { return nil }
        let pair = circlePlane.axes, axes = camera.axes, first = axes[pair.0], second = axes[pair.1]
        let dot = first.x * second.x + first.y * second.y + first.z * second.z
        let orthogonal = second - first * dot
        let norm = sqrt(orthogonal.x * orthogonal.x + orthogonal.y * orthogonal.y + orthogonal.z * orthogonal.z)
        guard norm > 1e-6 else { return nil }
        let origin = fixedReference?.cg ?? position ?? center
        let cameraOrigin = SIMD3(origin.x - centerX, origin.y - centerY, camera.focalLength)
        let corners = [CGPoint(x: -0.5, y: -0.5), CGPoint(x: 0.5, y: -0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: -0.5, y: 0.5)]
            .compactMap { camera.project(cameraOrigin + first * ($0.x * circleDiameter) + orthogonal / norm * ($0.y * circleDiameter), center: center) }
        guard corners.count == 4 else { return nil }
        var next = self
        next.kind = .perspectiveEllipse; next.corners = corners.map { RulerPoint(x: $0.x, y: $0.y) }
        next.ellipseSizing = .fixed; next.circleRadius = 1
        let normal = SIMD3(first.y * orthogonal.z - first.z * orthogonal.y,
                           first.z * orthogonal.x - first.x * orthogonal.z,
                           first.x * orthogonal.y - first.y * orthogonal.x)
        var depth = RulerEllipseDepth()
        depth.sceneLines = RulerGeometry.sceneLines(toward: SIMD3(camera.focalLength * normal.x + centerX * normal.z,
                                                                camera.focalLength * normal.y + centerY * normal.z, normal.z), center: origin)
        next.ellipseDepth = depth
        return (try? next.validate()) != nil ? next : nil
    }
    var fixedReference: RulerPoint?
    var box: RulerBoxSettings?
    var boxSettings: RulerBoxSettings {
        get { box ?? RulerBoxSettings() }
        set { box = newValue }
    }
    var usesBox: Bool { boxSettings.enabled && (kind == .isometric || kind == .perspective && camera != nil) }
    var radial: RulerRadialSettings?
    var radialSettings: RulerRadialSettings {
        get { radial ?? RulerRadialSettings() }
        set { radial = newValue }
    }
    var axisAngles: [Double]?
    var isometricAngles: [Double] {
        get { axisAngles ?? [angle, 180 - angle, 90] }
        set { axisAngles = newValue }
    }
    mutating func useIsometricPreset(_ index: Int) {
        orientation = 0
        switch index {
        case 0: angle = 30; axisAngles = nil
        case 1: angle = atan(0.5) * 180 / .pi; axisAngles = nil
        default: axisAngles = [15, 150, 90]
        }
    }
    var isometricPreset: Int? {
        if axisAngles == nil && abs(angle - 30) < 1e-6 { return 0 }
        if axisAngles == nil && abs(angle - atan(0.5) * 180 / .pi) < 1e-6 { return 1 }
        if axisAngles == [15, 150, 90] { return 2 }
        return nil
    }
    var ellipsePlaneStep: Double?
    var ellipseGrid: Bool?
    var showsPlaneGrid: Bool {
        get { ellipseGrid ?? false }
        set { ellipseGrid = newValue }
    }
    var planeStep: Double {
        get { ellipsePlaneStep ?? 0.25 }
        set { ellipsePlaneStep = newValue }
    }
    var ellipseDepth: RulerEllipseDepth?
    var depthSettings: RulerEllipseDepth {
        get { ellipseDepth ?? RulerEllipseDepth() }
        set { ellipseDepth = newValue }
    }
    var sectionRadius: Double { circleRadius * (depthSettings.enabled ? depthSettings.scale : 1) }
    // Normalize at the circle center so offset is locally measured in screen points.
    var depthVector: SIMD3<Double>? {
        guard let plane = RulerPlane(corners), var v = depthSettings.direction else { return nil }
        if v.z < 0 || v.z == 0 && (v.x < 0 || v.x == 0 && v.y < 0) { v = -v }
        let h = plane.horizon, hNorm = sqrt(h.x * h.x + h.y * h.y + h.z * h.z)
        let vNorm = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard abs(h.x * v.x + h.y * v.y + h.z * v.z) > 1e-9 * hNorm * vNorm else { return nil }
        let q = plane.homogeneous(CGPoint(x: 0.5, y: 0.5))
        let distance = hypot(v.x - q.x / q.z * v.z, v.y - q.y / q.z * v.z)
        return v * (q.z / (distance > 1e-6 ? distance : 100))
    }
    func sectionPoint(_ unit: CGPoint, offset: Double) -> CGPoint? {
        guard let plane = RulerPlane(corners), let v = depthVector else { return nil }
        let q = plane.homogeneous(unit) + v * offset
        guard q.z > 1e-8 else { return nil }
        let point = CGPoint(x: q.x / q.z, y: q.y / q.z)
        return point.x.isFinite && point.y.isFinite && abs(point.x) <= 100000 && abs(point.y) <= 100000 ? point : nil
    }
    var sectionCorners: [RulerPoint] {
        guard depthSettings.enabled else { return corners }
        let points = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            .compactMap { sectionPoint($0, offset: depthSettings.offset) }
        guard points.count == 4 else { return [] }
        func winding(_ p: [CGPoint]) -> Double {
            (p[1].x - p[0].x) * (p[2].y - p[1].y) - (p[1].y - p[0].y) * (p[2].x - p[1].x)
        }
        guard winding(points) * winding(corners.map(\.cg)) > 0 else { return [] }
        return points.map { RulerPoint(x: $0.x, y: $0.y) }
    }
    // Recover depth after an edit without collapsing the two parallel sections.
    private func depthOffset(matching section: [RulerPoint]) -> Double? {
        guard section.count == 4, let plane = RulerPlane(corners), let v = depthVector else { return nil }
        let units = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        var strongest = 0.0, offset: Double?
        for (unit, point) in zip(units, section) {
            let q = plane.homogeneous(unit)
            for (numerator, denominator) in [(q.x - point.x * q.z, point.x * v.z - v.x), (q.y - point.y * q.z, point.y * v.z - v.y)] {
                if abs(denominator) > strongest { strongest = abs(denominator); offset = numerator / denominator }
            }
        }
        return strongest > 1e-9 && offset?.isFinite == true ? offset : nil
    }
    func ellipseEditFrame(radius: Double? = nil) -> [RulerPoint] {
        let radius = radius ?? sectionRadius
        if let frame = RulerPlane(sectionCorners)?.rectangle(x: 0.5 - radius * 0.56, y: 0.5 - radius * 0.56,
                                                            width: radius * 1.12, height: radius * 1.12) { return frame }
        // A circle can be visible even when its plane's expanded rectangle crosses
        // the horizon. Keep a finite enclosing frame and use the same projective edit.
        let bounds = (RulerGeometry.projectedCircle(sectionCorners, radius: radius) ?? []).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -12, dy: -12)
        guard !bounds.isNull else { return sectionCorners }
        return [RulerPoint(x: bounds.minX, y: bounds.minY), RulerPoint(x: bounds.maxX, y: bounds.minY),
                RulerPoint(x: bounds.maxX, y: bounds.maxY), RulerPoint(x: bounds.minX, y: bounds.maxY)]
    }
    mutating func enableDepth(_ enabled: Bool) {
        depthSettings.enabled = enabled
        if enabled, depthVector == nil, let center = RulerPlane(corners)?.screen(CGPoint(x: 0.5, y: 0.5)) {
            depthSettings.sceneLines = nil
            depthSettings.vanishingPoint = RulerPoint(x: center.x, y: center.y)
        }
    }
    mutating func matchDepthScene(_ enabled: Bool) {
        depthSettings.sceneLines = enabled ? depthSettings.direction.map { RulerGeometry.sceneLines(toward: $0, center: editingCenter) } : nil
    }
    // Common silhouette generators of two coaxial projected circle sections.
    func depthTangents(radius: Double) -> [(CGPoint, CGPoint)] {
        guard depthSettings.enabled, depthSettings.tangents, abs(depthSettings.offset) > 1e-6,
              let plane = RulerPlane(corners), let v = depthVector else { return [] }
        let r0 = circleRadius / 2, r1 = radius / 2
        let center = plane.homogeneous(CGPoint(x: 0.5, y: 0.5))
        let apex = abs(r0 - r1) < 1e-9 ? v : center + v * (depthSettings.offset * r0 / (r0 - r1))
        let q = plane.inverseHomogeneous(apex), dx = q.x - q.z / 2, dy = q.y - q.z / 2
        let distance = hypot(dx, dy)
        guard distance > abs(r0 * q.z) + 1e-9 else { return [] }
        let cosine = r0 * q.z / distance, sine = sqrt(max(0, 1 - cosine * cosine))
        return [-1.0, 1.0].compactMap { sign in
            let nx = dx / distance * cosine - dy / distance * sine * sign
            let ny = dy / distance * cosine + dx / distance * sine * sign
            guard let base = plane.screen(CGPoint(x: 0.5 + r0 * nx, y: 0.5 + r0 * ny)),
                  let top = sectionPoint(CGPoint(x: 0.5 + r1 * nx, y: 0.5 + r1 * ny), offset: depthSettings.offset) else { return nil }
            return (base, top)
        }
    }
    var ellipseMode: RulerEllipseMode?
    var ellipseRadius: Double?
    var ellipseStep: Double?
    var ellipseSizing: RulerEllipseMode {
        get { ellipseMode ?? .fixed }
        set { ellipseMode = newValue }
    }
    var circleRadius: Double {
        get { ellipseRadius ?? 1 }
        set { ellipseRadius = newValue }
    }
    var circleStep: Double {
        get { ellipseStep ?? 0.25 }
        set { ellipseStep = newValue }
    }
    var sceneLines: [[RulerPoint]]?
    var camera: RulerCamera?
    var familyMeasurements: [RulerMeasurements]?
    var horizonVisible: Bool?
    var showsHorizon: Bool {
        get { horizonVisible ?? false }
        set { horizonVisible = newValue }
    }
    var usesVanishingMeasurements: Bool { (kind == .vanishing || kind == .perspective && camera == nil) && familyMeasurements != nil }
    func measurement(for family: Int) -> RulerMeasurements {
        var result = familyMeasurements.flatMap { $0.indices.contains(family) ? $0[family] : nil } ?? measureSettings
        result.visible = measureSettings.visible
        return result
    }
    mutating func setMeasurement(_ value: RulerMeasurements, family: Int) {
        guard (0..<6).contains(family) else { return }
        var all = familyMeasurements ?? []
        while all.count <= family { all.append(measureSettings) }
        all[family] = value
        familyMeasurements = all
    }
    var measurements: RulerMeasurements?
    var measureSettings: RulerMeasurements {
        get { measurements ?? RulerMeasurements() }
        set { measurements = newValue }
    }
    var acquisitionDistance: Double?
    var lockedFamily: Int?
    var selectionDistance: Double {
        get { acquisitionDistance ?? 8 }
        set { acquisitionDistance = newValue }
    }
    var family: Int {
        get { lockedFamily ?? 0 }
        set { lockedFamily = newValue }
    }
    var rotation: Double?
    var orientation: Double {
        get { rotation ?? 0 }
        set { rotation = newValue }
    }
    var centerX = 700.0, centerY = 450.0
    var angle = 30.0
    var spacing = 15.0
    var vanishingPoints = [RulerPoint(x: 100, y: 400), RulerPoint(x: 1300, y: 400), RulerPoint(x: 700, y: -1200)]
    var corners = [RulerPoint(x: 400, y: 300), RulerPoint(x: 1000, y: 250), RulerPoint(x: 1100, y: 650), RulerPoint(x: 350, y: 700)]
    func validate() throws {
        try constructionSettings.validate()
        if let point = fixedReference {
            guard [point.x, point.y].allSatisfy({ $0.isFinite && abs($0) <= 100000 }) else {
                throw SettingsError.invalid("The fixed ruler reference must use finite screen coordinates within ±100,000 points.")
            }
        }
        if let guideColors {
            guard guideColors.allSatisfy({ RulerKind(rawValue: $0.key) != nil && $0.value.count <= 6 && $0.value.allSatisfy { $0?.isValid ?? true } }) else {
                throw SettingsError.invalid("Guideline colors need a known ruler, at most six slots, and RGB values from 0 to 1.")
            }
        }
        if let sceneLines {
            guard sceneLines.count == vanishingPoints.count,
                  sceneLines.allSatisfy({ $0.count == 4 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100000 && abs($0.y) <= 100000 } && RulerGeometry.sceneVanishingPoint($0) != nil }) else {
                throw SettingsError.invalid("Scene matching needs two distinct non-collapsed construction lines per vanishing family.")
            }
        }
        try depthSettings.validate()
        try boxSettings.validate()
        try radialSettings.validate()
        if let axisAngles {
            guard axisAngles.count == 3, axisAngles.allSatisfy({ $0.isFinite && abs($0) <= 360 }) else {
                throw SettingsError.invalid("Isometric needs three finite axis angles within ±360°.")
            }
        }
        try camera?.validate()
        try measureSettings.validate()
        if let familyMeasurements {
            guard !familyMeasurements.isEmpty, familyMeasurements.count <= 6 else {
                throw SettingsError.invalid("Vanishing measurements need one to six family calibrations.")
            }
            for measurement in familyMeasurements { try measurement.validate() }
        }
        let values = [centerX, centerY, angle, spacing, accuracy, opacity, orientation, circleRadius, circleStep] + (vanishingPoints + corners).flatMap { [$0.x, $0.y] }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
              (0...1).contains(accuracy), (0.1...1).contains(opacity),
              (0.02...20).contains(circleRadius), (0.02...5).contains(circleStep), planeStep.isFinite, (0.01...2).contains(planeStep), circleDiameter.isFinite, (2...10000).contains(circleDiameter),
              selectionDistance.isFinite, (2...50).contains(selectionDistance), (0...6).contains(family),
              (1...90).contains(spacing), (-360...360).contains(angle),
              (1...6).contains(vanishingPoints.count), corners.count == 4 else {
            throw SettingsError.invalid("Ruler values are outside their allowed range.")
        }
        guard RulerGeometry.projectedCircle(corners, radius: circleRadius) != nil,
              !depthSettings.enabled || (0.02...20).contains(sectionRadius) && RulerGeometry.projectedCircle(sectionCorners, radius: sectionRadius) != nil else {
            throw SettingsError.invalid("Perspective ellipse corners must form a convex, non-collapsed quadrilateral in order.")
        }
    }
    var center: CGPoint { CGPoint(x: centerX, y: centerY) }
}

// Shared screen-point geometry for guide rendering and bounded projection.
enum RulerGeometry {
    static func constructionScale(_ settings: RulerSettings, through point: CGPoint) -> Double {
        let c = settings.constructionSettings
        guard c.sizing != .fixed else { return 1 }
        let local = ellipseLocal(point, settings: settings)
        let radius = hypot(local.x / c.radiusX, local.y / (c.circle ? c.radiusX : c.radiusY))
        return max(0.001, min(20, c.sizing == .stepped ? (radius / settings.circleStep).rounded() * settings.circleStep : radius))
    }
    static func parallelOrigin(_ settings: RulerSettings, through point: CGPoint) -> CGPoint {
        let c = settings.constructionSettings
        guard c.fixed else { return point }
        let d = direction(settings.angle), normal = CGPoint(x: -d.y, y: d.x)
        let offset = ((point.x - settings.centerX) * normal.x + (point.y - settings.centerY) * normal.y - c.offset) / c.spacing
        let distance = offset.rounded() * c.spacing + c.offset
        return CGPoint(x: settings.centerX + normal.x * distance, y: settings.centerY + normal.y * distance)
    }
    static func ellipseLocal(_ point: CGPoint, settings: RulerSettings) -> CGPoint {
        let d = direction(settings.angle), x = point.x - settings.centerX, y = point.y - settings.centerY
        return CGPoint(x: x * d.x + y * d.y, y: -x * d.y + y * d.x)
    }
    static func ordinaryEllipse(_ settings: RulerSettings, scale: Double = 1) -> [CGPoint] {
        let c = settings.constructionSettings, d = direction(settings.angle)
        return (0...720).map { i in
            let t = Double(i) * .pi / 360, x = cos(t) * c.radiusX * scale, y = sin(t) * (c.circle ? c.radiusX : c.radiusY) * scale
            return CGPoint(x: settings.centerX + x * d.x - y * d.y, y: settings.centerY + x * d.y + y * d.x)
        }
    }
    static func line(_ point: CGPoint, origin: CGPoint, direction: CGPoint) -> CGPoint {
        let d = direction.x * direction.x + direction.y * direction.y
        guard d > 1e-12 else { return point }
        let t = ((point.x - origin.x) * direction.x + (point.y - origin.y) * direction.y) / d
        return CGPoint(x: origin.x + t * direction.x, y: origin.y + t * direction.y)
    }
    static func vanishingPoint(_ settings: RulerSettings, family: Int) -> SIMD3<Double>? {
        guard settings.vanishingPoints.indices.contains(family) else { return nil }
        var v: SIMD3<Double>
        if let lines = settings.sceneLines, lines.indices.contains(family), let matched = sceneVanishingPoint(lines[family]) { v = matched }
        else { let p = settings.vanishingPoints[family]; v = SIMD3(p.x, p.y, 1) }
        if v.z < 0 { v = -v }
        return v
    }
    static func horizon(_ settings: RulerSettings) -> (origin: CGPoint, direction: CGPoint)? {
        guard let a = vanishingPoint(settings, family: 0), let b = vanishingPoint(settings, family: 1) else { return nil }
        let line = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        let norm = hypot(line.x, line.y)
        guard norm > 1e-9 else { return nil } // A horizon at infinity has no screen line.
        let origin = CGPoint(x: -line.z / norm * (line.x / norm), y: -line.z / norm * (line.y / norm))
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) <= 300000, abs(origin.y) <= 300000 else { return nil }
        return (origin, CGPoint(x: -line.y / norm, y: line.x / norm))
    }
    static func editSceneLine(_ points: [RulerPoint], index: Int, delta: CGPoint, translate: Bool, align: Bool, horizon: CGPoint? = nil) -> [RulerPoint]? {
        guard points.count == 4, points.indices.contains(index) else { return nil }
        var next = points
        let pair = index / 2 * 2, fixed = pair + (index % 2 == 0 ? 1 : 0)
        var target = CGPoint(x: points[index].x + delta.x, y: points[index].y + delta.y)
        if translate {
            for i in pair...pair + 1 { next[i] = RulerPoint(x: points[i].x + delta.x, y: points[i].y + delta.y) }
        } else {
            if align {
                let other = pair == 0 ? 2 : 0
                var directions = [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: points[other + 1].x - points[other].x, y: points[other + 1].y - points[other].y)]
                if let horizon { directions.append(CGPoint(x: -horizon.y, y: horizon.x)) }
                let origin = points[fixed].cg
                let candidates = directions.filter { hypot($0.x, $0.y) > 1e-6 }.map { line(target, origin: origin, direction: $0) }
                target = candidates.min { hypot($0.x - target.x, $0.y - target.y) < hypot($1.x - target.x, $1.y - target.y) } ?? target
            }
            next[index] = RulerPoint(x: target.x, y: target.y)
        }
        return sceneVanishingPoint(next) != nil ? next : nil
    }
    static func direction(_ degrees: Double) -> CGPoint {
        CGPoint(x: cos(degrees * .pi / 180), y: sin(degrees * .pi / 180))
    }
    static func directions(_ settings: RulerSettings, anchor: CGPoint) -> [CGPoint] {
        switch settings.kind {
        case .straight, .parallel, .connected, .ellipse: return [direction(settings.angle)]
        case .isometric: return settings.isometricAngles.map { direction($0 + settings.orientation) }
        case .perspective where settings.camera != nil:
            return settings.camera!.directions(center: settings.center, anchor: anchor)
        case .perspective, .vanishing:
            return settings.vanishingPoints.indices.map { i in
                let v = vanishingPoint(settings, family: i)!
                return CGPoint(x: v.x - anchor.x * v.z, y: v.y - anchor.y * v.z)
            }
        case .radial:
            let distance = hypot(anchor.x - settings.centerX, anchor.y - settings.centerY)
            let k = settings.radialSettings.bend / 1000
            let parameter = sqrt(2 * distance * distance / (1 + sqrt(1 + 4 * k * k * distance * distance)))
            let theta = (atan2(anchor.y - settings.centerY, anchor.x - settings.centerX) - atan(k * parameter)) * 180 / .pi
            let angle = settings.radialSettings.locked ? ((theta - settings.angle) / settings.spacing).rounded() * settings.spacing + settings.angle : theta
            return [direction(distance > 1e-6 ? angle : settings.angle)]
        case .perspectiveEllipse: return []
        }
    }
    static let boxEdges: [(from: Int, to: Int, family: Int)] = (0..<8).flatMap { vertex in
        (0..<3).filter { vertex & (1 << $0) == 0 }.map { (vertex, vertex | (1 << $0), $0) }
    }
    private static func cameraPosition(_ camera: RulerCamera, center: CGPoint, anchor: CGPoint, world: SIMD3<Double>) -> SIMD3<Double> {
        let axes = camera.axes
        return (0..<3).reduce(SIMD3(anchor.x - center.x, anchor.y - center.y, camera.focalLength)) { $0 + axes[$1] * world[$1] }
    }
    static func projectWorld(_ settings: RulerSettings, anchor: CGPoint, world: SIMD3<Double>) -> CGPoint? {
        let point: CGPoint
        if settings.kind == .perspective, let camera = settings.camera {
            let p = cameraPosition(camera, center: settings.center, anchor: anchor, world: world)
            guard let projected = camera.project(p, center: settings.center) else { return nil }
            point = projected
        } else {
            let directions = directions(settings, anchor: anchor)
            guard directions.count == 3 else { return nil }
            point = (0..<3).reduce(anchor) { CGPoint(x: $0.x + directions[$1].x * world[$1], y: $0.y + directions[$1].y * world[$1]) }
        }
        return point.x.isFinite && point.y.isFinite && abs(point.x) <= 100000 && abs(point.y) <= 100000 ? point : nil
    }
    static func axisDistance(_ settings: RulerSettings, anchor: CGPoint, world: SIMD3<Double>, family: Int, point: CGPoint) -> Double? {
        guard (0..<3).contains(family) else { return nil }
        let distance: Double
        if settings.kind == .perspective, let camera = settings.camera {
            let p = cameraPosition(camera, center: settings.center, anchor: anchor, world: world), axis = camera.axes[family]
            let x = point.x - settings.centerX, y = point.y - settings.centerY
            let dx = x * axis.z - camera.focalLength * axis.x, dy = y * axis.z - camera.focalLength * axis.y
            guard max(abs(dx), abs(dy)) > 1e-9 else { return nil }
            distance = abs(dx) > abs(dy) ? (camera.focalLength * p.x - x * p.z) / dx : (camera.focalLength * p.y - y * p.z) / dy
        } else {
            guard let origin = projectWorld(settings, anchor: anchor, world: world) else { return nil }
            let directions = directions(settings, anchor: anchor)
            guard directions.indices.contains(family) else { return nil }
            distance = (point.x - origin.x) * directions[family].x + (point.y - origin.y) * directions[family].y
        }
        return distance.isFinite ? distance : nil
    }
    static func anchorForWorldPoint(_ settings: RulerSettings, world: SIMD3<Double>, screen: CGPoint) -> CGPoint? {
        if settings.kind == .perspective, let camera = settings.camera {
            let offset = cameraPosition(camera, center: settings.center, anchor: settings.center, world: world)
            guard offset.z > camera.focalLength * 0.01 else { return nil }
            return CGPoint(x: settings.centerX + (screen.x - settings.centerX) * offset.z / camera.focalLength - offset.x,
                           y: settings.centerY + (screen.y - settings.centerY) * offset.z / camera.focalLength - offset.y)
        }
        guard let offset = projectWorld(settings, anchor: .zero, world: world) else { return nil }
        return CGPoint(x: screen.x - offset.x, y: screen.y - offset.y)
    }
    static func boxVertices(_ settings: RulerSettings, anchor: CGPoint) -> [CGPoint]? {
        guard settings.usesBox, (try? settings.boxSettings.validate()) != nil else { return nil }
        let result = (0..<8).compactMap { vertex -> CGPoint? in
            let lengths = (0..<3).map { vertex & (1 << $0) == 0 ? 0 : settings.boxSettings.extents[$0] }
            return projectWorld(settings, anchor: anchor, world: SIMD3(lengths[0], lengths[1], lengths[2]))
        }
        return result.count == 8 ? result : nil
    }
    static func radialPoint(center: CGPoint, direction: CGPoint, bend: Double, parameter: Double) -> CGPoint {
        let offset = bend * parameter * parameter / 1000
        return CGPoint(x: center.x + direction.x * parameter - direction.y * offset,
                       y: center.y + direction.y * parameter + direction.x * offset)
    }
    // All stationary points of squared distance to a parabola (a depressed cubic),
    // plus its ray boundary. No iterative search or sampled-curve error in HID.
    static func nearestRadial(_ point: CGPoint, center: CGPoint, direction: CGPoint, bend: Double, previous: Double?) -> (point: CGPoint, parameter: Double) {
        let dx = point.x - center.x, dy = point.y - center.y
        let x = dx * direction.x + dy * direction.y, y = -dx * direction.y + dy * direction.x
        let k = bend / 1000
        if k == 0 || abs(k) * (dx * dx + dy * dy) < 1e-9 {
            let parameter = k == 0 ? x : max(0, x)
            return (radialPoint(center: center, direction: direction, bend: 0, parameter: parameter), parameter)
        }
        let p = (1 - 2 * k * y) / (2 * k * k), q = -x / (2 * k * k)
        let discriminant = q * q / 4 + p * p * p / 27
        var roots = [0.0]
        if p > 0 {
            roots.append(-2 * sqrt(p / 3) * sinh(asinh(3 * q / (2 * p) * sqrt(3 / p)) / 3))
        } else if discriminant >= 0 {
            let root = sqrt(discriminant)
            roots.append(cbrt(-q / 2 + root) + cbrt(-q / 2 - root))
        } else {
            let radius = 2 * sqrt(-p / 3)
            let phase = acos(max(-1, min(1, 3 * q / (2 * p) * sqrt(-3 / p)))) / 3
            roots += (0..<3).map { radius * cos(phase - Double($0) * 2 * .pi / 3) }
        }
        let candidates = roots.filter { $0.isFinite && (0...300000).contains($0) }.map { parameter in
            let projected = radialPoint(center: center, direction: direction, bend: bend, parameter: parameter)
            return (point: projected, parameter: parameter, distance: hypot(projected.x - point.x, projected.y - point.y))
        }.sorted { $0.distance < $1.distance }
        let best = candidates[0]
        // At two equally near branches, retain the previous side of the stroke.
        if let previous, let continuous = candidates.filter({ $0.distance <= best.distance + 0.25 }).min(by: { abs($0.parameter - previous) < abs($1.parameter - previous) }) {
            return (continuous.point, continuous.parameter)
        }
        return (best.point, best.parameter)
    }
    static func sceneLines(toward v: SIMD3<Double>, center: CGPoint) -> [RulerPoint] {
        let dx = v.x - center.x * v.z, dy = v.y - center.y * v.z, norm = hypot(dx, dy)
        let axis = norm > 1e-6 ? CGPoint(x: dx / norm, y: dy / norm) : CGPoint(x: 1, y: 0)
        return [-80.0, 80.0].flatMap { offset in
            let start = RulerPoint(x: center.x - axis.x * 80 - axis.y * offset, y: center.y - axis.y * 80 + axis.x * offset)
            let x = v.x - start.x * v.z, y = v.y - start.y * v.z, length = max(1e-9, hypot(x, y))
            return [start, RulerPoint(x: start.x + x / length * 80, y: start.y + y / length * 80)]
        }
    }
    static func sceneVanishingPoint(_ points: [RulerPoint]) -> SIMD3<Double>? {
        guard points.count == 4 else { return nil }
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        let p = points.map { SIMD3($0.x, $0.y, 1) }
        let l1 = cross(p[0], p[1]), l2 = cross(p[2], p[3])
        guard hypot(l1.x, l1.y) > 1e-6, hypot(l2.x, l2.y) > 1e-6 else { return nil }
        let v = cross(l1, l2), norm = max(abs(v.x), abs(v.y), abs(v.z))
        guard norm.isFinite, norm > 1e-9 else { return nil }
        return v / norm
    }
    // Equal world steps at the anchor's image-plane depth. Skip the camera plane
    // and the invisible half-space rather than reflecting ticks through infinity.
    static func ticks(_ settings: RulerSettings, anchor: CGPoint, family: Int) -> [(point: CGPoint, major: Bool)] {
        let measure = settings.usesVanishingMeasurements ? settings.measurement(for: family) : settings.measureSettings
        guard measure.visible else { return [] }
        let directions = directions(settings, anchor: anchor)
        guard directions.indices.contains(family) else { return [] }
        let direction = directions[family], norm = hypot(direction.x, direction.y)
        guard norm > 1e-6 else { return [] }
        return (-20 * measure.divisions...20 * measure.divisions).compactMap { i in
            guard i != 0 else { return nil }
            let t = Double(i) * measure.distance / Double(measure.divisions)
            let point: CGPoint
            if settings.kind == .perspective, let camera = settings.camera {
                let axis = camera.axes[family], depth = camera.focalLength + t * axis.z
                guard depth > camera.focalLength * 0.01 else { return nil }
                point = CGPoint(x: settings.centerX + camera.focalLength * (anchor.x - settings.centerX + t * axis.x) / depth,
                                y: settings.centerY + camera.focalLength * (anchor.y - settings.centerY + t * axis.y) / depth)
            } else {
                var distance = t
                if settings.usesVanishingMeasurements, let v = vanishingPoint(settings, family: family), v.z > 1e-12 {
                    let limit = norm / v.z
                    guard measure.distance < limit - 1e-6 else { return nil }
                    let units = Double(i) / Double(measure.divisions)
                    let denominator = 1 + (units - 1) * measure.distance / limit
                    guard denominator > 1e-5 else { return nil }
                    distance = t / denominator
                }
                point = CGPoint(x: anchor.x + distance * direction.x / norm, y: anchor.y + distance * direction.y / norm)
            }
            guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 300000, abs(point.y) <= 300000 else { return nil }
            return (point, i % measure.divisions == 0)
        }
    }
    static func projectedCircle(_ corners: [RulerPoint], radius: Double = 1) -> [CGPoint]? {
        guard let plane = RulerPlane(corners), radius.isFinite, radius > 0 else { return nil }
        var points: [CGPoint] = []
        for i in 0...512 {
            let t = Double(i) * 2 * .pi / 512
            guard let point = plane.screen(CGPoint(x: 0.5 + radius * 0.5 * cos(t), y: 0.5 + radius * 0.5 * sin(t))) else { return nil }
            points.append(point)
        }
        return points
    }
    static func ellipseRadius(_ settings: RulerSettings, through point: CGPoint) -> Double {
        guard settings.ellipseSizing != .fixed, let unit = RulerPlane(settings.sectionCorners)?.unit(point) else { return settings.sectionRadius }
        let radius = 2 * hypot(unit.x - 0.5, unit.y - 0.5)
        let step = settings.circleStep
        return max(0.02, min(20, settings.ellipseSizing == .stepped ? (radius / step).rounded() * step : radius))
    }
    static func nearest(_ point: CGPoint, on curve: [CGPoint], previous: CGPoint? = nil) -> CGPoint {
        var result = point, distance = Double.infinity
        var continuous: CGPoint?, continuousDistance = Double.infinity
        for i in 1..<curve.count {
            let a = curve[i - 1], b = curve[i]
            let dx = b.x - a.x, dy = b.y - a.y, denominator = dx * dx + dy * dy
            guard denominator > 1e-12 else { continue }
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator))
            let candidate = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let delta = hypot(point.x - candidate.x, point.y - candidate.y)
            if delta < distance { result = candidate; distance = delta }
            if let previous, hypot(candidate.x - previous.x, candidate.y - previous.y) <= 8, delta < continuousDistance {
                continuous = candidate; continuousDistance = delta
            }
        }
        // Retain a distant, nearly tied branch through center noise, without
        // biasing the ordinary nearest point along the same local arc.
        if let continuous, continuousDistance <= distance + 0.25,
           hypot(continuous.x - result.x, continuous.y - result.y) > 8 { return continuous }
        return result
    }
}

struct RulerProjection {
    private var chainStart: CGPoint?
    private var chainMidpoint: CGPoint?
    private var chainEnd: CGPoint?
    private var chainDirection: CGPoint?
    private var lastConstructionPoint: CGPoint?
    private var constructionOrigin: CGPoint?
    private var constructionDirection: CGPoint?
    private var ellipseScale = 1.0
    private var ellipseStart: CGPoint?
    private var ellipseTravel = false
    mutating func finishStroke(settings: RulerSettings) {
        if settings.kind == .connected, let start = anchor, let end = lastConstructionPoint,
           hypot(end.x - start.x, end.y - start.y) >= 0.01 {
            if chainStart == nil { chainStart = start }
            chainMidpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            chainEnd = end
            chainDirection = constructionDirection
        }
        let saved = (chainStart, chainMidpoint, chainEnd, chainDirection)
        reset()
        (chainStart, chainMidpoint, chainEnd, chainDirection) = saved
    }
    private(set) var anchor: CGPoint?
    private(set) var selected: CGPoint?
    private(set) var selectedFamily: Int?
    private var boxPoints: [CGPoint] = []
    private var boxVertex = 0
    private var learnedExtents = [Double?](repeating: nil, count: 3)
    private var boxWorld = SIMD3<Double>.zero
    private var boxSegmentWorld = SIMD3<Double>.zero
    private var allDimensionsLearned: Bool { learnedExtents.allSatisfy { $0 != nil } }
    func guideSettings(_ settings: RulerSettings) -> RulerSettings {
        if settings.kind == .ellipse, anchor != nil {
            var next = settings
            next.constructionSettings.radiusX *= ellipseScale
            next.constructionSettings.radiusY *= ellipseScale
            next.constructionSettings.sizing = .fixed
            return next
        }
        if settings.kind == .connected, let origin = constructionOrigin ?? [chainStart, chainMidpoint, chainEnd][settings.constructionSettings.attachment] {
            var next = settings; next.centerX = origin.x; next.centerY = origin.y
            if let direction = constructionDirection ?? chainDirection { next.angle = atan2(direction.y, direction.x) * 180 / .pi }
            return next
        }

        guard settings.usesBox, settings.boxSettings.learnsDimensions, anchor != nil else { return settings }
        var next = settings
        next.boxSettings.extents = (0..<3).map { i in learnedExtents[i] ?? (abs(boxWorld[i]) >= 2 ? boxWorld[i] : settings.boxSettings.extents[i]) }
        return next
    }
    private var boxEdge: (from: Int, to: Int)?
    private var inputOffset = CGPoint.zero
    private var previousInput: CGPoint?
    private var previousOutput: CGPoint?
    private var turnOrigin: CGPoint?
    private var turnInput: CGPoint?
    private var turnWorld = SIMD3<Double>.zero
    private var radialParameter: Double?
    private var candidate: CGPoint?
    private var candidateStart: CGPoint?
    private var curve: [CGPoint] = []
    private var baseEllipse: [CGPoint] = []
    mutating func configure(_ settings: RulerSettings) {
        reset()
        curve = settings.kind == .ellipse ? RulerGeometry.ordinaryEllipse(settings) : settings.kind == .perspectiveEllipse ? RulerGeometry.projectedCircle(settings.sectionCorners, radius: settings.sectionRadius) ?? [] : []
        baseEllipse = settings.kind == .ellipse ? curve : []
    }
    mutating func reset() { chainStart = nil; chainMidpoint = nil; chainEnd = nil; chainDirection = nil; lastConstructionPoint = nil; constructionOrigin = nil; constructionDirection = nil; ellipseScale = 1; ellipseStart = nil; ellipseTravel = false; anchor = nil; selected = nil; selectedFamily = nil; inputOffset = .zero; previousInput = nil; previousOutput = nil; turnOrigin = nil; turnInput = nil; boxPoints = []; boxVertex = 0; boxEdge = nil; learnedExtents = [Double?](repeating: nil, count: 3); boxWorld = .zero; boxSegmentWorld = .zero; radialParameter = nil; candidate = nil; candidateStart = nil }
    mutating func process(_ point: CGPoint, settings: RulerSettings) -> CGPoint {
        if settings.enabled, settings.accuracy > 0, settings.changesAxesAutomatically,
           settings.kind.supportsAxisCycling, !settings.usesBox || settings.boxSettings.learnsDimensions && !allDimensionsLearned {
            inferAxisChange(point, settings: settings)
        }
        let result = project(point, settings: settings)
        if settings.kind == .connected, anchor != nil { lastConstructionPoint = result }
        previousInput = point; previousOutput = result
        return result
    }
    private mutating func clearTurn() {
        turnOrigin = nil; turnInput = nil; candidate = nil; candidateStart = nil
    }
    private mutating func inferAxisChange(_ point: CGPoint, settings: RulerSettings) {
        guard let selected, let selectedFamily, let previousInput, let previousOutput else { return }
        let dx = point.x - previousInput.x, dy = point.y - previousInput.y, travel = hypot(dx, dy)
        guard travel > 1e-6 else { return }
        let directions = RulerGeometry.directions(settings, anchor: previousOutput)
        let currentError = abs(dx * selected.y - dy * selected.x) / (travel * hypot(selected.x, selected.y))
        let alternative = directions.enumerated().filter { $0.offset != selectedFamily && hypot($0.element.x, $0.element.y) > 1e-6 }
            .map { abs(dx * $0.element.y - dy * $0.element.x) / (travel * hypot($0.element.x, $0.element.y)) }.min() ?? 1
        guard alternative < 0.35, currentError - alternative > 0.02 else { clearTurn(); return }
        if turnOrigin == nil {
            turnOrigin = previousOutput; turnInput = previousInput; turnWorld = boxWorld
            candidate = nil; candidateStart = nil
        }
        let origin = turnOrigin!, input = turnInput!
        let evidence = CGPoint(x: origin.x + point.x - input.x, y: origin.y + point.y - input.y)
        var automatic = settings; automatic.family = 0
        guard let choice = chooseDirection(evidence, origin: origin, directions: RulerGeometry.directions(settings, anchor: origin), settings: automatic) else { return }
        guard choice.family != selectedFamily else { clearTurn(); return }
        let oldWorld = boxWorld
        if settings.usesBox { boxWorld = turnWorld }
        if !cycleAxis(at: origin, input: input, settings: settings, preferredFamily: choice.family) { boxWorld = oldWorld; clearTurn() }
    }
    private mutating func project(_ point: CGPoint, settings: RulerSettings) -> CGPoint {
        guard settings.enabled, settings.accuracy > 0 else { return point }
        var point = CGPoint(x: point.x + inputOffset.x, y: point.y + inputOffset.y)
        if anchor == nil {
            let c = settings.constructionSettings
            anchor = settings.kind == .connected ? ([chainStart, chainMidpoint, chainEnd][c.attachment] ?? point) : point
            if settings.kind == .connected, let anchor {
                inputOffset = CGPoint(x: anchor.x - point.x, y: anchor.y - point.y)
                point = anchor
            }
            if settings.kind == .ellipse, c.sizing != .fixed, !c.radial || hypot(point.x - settings.centerX, point.y - settings.centerY) > settings.selectionDistance {
                ellipseScale = RulerGeometry.constructionScale(settings, through: point)
            }
            if settings.kind == .ellipse { curve = ellipseScale == 1 ? baseEllipse : baseEllipse.map { CGPoint(x: settings.centerX + ($0.x - settings.centerX) * ellipseScale, y: settings.centerY + ($0.y - settings.centerY) * ellipseScale) } }
            boxPoints = RulerGeometry.boxVertices(settings, anchor: point) ?? []
            if settings.kind == .perspectiveEllipse, settings.ellipseSizing != .fixed {
                curve = RulerGeometry.projectedCircle(settings.sectionCorners, radius: RulerGeometry.ellipseRadius(settings, through: point)) ?? []
            }
        }
        let start = anchor!
        let projected: CGPoint
        var connectEndpoint = false
        if [.straight, .parallel, .connected, .ellipse].contains(settings.kind) {
            let c = settings.constructionSettings
            var origin = start, direction = RulerGeometry.direction(settings.angle)
            if settings.kind == .ellipse {
                if c.radial, hypot(start.x - settings.centerX, start.y - settings.centerY) <= settings.selectionDistance {
                    if constructionDirection == nil, hypot(point.x - settings.centerX, point.y - settings.centerY) >= settings.selectionDistance {
                        constructionDirection = CGPoint(x: point.x - settings.centerX, y: point.y - settings.centerY)
                    }
                    selected = constructionDirection
                    projected = constructionDirection.map { RulerGeometry.line(point, origin: settings.center, direction: $0) } ?? settings.center
                } else {
                    let nearest = RulerGeometry.nearest(point, on: curve, previous: lastConstructionPoint)
                    connectEndpoint = c.connect && ellipseStart == nil
                    if ellipseStart == nil { ellipseStart = nearest }
                    if hypot(nearest.x - ellipseStart!.x, nearest.y - ellipseStart!.y) > max(8, c.tolerance * 2) { ellipseTravel = true }
                    let closing = c.connect && ellipseTravel && hypot(nearest.x - ellipseStart!.x, nearest.y - ellipseStart!.y) <= max(2, c.tolerance)
                    connectEndpoint = connectEndpoint || closing
                    projected = closing ? ellipseStart! : nearest
                }
            } else {
                if settings.kind == .straight {
                    origin = c.start.cg; direction = CGPoint(x: c.end.x - c.start.x, y: c.end.y - c.start.y)
                } else if settings.kind == .parallel {
                    if constructionOrigin == nil {
                        constructionOrigin = RulerGeometry.parallelOrigin(settings, through: start)
                    }
                    origin = constructionOrigin!
                } else {
                    if constructionDirection == nil, hypot(point.x - start.x, point.y - start.y) >= settings.selectionDistance {
                        let degrees = atan2(point.y - start.y, point.x - start.x) * 180 / .pi
                        constructionDirection = RulerGeometry.direction(((degrees - settings.angle) / c.angleStep).rounded() * c.angleStep + settings.angle)
                    }
                    guard let chosen = constructionDirection else { return start }
                    direction = chosen; constructionOrigin = start
                }
                let norm = hypot(direction.x, direction.y)
                var distance = ((point.x - origin.x) * direction.x + (point.y - origin.y) * direction.y) / norm
                let step = settings.measureSettings.distance / Double(settings.measureSettings.divisions)
                let tick = (distance / step).rounded() * step
                if abs(distance - tick) <= c.tolerance { distance = tick }
                if settings.kind == .straight && c.bounded { distance = min(norm, max(0, distance)) }
                if settings.kind == .connected && c.stopAtStart { distance = max(0, distance) }
                projected = CGPoint(x: origin.x + distance * direction.x / norm, y: origin.y + distance * direction.y / norm)
            }
            lastConstructionPoint = projected; selectedFamily = settings.kind == .ellipse && selected != nil ? 1 : 0
        } else if settings.usesBox {
            if settings.boxSettings.learnsDimensions && !allDimensionsLearned { projected = processLearningBox(point, settings: settings) }
            else { projected = boxPoints.isEmpty ? point : processBox(point, settings: settings) }
        } else if settings.kind == .perspectiveEllipse {
            projected = RulerGeometry.nearest(point, on: curve)
        } else {
            if selected == nil {
                if settings.kind == .radial {
                    let evidence = hypot(start.x - settings.centerX, start.y - settings.centerY) > 2 ? start : point
                    guard hypot(evidence.x - settings.centerX, evidence.y - settings.centerY) > 2 else { return point }
                    selected = RulerGeometry.directions(settings, anchor: evidence).first
                    selectedFamily = 0
                } else {
                    if let choice = chooseDirection(point, origin: start, directions: RulerGeometry.directions(settings, anchor: start), settings: settings) {
                        selected = choice.direction; selectedFamily = choice.family
                    }
                }
            }
            if let selected {
                if settings.kind == .radial {
                    let radial = RulerGeometry.nearestRadial(point, center: settings.center, direction: selected, bend: settings.radialSettings.bend, previous: radialParameter)
                    radialParameter = radial.parameter
                    projected = radial.point
                } else { projected = RulerGeometry.line(point, origin: start, direction: selected) }
            } else {
                // Acquisition must not ink raw jitter before the axis locks.
                projected = start
            }
        }
        let accuracy = connectEndpoint ? 1 : settings.accuracy
        return CGPoint(x: point.x + (projected.x - point.x) * accuracy,
                       y: point.y + (projected.y - point.y) * accuracy)
    }
    @discardableResult
    mutating func cycleAxis(at output: CGPoint, input: CGPoint, settings: RulerSettings, preferredFamily: Int? = nil) -> Bool {
        guard settings.enabled, settings.accuracy > 0, settings.kind.supportsAxisCycling else { return false }
        clearTurn()
        if settings.usesBox {
            if settings.boxSettings.learnsDimensions, !allDimensionsLearned {
                guard anchor != nil else { return false }
                var learned = learnedExtents
                if let family = selectedFamily, learned[family] == nil {
                    guard abs(boxWorld[family]) >= 2 else { return false }
                    learned[family] = boxWorld[family]
                }
                guard let newAnchor = RulerGeometry.anchorForWorldPoint(settings, world: boxWorld, screen: output) else { return false }
                var completed = settings
                let complete = learned.allSatisfy { $0 != nil }
                if complete {
                    completed.boxSettings.extents = learned.map { $0! }
                    guard RulerGeometry.boxVertices(completed, anchor: newAnchor) != nil else { return false }
                }
                let directions = RulerGeometry.directions(settings, anchor: output)
                var next: Int?
                let choices = preferredFamily.map { [$0] } ?? (1...3).map { ((selectedFamily ?? -1) + $0) % 3 }
                for index in choices where directions.indices.contains(index) {
                    let direction = directions[index], norm = hypot(direction.x, direction.y)
                    guard norm > 1e-6 else { continue }
                    if let selected, abs(selected.x * direction.y - selected.y * direction.x) / (hypot(selected.x, selected.y) * norm) < 1e-6 { continue }
                    next = index; break
                }
                guard let next else { return false }
                anchor = newAnchor; learnedExtents = learned; boxSegmentWorld = boxWorld
                inputOffset = CGPoint(x: output.x - input.x, y: output.y - input.y)
                candidate = nil; candidateStart = nil
                if !complete { selectedFamily = next; selected = directions[next]; return true }
                boxPoints = RulerGeometry.boxVertices(completed, anchor: newAnchor)!
                boxVertex = (0..<3).reduce(0) { abs(boxWorld[$1] - learned[$1]!) < 1e-6 ? $0 | (1 << $1) : $0 }
                boxEdge = nil
            }
            guard !boxPoints.isEmpty else { return false }
            if let boxEdge, hypot(output.x - boxPoints[boxEdge.from].x, output.y - boxPoints[boxEdge.from].y) > 0.5 { return false }
            let family = preferredFamily ?? ((selectedFamily ?? -1) + 1) % 3
            guard (0..<3).contains(family) else { return false }
            let target = boxVertex ^ (1 << family), origin = boxPoints[boxVertex]
            let direction = CGPoint(x: boxPoints[target].x - origin.x, y: boxPoints[target].y - origin.y)
            guard hypot(direction.x, direction.y) > 1e-6 else { return false }
            boxEdge = (boxVertex, target); selected = direction; selectedFamily = family
            inputOffset = CGPoint(x: output.x - input.x, y: output.y - input.y)
            return true
        }
        let directions = RulerGeometry.directions(settings, anchor: output)
        guard !directions.isEmpty else { return false }
        let choices = preferredFamily.map { [$0] } ?? (1...directions.count).map { ((selectedFamily ?? -1) + $0) % directions.count }
        for family in choices where directions.indices.contains(family) {
            let direction = directions[family]
            let norm = hypot(direction.x, direction.y)
            guard norm > 1e-6 else { continue }
            if let selected, abs(selected.x * direction.y - selected.y * direction.x) / (hypot(selected.x, selected.y) * norm) < 1e-6 { continue }
            anchor = output; inputOffset = CGPoint(x: output.x - input.x, y: output.y - input.y)
            selected = direction; selectedFamily = family; candidate = nil; candidateStart = nil
            return true
        }
        return false
    }
    private mutating func chooseDirection(_ point: CGPoint, origin: CGPoint, directions: [CGPoint], settings: RulerSettings) -> (direction: CGPoint, family: Int)? {
        if settings.family > 0, directions.indices.contains(settings.family - 1) {
            let direction = directions[settings.family - 1]
            return hypot(direction.x, direction.y) > 1e-6 ? (direction, settings.family - 1) : nil
        }
        let distance = hypot(point.x - origin.x, point.y - origin.y)
        guard distance >= settings.selectionDistance else { candidate = nil; candidateStart = nil; return nil }
        let distinct = directions.enumerated().filter { hypot($0.element.x, $0.element.y) > 1e-6 }.reduce(into: [(direction: CGPoint, family: Int)]()) { result, item in
            let vector = item.element, norm = hypot(vector.x, vector.y)
            if !result.contains(where: { abs($0.direction.x * vector.y - $0.direction.y * vector.x) / (hypot($0.direction.x, $0.direction.y) * norm) < 1e-6 }) { result.append((vector, item.offset)) }
        }
        let ranked = distinct.map { item in
            let projected = RulerGeometry.line(point, origin: origin, direction: item.direction)
            return (item, hypot(point.x - projected.x, point.y - projected.y) / distance)
        }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { candidate = nil; candidateStart = nil; return nil }
        if ranked.count > 1, ranked[1].1 - best.1 < max(0.035, 2 / distance) { candidate = nil; candidateStart = nil; return nil }
        if candidate != best.0.direction { candidate = best.0.direction; candidateStart = point }
        guard let candidateStart, hypot(point.x - candidateStart.x, point.y - candidateStart.y) >= min(4, settings.selectionDistance / 2) else { return nil }
        return best.0
    }
    private mutating func processLearningBox(_ point: CGPoint, settings: RulerSettings) -> CGPoint {
        let origin = RulerGeometry.projectWorld(settings, anchor: anchor!, world: boxSegmentWorld) ?? anchor!
        if selected == nil, let choice = chooseDirection(point, origin: origin, directions: RulerGeometry.directions(settings, anchor: origin), settings: settings) {
            selected = choice.direction; selectedFamily = choice.family
        }
        guard let selected, let family = selectedFamily else { return origin }
        let projected = RulerGeometry.line(point, origin: origin, direction: selected)
        guard let distance = RulerGeometry.axisDistance(settings, anchor: anchor!, world: boxSegmentWorld, family: family, point: projected) else {
            return RulerGeometry.projectWorld(settings, anchor: anchor!, world: boxWorld) ?? origin
        }
        var next = boxSegmentWorld
        let coordinate = max(-10000, min(10000, boxSegmentWorld[family] + distance))
        if let bound = learnedExtents[family] { next[family] = min(max(0, bound), max(min(0, bound), coordinate)) }
        else { next[family] = coordinate }
        guard let result = RulerGeometry.projectWorld(settings, anchor: anchor!, world: next) else {
            return RulerGeometry.projectWorld(settings, anchor: anchor!, world: boxWorld) ?? origin
        }
        boxWorld = next
        return result
    }
    private mutating func processBox(_ point: CGPoint, settings: RulerSettings) -> CGPoint {
        if boxEdge == nil {
            let origin = boxPoints[boxVertex]
            let directions = (0..<3).map { family -> CGPoint in
                let target = boxPoints[boxVertex ^ (1 << family)]
                let vector = CGPoint(x: target.x - origin.x, y: target.y - origin.y)
                let distance = hypot(point.x - origin.x, point.y - origin.y), norm = hypot(vector.x, vector.y)
                let forward = (point.x - origin.x) * vector.x + (point.y - origin.y) * vector.y
                let error = abs((point.x - origin.x) * vector.y - (point.y - origin.y) * vector.x)
                return forward > 0 && norm > 1e-6 && error <= distance * norm * 0.4 ? vector : .zero
            }
            guard let choice = chooseDirection(point, origin: origin, directions: directions, settings: settings) else { return origin }
            boxEdge = (boxVertex, boxVertex ^ (1 << choice.family))
            selected = choice.direction; selectedFamily = choice.family
        }
        let edge = boxEdge!, a = boxPoints[edge.from], b = boxPoints[edge.to]
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 1e-12 else { boxEdge = nil; return a }
        let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / length
        let projected = CGPoint(x: a.x + min(1, max(0, t)) * dx, y: a.y + min(1, max(0, t)) * dy)
        if t >= 1 || t < -0.01 {
            boxVertex = t >= 1 ? edge.to : edge.from
            boxEdge = nil; selected = nil; selectedFamily = nil; candidate = nil; candidateStart = nil
        }
        return projected
    }

}


// Handle identities are shared by preview geometry and the native editor.
enum RulerHandleID: Hashable {
    case chainReset, parallelSpacing, constructionMode, move, rotate, size, axis, isometricAxis(Int), isometricPreset, radialMode, radialBend, radialSpacing, boxMode, boxLearn, boxSize(Int), reference, axisPolicy, cameraAxis(Int), cameraCircle, viewTilt, fieldOfView, tickDistance, familyMeasure(Int), horizon, ellipseRadius, ellipseMode, ellipseDepthMode, ellipseDepth, ellipseVP, ellipseSceneMode, ellipseScenePoint(Int), ellipseScale, cameraMode, sceneMode, scenePoint(Int, Int), corner(Int), edge(Int), vanishing(Int)
}

extension RulerSettings {
    mutating func matchScene(_ enabled: Bool) {
        if !enabled { sceneLines = nil; return }
        sceneLines = vanishingPoints.map { RulerGeometry.sceneLines(toward: SIMD3($0.x, $0.y, 1), center: center) }
    }
    var editingCenter: CGPoint {
        let points: [RulerPoint]
        switch kind {
        case .straight: return CGPoint(x: (constructionSettings.start.x + constructionSettings.end.x) / 2, y: (constructionSettings.start.y + constructionSettings.end.y) / 2)
        case .parallel, .connected, .ellipse, .radial, .isometric: return center
        case .perspective where camera != nil: return center
        case .perspective, .vanishing: points = sceneLines?.flatMap { $0 } ?? vanishingPoints
        case .perspectiveEllipse: return RulerPlane(sectionCorners)?.screen(CGPoint(x: 0.5, y: 0.5)) ?? center
        }
        return CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                       y: points.map(\.y).reduce(0, +) / Double(points.count))
    }
    var editHandles: [(id: RulerHandleID, point: CGPoint)] {
        let pivot = editingCenter
        var result: [(id: RulerHandleID, point: CGPoint)] = [(.move, pivot)]
        if kind == .vanishing || kind == .perspective && camera == nil {
            result.append((.sceneMode, CGPoint(x: pivot.x + 70, y: pivot.y + 70)))
            if vanishingPoints.count >= 2 { result.append((.horizon, CGPoint(x: pivot.x - 70, y: pivot.y - 70))) }
            if usesVanishingMeasurements, let reference = fixedReference?.cg {
                for (i, direction) in RulerGeometry.directions(self, anchor: reference).enumerated() {
                    let norm = hypot(direction.x, direction.y)
                    if norm > 1e-6 {
                        let distance = measurement(for: i).distance
                        result.append((.familyMeasure(i), CGPoint(x: reference.x + direction.x / norm * distance, y: reference.y + direction.y / norm * distance)))
                    }
                }
            }
        }
        if kind == .perspective { result.append((.cameraMode, CGPoint(x: pivot.x - 70, y: pivot.y + 70))) }
        switch kind {
        case .straight:
            result += [(.corner(0), constructionSettings.start.cg), (.corner(1), constructionSettings.end.cg)]
        case .parallel, .connected:
            result.append((.tickDistance, CGPoint(x: pivot.x + 80, y: pivot.y + 80)))
            if kind == .connected { result.append((.chainReset, CGPoint(x: pivot.x - 60, y: pivot.y + 60))) }
            else { result.append((.parallelSpacing, CGPoint(x: pivot.x + 100, y: pivot.y))) }
        case .ellipse:
            for i in 0..<2 {
                let d = RulerGeometry.direction(angle + Double(i) * 90), radius = i == 0 ? constructionSettings.radiusX : (constructionSettings.circle ? constructionSettings.radiusX : constructionSettings.radiusY)
                result.append((.corner(i), CGPoint(x: pivot.x + d.x * radius, y: pivot.y + d.y * radius)))
            }
            result.append((.constructionMode, CGPoint(x: pivot.x - 60, y: pivot.y + 60)))
        case .radial:
            result += [(.radialMode, CGPoint(x: pivot.x - 60, y: pivot.y + 60)),
                       (.radialBend, CGPoint(x: pivot.x + 120, y: pivot.y)),
                       (.radialSpacing, CGPoint(x: pivot.x - 120, y: pivot.y))]
        case .isometric:
            for (i, degrees) in isometricAngles.enumerated() {
                let direction = RulerGeometry.direction(degrees + orientation)
                result.append((.isometricAxis(i), CGPoint(x: pivot.x + direction.x * 120, y: pivot.y + direction.y * 120)))
            }
            result.append((.isometricPreset, CGPoint(x: pivot.x - 60, y: pivot.y + 60)))
        case .perspective where camera != nil:
            if camera!.points > 1 { result.append((.axis, CGPoint(x: pivot.x + 120, y: pivot.y))) }
            if camera!.points == 3 { result.append((.viewTilt, CGPoint(x: pivot.x, y: pivot.y + 120))) }
            result.append((.fieldOfView, CGPoint(x: pivot.x - 120, y: pivot.y)))
            if camera!.points == 3, camera!.customAxes != nil {
                for (i, direction) in camera!.directions(center: center, anchor: pivot).enumerated() {
                    let norm = hypot(direction.x, direction.y)
                    let visible = norm > 1e-6 ? CGPoint(x: direction.x / norm, y: direction.y / norm) : RulerGeometry.direction(Double(i) * 120)
                    result.append((.cameraAxis(i), CGPoint(x: pivot.x + visible.x * 160, y: pivot.y + visible.y * 160)))
                }
            }
            if cameraEllipse() != nil { result.append((.cameraCircle, CGPoint(x: pivot.x + 50, y: pivot.y + 50))) }
        case .perspective, .vanishing:
            if let sceneLines {
                for (family, line) in sceneLines.enumerated() {
                    result += line.enumerated().map { (.scenePoint(family, $0.offset), $0.element.cg) }
                }
            } else { result += vanishingPoints.enumerated().map { (.vanishing($0.offset), $0.element.cg) } }
        case .perspectiveEllipse:
            result.append((.ellipseDepthMode, CGPoint(x: pivot.x + 50, y: pivot.y + 50)))
            if depthSettings.enabled {
                result += [(.ellipseDepth, CGPoint(x: pivot.x, y: pivot.y + 80)),
                           (.ellipseScale, CGPoint(x: pivot.x + 80, y: pivot.y)),
                           (.ellipseSceneMode, CGPoint(x: pivot.x - 80, y: pivot.y))]
                if let lines = depthSettings.sceneLines {
                    result += lines.enumerated().map { (.ellipseScenePoint($0.offset), $0.element.cg) }
                } else { result.append((.ellipseVP, depthSettings.vanishingPoint.cg)) }
            }
            result.append((.ellipseMode, CGPoint(x: pivot.x - 50, y: pivot.y + 50)))
            if let point = RulerPlane(sectionCorners)?.screen(CGPoint(x: 0.5 + sectionRadius / 2, y: 0.5)) {
                result.append((.ellipseRadius, point))
            }
            for i in 0..<4 {
                let quad = sectionCorners
                guard quad.count == 4 else { continue }
                result.append((.corner(i), ellipseEditFrame()[i].cg))
                let next = quad[(i + 1) % 4]
                result.append((.edge(i), CGPoint(x: (quad[i].x + next.x) / 2, y: (quad[i].y + next.y) / 2)))
            }
        }
        if kind == .isometric || kind == .perspective || kind == .radial {
            result.append((.tickDistance, CGPoint(x: pivot.x + 80, y: pivot.y + 80)))
        }
        if kind == .isometric || kind == .perspective || kind == .vanishing {
            result.append((.reference, fixedReference?.cg ?? CGPoint(x: pivot.x + 50, y: pivot.y - 50)))
            result.append((.axisPolicy, CGPoint(x: pivot.x - 50, y: pivot.y + 50)))
        }
        if kind == .isometric || kind == .perspective && camera != nil {
            result.append((.boxMode, CGPoint(x: pivot.x - 80, y: pivot.y - 80)))
            if boxSettings.enabled { result.append((.boxLearn, CGPoint(x: pivot.x - 120, y: pivot.y - 80))) }
            if !boxSettings.learnsDimensions, let vertices = RulerGeometry.boxVertices(self, anchor: pivot) {
                result += (0..<3).map { (.boxSize($0), vertices[1 << $0]) }
            }
        }
        let radius: Double
        switch kind {
        case .radial, .isometric: radius = 80
        case .perspectiveEllipse:
            radius = max(80, (ellipseEditFrame().map { hypot($0.x - pivot.x, $0.y - pivot.y) }.max() ?? 80) + 48)
        default:
            let extent = result.map { Double(hypot($0.point.x - pivot.x, $0.point.y - pivot.y)) }.max() ?? 80
            radius = max(80, min(50000, extent + 48))
        }
        result.append((.rotate, CGPoint(x: pivot.x, y: pivot.y - radius)))
        if kind == .perspectiveEllipse || kind == .perspective || kind == .vanishing {
            result.append((.size, CGPoint(x: pivot.x + radius, y: pivot.y)))
        }
        return result
    }
    // Delta is in Quartz screen points. Every update derives from the gesture's
    // original geometry, avoiding cumulative rounding and frame-rate dependence.
    func editing(_ handle: RulerHandleID, delta: CGPoint, screenSpace: Bool = false, referenceOrigin: CGPoint? = nil, snap: Bool = false) -> RulerSettings? {
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        if kind == .perspectiveEllipse, depthSettings.enabled, depthSettings.offset != 0 {
            switch handle {
            case .corner, .edge:
                guard let v = depthVector else { return nil }
                var baked = self; baked.corners = sectionCorners; baked.depthSettings.offset = 0; baked.circleRadius = sectionRadius; baked.depthSettings.scale = 1
                guard let edited = baked.editing(handle, delta: delta, screenSpace: screenSpace, referenceOrigin: referenceOrigin, snap: snap),
                      let plane = RulerPlane(edited.corners) else { return nil }
                var restored = self
                let units = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                let factor = 1 + v.z * depthSettings.offset
                restored.corners = units.compactMap { unit in
                    let q = plane.homogeneous(unit) * factor - v * depthSettings.offset
                    guard q.z > 1e-8 else { return nil }
                    return RulerPoint(x: q.x / q.z, y: q.y / q.z)
                }
                guard let offset = restored.depthOffset(matching: edited.corners) else { return nil }
                restored.depthSettings.offset = offset
                return (try? restored.validate()) != nil ? restored : nil
            default: break
            }
        }
        var next = self
        let pivot = editingCenter
        func quantized(_ value: Double, step: Double) -> Double { snap ? (value / step).rounded() * step : value }
        func move(_ p: RulerPoint) -> RulerPoint { RulerPoint(x: p.x + delta.x, y: p.y + delta.y) }
        switch handle {
        case .chainReset:
            guard kind == .connected, hypot(delta.x, delta.y) < 3 else { return nil }
            next.constructionSettings.resetID = constructionSettings.resetID &+ 1
        case .parallelSpacing:
            next.constructionSettings.spacing = max(2, min(10000, constructionSettings.spacing + delta.x))
        case .constructionMode:
            let modes = RulerEllipseMode.allCases
            next.constructionSettings.sizing = modes[(modes.firstIndex(of: constructionSettings.sizing)! + 1) % modes.count]
        case .move:
            switch kind {
            case .straight:
                next.constructionSettings.start = move(constructionSettings.start); next.constructionSettings.end = move(constructionSettings.end)
            case .parallel, .connected, .ellipse: next.centerX += delta.x; next.centerY += delta.y
            case .perspective where camera != nil: next.centerX += delta.x; next.centerY += delta.y
            case .radial, .isometric: next.centerX += delta.x; next.centerY += delta.y
            case .perspectiveEllipse:
                let section: [RulerPoint]
                if screenSpace {
                    next.corners = corners.map(move)
                    if ellipseDepth != nil {
                        next.depthSettings.vanishingPoint = move(depthSettings.vanishingPoint)
                        next.depthSettings.sceneLines = depthSettings.sceneLines?.map(move)
                    }
                    section = sectionCorners.map(move)
                } else {
                    guard let plane = RulerPlane(corners), let topPlane = RulerPlane(sectionCorners),
                          let target = topPlane.unit(CGPoint(x: pivot.x + delta.x, y: pivot.y + delta.y)) else { return nil }
                    let tx = quantized(target.x - 0.5, step: planeStep), ty = quantized(target.y - 0.5, step: planeStep)
                    guard let moved = plane.rectangle(x: tx, y: ty) else { return nil }
                    next.corners = moved
                    section = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].compactMap { unit in
                        sectionPoint(CGPoint(x: unit.x + tx, y: unit.y + ty), offset: depthSettings.offset).map { RulerPoint(x: $0.x, y: $0.y) }
                    }
                }
                if depthSettings.enabled, depthSettings.offset != 0 {
                    guard let offset = next.depthOffset(matching: section) else { return nil }
                    next.depthSettings.offset = offset
                }
            case .perspective, .vanishing:
                next.vanishingPoints = vanishingPoints.map(move)
                next.sceneLines = sceneLines?.map { $0.map(move) }
            }
        case .corner(let index) where kind == .straight:
            if index == 0 { next.constructionSettings.start = move(constructionSettings.start) }
            else { next.constructionSettings.end = move(constructionSettings.end) }
        case .corner(let index) where kind == .ellipse:
            guard let p = editHandles.first(where: { $0.id == handle })?.point else { return nil }
            let local = RulerGeometry.ellipseLocal(CGPoint(x: p.x + delta.x, y: p.y + delta.y), settings: self)
            if index == 0 { next.constructionSettings.radiusX = abs(local.x) }
            else { next.constructionSettings.radiusY = abs(local.y) }
        case .corner(let index):
            guard kind == .perspectiveEllipse, corners.indices.contains(index) else { return nil }
            let frame = ellipseEditFrame()
            guard let oldPlane = RulerPlane(frame) else { return nil }
            var changed = frame
            let target = move(frame[index])
            if snap, !screenSpace {
                guard let plane = RulerPlane(frame), let unit = plane.unit(target.cg) else { return nil }
                let width = quantized((unit.x - 0.5) * (index == 0 || index == 3 ? -2 : 2), step: planeStep)
                let height = quantized((unit.y - 0.5) * (index < 2 ? -2 : 2), step: planeStep)
                guard let resized = plane.rectangle(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height) else { return nil }
                changed = resized
            } else if screenSpace {
                let candidates = [(index + 1) % 4, (index + 3) % 4].map { other in
                    RulerGeometry.line(target.cg, origin: frame[index].cg, direction: CGPoint(x: frame[other].x - frame[index].x, y: frame[other].y - frame[index].y))
                }
                let closest = candidates.min { hypot($0.x - target.x, $0.y - target.y) < hypot($1.x - target.x, $1.y - target.y) }!
                changed[index] = RulerPoint(x: closest.x, y: closest.y)
            } else { changed[index] = target }
            guard let newPlane = RulerPlane(changed) else { return nil }
            next.corners = corners.compactMap { point in
                oldPlane.unit(point.cg).flatMap { newPlane.screen($0) }.map { RulerPoint(x: $0.x, y: $0.y) }
            }
        case .edge(let index):
            guard kind == .perspectiveEllipse, corners.indices.contains(index) else { return nil }
            if screenSpace {
                next.corners[index] = move(corners[index])
                next.corners[(index + 1) % 4] = move(corners[(index + 1) % 4])
            } else {
                guard let plane = RulerPlane(corners), let handlePoint = editHandles.first(where: { $0.id == handle })?.point,
                      let target = plane.unit(CGPoint(x: handlePoint.x + delta.x, y: handlePoint.y + delta.y)) else { return nil }
                let tx = quantized(target.x - (index == 1 ? 1 : 0), step: planeStep)
                let ty = quantized(target.y - (index == 2 ? 1 : 0), step: planeStep)
                let x = index == 3 ? tx : (snap && index == 1 ? -tx : 0)
                let y = index == 0 ? ty : (snap && index == 2 ? -ty : 0)
                let right = index == 1 ? 1 + tx : (snap && index == 3 ? 1 - tx : 1)
                let bottom = index == 2 ? 1 + ty : (snap && index == 0 ? 1 - ty : 1)
                guard let resized = plane.rectangle(x: x, y: y, width: right - x, height: bottom - y) else { return nil }
                next.corners = resized
            }
        case .scenePoint(let family, let point):
            guard let lines = sceneLines, lines.indices.contains(family), lines[family].indices.contains(point) else { return nil }
            guard let edited = RulerGeometry.editSceneLine(lines[family], index: point, delta: delta, translate: snap, align: screenSpace,
                horizon: family == 2 ? RulerGeometry.horizon(self)?.direction : nil) else { return nil }
            next.sceneLines![family] = edited
        case .vanishing(let index):
            guard vanishingPoints.indices.contains(index) else { return nil }
            var target = move(vanishingPoints[index])
            if snap, index < 2, let horizon = RulerGeometry.horizon(self) {
                let point = RulerGeometry.line(target.cg, origin: horizon.origin, direction: horizon.direction)
                target = RulerPoint(x: point.x, y: point.y)
            } else if screenSpace {
                for other in vanishingPoints.indices where other != index {
                    if abs(target.x - vanishingPoints[other].x) <= 8 { target.x = vanishingPoints[other].x }
                    if abs(target.y - vanishingPoints[other].y) <= 8 { target.y = vanishingPoints[other].y }
                }
            }
            next.vanishingPoints[index] = target
        case .cameraAxis(let i):
            guard kind == .perspective, camera != nil, (0..<3).contains(i) else { return nil }
            next.camera!.enableCustomAxes(true)
            next.camera!.worldAxesSettings[i].azimuth = (camera!.worldAxesSettings[i].azimuth + delta.x / 3).remainder(dividingBy: 360)
            next.camera!.worldAxesSettings[i].incline = max(-90, min(90, camera!.worldAxesSettings[i].incline + delta.y / 3))
        case .cameraCircle:
            guard hypot(delta.x, delta.y) < 3 else { return nil }
            return cameraEllipse(at: referenceOrigin)
        case .axisPolicy:
            guard kind.supportsAxisCycling else { return nil }
            if hypot(delta.x, delta.y) < 3 { next.changesAxesAutomatically.toggle() }
        case .reference:
            guard kind == .isometric || kind == .perspective || kind == .vanishing else { return nil }
            let origin = fixedReference?.cg ?? referenceOrigin ?? pivot
            if hypot(delta.x, delta.y) < 3 {
                next.fixedReference = fixedReference == nil ? RulerPoint(x: origin.x, y: origin.y) : nil
            } else { next.fixedReference = RulerPoint(x: origin.x + delta.x, y: origin.y + delta.y) }
        case .boxMode:
            guard kind == .isometric || kind == .perspective && camera != nil else { return nil }
            if hypot(delta.x, delta.y) < 3 { next.boxSettings.enabled.toggle() }
        case .boxLearn:
            guard usesBox else { return nil }
            if hypot(delta.x, delta.y) < 3 { next.boxSettings.learnsDimensions.toggle() }
        case .boxSize(let i):
            guard (0..<3).contains(i), let vertices = RulerGeometry.boxVertices(self, anchor: pivot) else { return nil }
            let target = CGPoint(x: vertices[1 << i].x + delta.x, y: vertices[1 << i].y + delta.y)
            guard let extent = RulerGeometry.axisDistance(self, anchor: pivot, world: .zero, family: i, point: target) else { return nil }
            guard extent.isFinite, abs(extent) >= 2 else { return nil }
            next.boxSettings.extents[i] = max(-10000, min(10000, extent))
        case .radialMode:
            guard kind == .radial else { return nil }
            if hypot(delta.x, delta.y) < 3 { next.radialSettings.locked.toggle() }
        case .radialBend:
            guard kind == .radial else { return nil }
            next.radialSettings.bend = max(-2, min(2, radialSettings.bend + delta.y / 200))
        case .radialSpacing:
            guard kind == .radial else { return nil }
            next.spacing = max(1, min(90, spacing + delta.x / 10))
        case .isometricPreset:
            guard kind == .isometric else { return nil }
            if hypot(delta.x, delta.y) < 3 { next.useIsometricPreset(isometricPreset.map { ($0 + 1) % 3 } ?? 0) }
        case .isometricAxis(let i):
            guard kind == .isometric, (0..<3).contains(i), let point = editHandles.first(where: { $0.id == handle })?.point else { return nil }
            let x = point.x + delta.x - pivot.x, y = point.y + delta.y - pivot.y
            guard hypot(x, y) > 2 else { return nil }
            next.isometricAngles[i] = (atan2(y, x) * 180 / .pi - orientation).remainder(dividingBy: 360)
        case .sceneMode:
            guard kind == .vanishing || kind == .perspective && camera == nil else { return nil }
            if hypot(delta.x, delta.y) < 3 { next.matchScene(sceneLines == nil) }
        case .cameraMode:
            guard kind == .perspective else { return nil }
            if hypot(delta.x, delta.y) < 3 {
                if next.camera == nil { next.camera = RulerCamera() }
                else { next.camera!.points = camera!.points % 3 + 1 }
            }
        case .ellipseDepthMode:
            guard kind == .perspectiveEllipse, hypot(delta.x, delta.y) < 3 else { return nil }
            next.enableDepth(!depthSettings.enabled)
        case .ellipseSceneMode:
            guard kind == .perspectiveEllipse, depthSettings.enabled, hypot(delta.x, delta.y) < 3 else { return nil }
            next.matchDepthScene(depthSettings.sceneLines == nil)
        case .ellipseScenePoint(let index):
            guard depthSettings.enabled, let lines = depthSettings.sceneLines, lines.indices.contains(index) else { return nil }
            guard let edited = RulerGeometry.editSceneLine(lines, index: index, delta: delta, translate: snap, align: screenSpace) else { return nil }
            next.depthSettings.sceneLines = edited
        case .ellipseVP:
            guard depthSettings.enabled else { return nil }
            next.depthSettings.vanishingPoint = move(depthSettings.vanishingPoint)
        case .ellipseScale:
            guard depthSettings.enabled else { return nil }
            let radius = quantized(sectionRadius * exp(delta.x / 150), step: circleStep)
            next.depthSettings.scale = max(0.02, min(20, radius / circleRadius))
        case .ellipseDepth:
            guard depthSettings.enabled, let plane = RulerPlane(corners), let v = depthVector else { return nil }
            if hypot(delta.x, delta.y) < 3 {
                next.depthSettings.offset += snap ? -depthSettings.step : depthSettings.step
                break
            }
            let q = plane.homogeneous(CGPoint(x: 0.5, y: 0.5))
            let target = CGPoint(x: pivot.x + delta.x, y: pivot.y + delta.y)
            let dx = target.x * v.z - v.x, dy = target.y * v.z - v.y
            if hypot(v.x - q.x / q.z * v.z, v.y - q.y / q.z * v.z) < 1e-6 { next.depthSettings.offset += delta.x }
            else { next.depthSettings.offset = abs(dx) > abs(dy) ? (q.x - target.x * q.z) / dx : (q.y - target.y * q.z) / dy }
            next.depthSettings.offset = quantized(next.depthSettings.offset, step: depthSettings.step)
        case .ellipseMode:
            guard kind == .perspectiveEllipse else { return nil }
            if hypot(delta.x, delta.y) < 3 {
                let modes = RulerEllipseMode.allCases
                next.ellipseSizing = modes[(modes.firstIndex(of: ellipseSizing)! + 1) % modes.count]
            }
        case .ellipseRadius:
            guard kind == .perspectiveEllipse, let plane = RulerPlane(sectionCorners),
                  let point = editHandles.first(where: { $0.id == handle })?.point,
                  let unit = plane.unit(CGPoint(x: point.x + delta.x, y: point.y + delta.y)) else { return nil }
            next.circleRadius = max(0.02, min(20, quantized(2 * hypot(unit.x - 0.5, unit.y - 0.5), step: circleStep) / (depthSettings.enabled ? depthSettings.scale : 1)))
        case .viewTilt:
            guard kind == .perspective, camera != nil else { return nil }
            next.camera!.pitch = max(-85, min(85, camera!.pitch + delta.y / 3))
        case .fieldOfView:
            guard kind == .perspective, camera != nil else { return nil }
            next.camera!.fieldOfView = max(5, min(160, camera!.fieldOfView + delta.x / 4))
        case .horizon:
            guard kind == .vanishing || kind == .perspective && camera == nil, hypot(delta.x, delta.y) < 3 else { return nil }
            next.showsHorizon.toggle()
        case .familyMeasure(let i):
            guard usesVanishingMeasurements, let reference = fixedReference?.cg else { return nil }
            let directions = RulerGeometry.directions(self, anchor: reference)
            guard directions.indices.contains(i), let point = editHandles.first(where: { $0.id == handle })?.point else { return nil }
            let direction = directions[i], norm = hypot(direction.x, direction.y)
            guard norm > 1e-6 else { return nil }
            var value = measurement(for: i)
            let distance = ((point.x + delta.x - reference.x) * direction.x + (point.y + delta.y - reference.y) * direction.y) / norm
            let v = RulerGeometry.vanishingPoint(self, family: i)!
            let limit = v.z > 1e-12 ? min(10000, norm / v.z * 0.99) : 10000
            guard limit >= 2 else { return nil }
            value.distance = max(2, min(limit, distance)); next.setMeasurement(value, family: i)
        case .tickDistance:
            next.measureSettings.visible = hypot(delta.x, delta.y) < 3 ? !measureSettings.visible : true
            next.measureSettings.distance = max(2, min(10000, measureSettings.distance + delta.x))
        case .axis where kind == .perspective && camera != nil:
            next.camera!.yaw = (camera!.yaw + delta.x / 3).remainder(dividingBy: 360)
        case .axis:
            guard kind == .isometric, let point = editHandles.first(where: { $0.id == handle })?.point else { return nil }
            let x = point.x + delta.x - pivot.x, y = point.y + delta.y - pivot.y
            guard hypot(x, y) > 2 else { return nil }
            next.angle = atan2(y, x) * 180 / .pi - orientation
        case .rotate, .size:
            guard let point = editHandles.first(where: { $0.id == handle })?.point else { return nil }
            let x = point.x - pivot.x, y = point.y - pivot.y
            let nx = x + delta.x, ny = y + delta.y
            guard hypot(nx, ny) > 2 else { return nil }
            let radians = handle == .rotate ? atan2(ny, nx) - atan2(y, x) : 0
            let scale = handle == .size ? hypot(nx, ny) / hypot(x, y) : 1
            func transform(_ p: RulerPoint) -> RulerPoint {
                let dx = (p.x - pivot.x) * scale, dy = (p.y - pivot.y) * scale
                return RulerPoint(x: pivot.x + dx * cos(radians) - dy * sin(radians),
                                  y: pivot.y + dx * sin(radians) + dy * cos(radians))
            }
            switch kind {
            case .straight:
                next.constructionSettings.start = transform(constructionSettings.start); next.constructionSettings.end = transform(constructionSettings.end)
            case .parallel, .connected, .ellipse: next.angle = (angle + radians * 180 / .pi).remainder(dividingBy: 360)
            case .radial: next.angle = (angle + radians * 180 / .pi).remainder(dividingBy: 360)
            case .isometric: next.orientation = (orientation + radians * 180 / .pi).remainder(dividingBy: 360)
            case .perspective where camera != nil:
                if handle == .rotate { next.camera!.roll = (camera!.roll + radians * 180 / .pi).remainder(dividingBy: 360) }
                else { next.camera!.viewRadius = max(20, min(20000, camera!.viewRadius * scale)) }
            case .perspective, .vanishing:
                next.vanishingPoints = vanishingPoints.map(transform)
                next.sceneLines = sceneLines?.map { $0.map(transform) }
            case .perspectiveEllipse:
                next.corners = corners.map(transform)
                if ellipseDepth != nil {
                    next.depthSettings.vanishingPoint = transform(depthSettings.vanishingPoint)
                    next.depthSettings.sceneLines = depthSettings.sceneLines?.map(transform)
                }
                if depthSettings.enabled, depthSettings.offset != 0 {
                    guard let offset = next.depthOffset(matching: sectionCorners.map(transform)) else { return nil }
                    next.depthSettings.offset = offset
                }
            }
        }
        return (try? next.validate()) != nil ? next : nil
    }
}
