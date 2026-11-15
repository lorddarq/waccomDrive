import Foundation
import CoreGraphics

enum RulerKind: String, Codable, CaseIterable, Identifiable {
    case perspective, isometric, vanishing, radial, perspectiveEllipse
    var id: String { rawValue }
    var title: String {
        switch self {
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
struct RulerCamera: Codable, Equatable {
    var points = 3
    var fieldOfView = 60.0
    var viewRadius = 600.0
    var yaw = 45.0
    var pitch = 20.0
    var roll = 0.0
    var focalLength: Double { viewRadius / tan(fieldOfView * .pi / 360) }
    var axes: [SIMD3<Double>] {
        let y = (points == 1 ? 0 : yaw) * .pi / 180
        let p = (points < 3 ? 0 : pitch) * .pi / 180, r = roll * .pi / 180
        return [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))].map { v in
            let vy = v.y * cos(p) - v.z * sin(p), vz = v.y * sin(p) + v.z * cos(p)
            return SIMD3(v.x * cos(r) - vy * sin(r), v.x * sin(r) + vy * cos(r), vz)
        }
    }
    func directions(center: CGPoint, anchor: CGPoint) -> [CGPoint] {
        axes.map { CGPoint(x: focalLength * $0.x + (center.x - anchor.x) * $0.z,
                           y: focalLength * $0.y + (center.y - anchor.y) * $0.z) }
    }
    func validate() throws {
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

struct RulerSettings: Codable, Equatable {
    var enabled = false
    var visible = true
    var kind = RulerKind.radial
    var accuracy = 0.0
    var opacity = 0.25
    var camera: RulerCamera?
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
        try camera?.validate()
        try measureSettings.validate()
        let values = [centerX, centerY, angle, spacing, accuracy, opacity, orientation] + (vanishingPoints + corners).flatMap { [$0.x, $0.y] }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 100000 }),
              (0...1).contains(accuracy), (0.1...1).contains(opacity),
              selectionDistance.isFinite, (2...50).contains(selectionDistance), (0...6).contains(family),
              (1...90).contains(spacing), (-360...360).contains(angle),
              (1...6).contains(vanishingPoints.count), corners.count == 4 else {
            throw SettingsError.invalid("Ruler values are outside their allowed range.")
        }
        guard RulerGeometry.projectedCircle(corners) != nil else {
            throw SettingsError.invalid("Perspective ellipse corners must form a convex, non-collapsed quadrilateral in order.")
        }
    }
    var center: CGPoint { CGPoint(x: centerX, y: centerY) }
}

// Shared screen-point geometry for guide rendering and bounded projection.
enum RulerGeometry {
    static func line(_ point: CGPoint, origin: CGPoint, direction: CGPoint) -> CGPoint {
        let d = direction.x * direction.x + direction.y * direction.y
        guard d > 1e-12 else { return point }
        let t = ((point.x - origin.x) * direction.x + (point.y - origin.y) * direction.y) / d
        return CGPoint(x: origin.x + t * direction.x, y: origin.y + t * direction.y)
    }
    static func direction(_ degrees: Double) -> CGPoint {
        CGPoint(x: cos(degrees * .pi / 180), y: sin(degrees * .pi / 180))
    }
    static func directions(_ settings: RulerSettings, anchor: CGPoint) -> [CGPoint] {
        switch settings.kind {
        case .isometric: return [settings.angle, 180 - settings.angle, 90].map { direction($0 + settings.orientation) }
        case .perspective where settings.camera != nil:
            return settings.camera!.directions(center: settings.center, anchor: anchor)
        case .perspective, .vanishing:
            return settings.vanishingPoints.map { CGPoint(x: $0.x - anchor.x, y: $0.y - anchor.y) }
        case .radial:
            let theta = atan2(anchor.y - settings.centerY, anchor.x - settings.centerX) * 180 / .pi
            return [direction(((theta - settings.angle) / settings.spacing).rounded() * settings.spacing + settings.angle)]
        case .perspectiveEllipse: return []
        }
    }
    // Equal world steps at the anchor's image-plane depth. Skip the camera plane
    // and the invisible half-space rather than reflecting ticks through infinity.
    static func ticks(_ settings: RulerSettings, anchor: CGPoint, family: Int) -> [(point: CGPoint, major: Bool)] {
        let measure = settings.measureSettings
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
                point = CGPoint(x: anchor.x + t * direction.x / norm, y: anchor.y + t * direction.y / norm)
            }
            guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 300000, abs(point.y) <= 300000 else { return nil }
            return (point, i % measure.divisions == 0)
        }
    }
    // Unit square -> convex screen quadrilateral homography; sample the inscribed circle.
    static func projectedCircle(_ corners: [RulerPoint]) -> [CGPoint]? {
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
        let g = (sx * dy2 - dx2 * sy) / det, h = (dx1 * sy - sx * dy1) / det
        let a = p[1].x - p[0].x + g * p[1].x, b = p[3].x - p[0].x + h * p[3].x
        let d = p[1].y - p[0].y + g * p[1].y, e = p[3].y - p[0].y + h * p[3].y
        var points: [CGPoint] = []
        for i in 0...512 {
            let t = Double(i) * 2 * .pi / 512
            let u = 0.5 + 0.5 * cos(t), v = 0.5 + 0.5 * sin(t), w = g * u + h * v + 1
            guard abs(w) > 1e-9 else { return nil }
            let point = CGPoint(x: (a * u + b * v + p[0].x) / w, y: (d * u + e * v + p[0].y) / w)
            guard point.x.isFinite, point.y.isFinite else { return nil }
            points.append(point)
        }
        return points
    }
    static func nearest(_ point: CGPoint, on curve: [CGPoint]) -> CGPoint {
        var result = point, distance = Double.infinity
        for i in 1..<curve.count {
            let a = curve[i - 1], b = curve[i]
            let dx = b.x - a.x, dy = b.y - a.y, denominator = dx * dx + dy * dy
            guard denominator > 1e-12 else { continue }
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator))
            let candidate = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let delta = hypot(point.x - candidate.x, point.y - candidate.y)
            if delta < distance { result = candidate; distance = delta }
        }
        return result
    }
}

struct RulerProjection {
    private(set) var anchor: CGPoint?
    private(set) var selected: CGPoint?
    private var candidate: CGPoint?
    private var candidateStart: CGPoint?
    private var curve: [CGPoint] = []
    mutating func configure(_ settings: RulerSettings) {
        reset()
        curve = settings.kind == .perspectiveEllipse ? RulerGeometry.projectedCircle(settings.corners) ?? [] : []
    }
    mutating func reset() { anchor = nil; selected = nil; candidate = nil; candidateStart = nil }
    mutating func process(_ point: CGPoint, settings: RulerSettings) -> CGPoint {
        guard settings.enabled, settings.accuracy > 0 else { return point }
        if anchor == nil { anchor = point }
        let start = anchor!
        let projected: CGPoint
        if settings.kind == .perspectiveEllipse {
            projected = RulerGeometry.nearest(point, on: curve)
        } else {
            if selected == nil {
                if settings.kind == .radial {
                    selected = RulerGeometry.directions(settings, anchor: start).first
                } else {
                    let directions = RulerGeometry.directions(settings, anchor: start)
                    if settings.family > 0, directions.indices.contains(settings.family - 1) {
                        selected = directions[settings.family - 1]
                    } else {
                        let distance = hypot(point.x - start.x, point.y - start.y)
                        guard distance >= settings.selectionDistance else {
                            candidate = nil; candidateStart = nil
                            return point
                        }
                        let distinct = directions.filter { hypot($0.x, $0.y) > 1e-6 }.reduce(into: [CGPoint]()) { result, candidate in
                            let length = hypot(candidate.x, candidate.y)
                            if !result.contains(where: { abs($0.x * candidate.y - $0.y * candidate.x) / (hypot($0.x, $0.y) * length) < 1e-6 }) { result.append(candidate) }
                        }
                        let ranked = distinct.map { direction in
                            let projected = RulerGeometry.line(point, origin: start, direction: direction)
                            return (direction, hypot(point.x - projected.x, point.y - projected.y) / distance)
                        }.sorted { $0.1 < $1.1 }
                        guard let best = ranked.first else { return point }
                        // Ambiguous near-parallel families need more direction evidence, not a premature lock.
                        if ranked.count > 1, ranked[1].1 - best.1 < max(0.035, 2 / distance) {
                            candidate = nil; candidateStart = nil
                            return point
                        }
                        // Require spatially sustained agreement, not one noisy threshold-crossing report.
                        // Distance-based evidence behaves the same at different report rates.
                        if candidate != best.0 { candidate = best.0; candidateStart = point }
                        guard let candidateStart,
                              hypot(point.x - candidateStart.x, point.y - candidateStart.y) >= min(4, settings.selectionDistance / 2) else { return point }
                        selected = best.0
                    }
                }
            }
            guard let selected else { return point }
            projected = RulerGeometry.line(point, origin: settings.kind == .radial ? settings.center : start, direction: selected)
        }
        return CGPoint(x: point.x + (projected.x - point.x) * settings.accuracy,
                       y: point.y + (projected.y - point.y) * settings.accuracy)
    }
}


// Handle identities are shared by preview geometry and the native editor.
enum RulerHandleID: Hashable {
    case move, rotate, size, axis, viewTilt, fieldOfView, tickDistance, corner(Int), edge(Int), vanishing(Int)
}

extension RulerSettings {
    var editingCenter: CGPoint {
        let points: [RulerPoint]
        switch kind {
        case .radial, .isometric: return center
        case .perspective where camera != nil: return center
        case .perspective, .vanishing: points = vanishingPoints
        case .perspectiveEllipse: points = corners
        }
        return CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                       y: points.map(\.y).reduce(0, +) / Double(points.count))
    }
    var editHandles: [(id: RulerHandleID, point: CGPoint)] {
        let pivot = editingCenter
        var result: [(id: RulerHandleID, point: CGPoint)] = [(.move, pivot)]
        switch kind {
        case .radial: break
        case .isometric:
            let direction = RulerGeometry.direction(angle + orientation)
            result.append((.axis, CGPoint(x: pivot.x + direction.x * 120, y: pivot.y + direction.y * 120)))
        case .perspective where camera != nil:
            result += [(.axis, CGPoint(x: pivot.x + 120, y: pivot.y)),
                       (.viewTilt, CGPoint(x: pivot.x, y: pivot.y + 120)),
                       (.fieldOfView, CGPoint(x: pivot.x - 120, y: pivot.y))]
        case .perspective, .vanishing:
            result += vanishingPoints.enumerated().map { (.vanishing($0.offset), $0.element.cg) }
        case .perspectiveEllipse:
            for i in 0..<4 {
                result.append((.corner(i), corners[i].cg))
                let next = corners[(i + 1) % 4]
                result.append((.edge(i), CGPoint(x: (corners[i].x + next.x) / 2, y: (corners[i].y + next.y) / 2)))
            }
        }
        if measureSettings.visible, kind == .isometric || kind == .perspective || kind == .radial {
            result.append((.tickDistance, CGPoint(x: pivot.x + 80, y: pivot.y + 80)))
        }
        let radius: Double
        switch kind {
        case .radial, .isometric: radius = 80
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
    func editing(_ handle: RulerHandleID, delta: CGPoint) -> RulerSettings? {
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        var next = self
        let pivot = editingCenter
        func move(_ p: RulerPoint) -> RulerPoint { RulerPoint(x: p.x + delta.x, y: p.y + delta.y) }
        switch handle {
        case .move:
            switch kind {
            case .perspective where camera != nil: next.centerX += delta.x; next.centerY += delta.y
            case .radial, .isometric: next.centerX += delta.x; next.centerY += delta.y
            case .perspectiveEllipse: next.corners = corners.map(move)
            case .perspective, .vanishing: next.vanishingPoints = vanishingPoints.map(move)
            }
        case .corner(let index):
            guard kind == .perspectiveEllipse, corners.indices.contains(index) else { return nil }
            next.corners[index] = move(corners[index])
        case .edge(let index):
            guard kind == .perspectiveEllipse, corners.indices.contains(index) else { return nil }
            next.corners[index] = move(corners[index])
            next.corners[(index + 1) % 4] = move(corners[(index + 1) % 4])
        case .vanishing(let index):
            guard vanishingPoints.indices.contains(index) else { return nil }
            next.vanishingPoints[index] = move(vanishingPoints[index])
        case .viewTilt:
            guard kind == .perspective, camera != nil else { return nil }
            next.camera!.pitch = max(-85, min(85, camera!.pitch + delta.y / 3))
        case .fieldOfView:
            guard kind == .perspective, camera != nil else { return nil }
            next.camera!.fieldOfView = max(5, min(160, camera!.fieldOfView + delta.x / 4))
        case .tickDistance:
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
            case .radial: next.angle = (angle + radians * 180 / .pi).remainder(dividingBy: 360)
            case .isometric: next.orientation = (orientation + radians * 180 / .pi).remainder(dividingBy: 360)
            case .perspective where camera != nil:
                if handle == .rotate { next.camera!.roll = (camera!.roll + radians * 180 / .pi).remainder(dividingBy: 360) }
                else { next.camera!.viewRadius = max(20, min(20000, camera!.viewRadius * scale)) }
            case .perspective, .vanishing: next.vanishingPoints = vanishingPoints.map(transform)
            case .perspectiveEllipse: next.corners = corners.map(transform)
            }
        }
        return (try? next.validate()) != nil ? next : nil
    }
}
