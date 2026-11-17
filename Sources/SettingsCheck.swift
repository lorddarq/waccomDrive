#if !APP
import Foundation
import CoreGraphics

func checkRulerPickerShortcut() throws {
    var settings = DriverSettings()
    let standard = settings.pickerShortcut!
    assert(standard.keyCode == 15 && standard.modifiers == CGEventFlags([.maskControl, .maskAlternate]).rawValue)
    try settings.validate()
    settings.pickerShortcut = nil
    let disabled = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(settings))
    assert(disabled.pickerShortcut == nil, "Explicit shortcut clearing must survive restart")
    settings.pickerShortcut = CustomKeyShortcut(keyCode: 15, modifiers: CGEventFlags.maskAlternate.rawValue, label: "Option-R")
    let restored = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(settings))
    assert(restored.pickerShortcut == settings.pickerShortcut && !restored.advancedFeaturesEnabled)
    for shortcut in [CustomKeyShortcut(keyCode: 123, modifiers: standard.modifiers, label: "Arrow"),
                     CustomKeyShortcut(keyCode: 15, modifiers: 0, label: "R"),
                     CustomKeyShortcut(keyCode: 15, modifiers: CGEventFlags.maskShift.rawValue, label: "Shift-R"),
                     CustomKeyShortcut(keyCode: 127, modifiers: standard.modifiers, label: "Invalid"),
                     CustomKeyShortcut(keyCode: 15, modifiers: UInt64.max, label: "Invalid"),
                     CustomKeyShortcut(keyCode: 15, modifiers: standard.modifiers, label: "")] {
        settings.pickerShortcut = shortcut
        do { try settings.validate(); assertionFailure("Invalid picker shortcut accepted") } catch {}
    }
    print("Ruler picker settings: default Control-Option-R, explicit disabled/custom JSON, master preservation and invalid-binding guards passed.")
}

func checkPriorityRulerPipeline() throws {
    var variants: [RulerSettings] = []
    for kind in RulerKind.allCases {
        var ruler = RulerSettings(); ruler.kind = kind; ruler.enabled = true; ruler.accuracy = 1
        ruler.changesAxesAutomatically = true
        variants.append(ruler)
        switch kind {
        case .straight:
            ruler.constructionSettings.bounded = true; variants.append(ruler)
        case .parallel:
            ruler.constructionSettings.fixed = true; ruler.constructionSettings.offset = 13
            ruler.constructionSettings.tolerance = 5; variants.append(ruler)
        case .connected:
            for target in 0...2 { ruler.constructionSettings.attachment = target; ruler.constructionSettings.stopAtStart = true; variants.append(ruler) }
        case .ellipse:
            for mode in RulerEllipseMode.allCases {
                ruler.constructionSettings.sizing = mode; ruler.constructionSettings.radial = true
                ruler.constructionSettings.connect = true; ruler.constructionSettings.circle = mode == .fixed
                variants.append(ruler)
            }
        case .radial:
            for bend in [-0.5, 0.5] { ruler.radialSettings.locked = false; ruler.radialSettings.bend = bend; variants.append(ruler) }
        case .isometric, .perspective:
            if kind == .perspective { ruler.camera = RulerCamera(); ruler.camera!.enableCustomAxes(true); ruler.camera!.worldAxesSettings[0].incline = 15 }
            else { ruler.isometricAngles = [15, 150, 90] }
            for learn in [false, true] { ruler.boxSettings.enabled = true; ruler.boxSettings.learnsDimensions = learn; variants.append(ruler) }
        case .vanishing:
            ruler.matchScene(true); ruler.fixedReference = RulerPoint(x: 700, y: 600)
            ruler.familyMeasurements = Array(repeating: RulerMeasurements(visible: true, distance: 40, divisions: 4), count: 3)
            variants.append(ruler)
        case .perspectiveEllipse:
            ruler.enableDepth(true); ruler.depthSettings.offset = 50; ruler.depthSettings.scale = 0.7
            for mode in RulerEllipseMode.allCases { ruler.ellipseSizing = mode; variants.append(ruler) }
        }
    }
    for ruler in variants.flatMap({ base in [0.0, 0.5, 1.0].map { accuracy in
        var ruler = base; ruler.accuracy = accuracy; return ruler
    } }) {
        try ruler.validate()
        let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(ruler))
        assert(restored == ruler, "Priority construction settings must survive JSON round trips")
        var settings = DriverSettings(); settings.advancedFeaturesEnabled = true; settings.rulerSettings = ruler
        settings.advancedPressureCurve = EditablePressureCurve(); settings.processingSettings.enabled = true
        settings.stringSettings.enabled = true; settings.stringSettings.length = 15
        settings.speedSettings.enabled = true; settings.speedSettings.slowGain = 0.5; settings.speedSettings.fastGain = 1.5
        let output = PenOutput(); output.settings = settings
        settings.rulerSettings.enabled = false
        let baseline = PenOutput(); baseline.settings = settings
        for i in 0..<160 {
            let sample = PenSample(x: 24000 + Int(8000 * cos(Double(i) / 15)), y: 16000 + Int(6000 * sin(Double(i) / 15)),
                pressure: 300 + i * 7, tiltX: i % 60 - 30, tiltY: 20 - i % 40, inProximity: true, toolID: i < 80 ? 1 : 2, buttons: i % 4)
            let time = 1 + Double(i) / 200, control = i % 25 == 0
            let actual = output.events(for: sample, time: time, controlHeld: control)
            let expected = baseline.events(for: sample, time: time, controlHeld: control)
            assert(actual.map(\.type) == expected.map(\.type), "Ruler must preserve event lifecycle across tool changes")
            assert(output.currentSpeed == baseline.currentSpeed && output.currentSpeedGain == baseline.currentSpeedGain && output.outputPressure == baseline.outputPressure)
            for (a, b) in zip(actual, expected) {
                if ruler.accuracy == 0 { assert(a.location == b.location, "Zero accuracy must exactly bypass ruler position processing") }
                assert(a.flags == b.flags)
                for field in [CGEventField.tabletEventPointPressure, .tabletEventTiltX, .tabletEventTiltY] { assert(a.getDoubleValueField(field) == b.getDoubleValueField(field)) }
                for field in [CGEventField.tabletEventPointX, .tabletEventPointY, .tabletEventPointButtons, .tabletProximityEventPointerType] { assert(a.getIntegerValueField(field) == b.getIntegerValueField(field)) }
            }
        }
        let last = output.outputLocation
        let release = output.events(for: PenSample(), time: 2)
        assert(release.map(\.type) == [.leftMouseUp, .tabletProximity])
        assert(release[0].location == last && release[0].getDoubleValueField(.tabletEventPointPressure) == 0)
        assert(!output.isContact && output.currentSpeed == 0 && output.outputPressure == 0)
        assert(output.events(for: PenSample(), time: 2.005).isEmpty, "Lift must not produce a tail")
        output.settings.advancedFeaturesEnabled = false
        let raw = PenSample(x: 20000, y: 10000, pressure: 1000, inProximity: true, toolID: 1)
        assert(output.events(for: raw, time: 3).last!.location == output.mappedLocation(for: raw), "Master-off must bypass every ruler mode")
        settings.rulerSettings = ruler; settings.penButtons = [.shift, .rightClick]
        for cleanup in 0..<4 {
            let session = TabletSession(logging: false); session.configure(settings)
            _ = session.buttons.pen(3)
            session.output.flags = session.buttons.flags; session.output.heldMouse = session.buttons.heldMouse
            _ = session.output.events(for: raw, time: 1)
            assert(session.output.isContact && session.buttons.flags.contains(.maskShift) && session.buttons.heldMouse == .right)
            switch cleanup {
            case 0:
                var changed = settings; changed.advancedFeaturesEnabled = false
                session.configure(changed)
                assert(session.processingChangePending && session.output.settings.advancedFeaturesEnabled)
                session.resetPen()
                assert(!session.processingChangePending && !session.output.settings.advancedFeaturesEnabled)
            case 1: session.reset()
            case 2: session.setPosting(false)
            default: session.stop()
            }
            assert(!session.output.isContact && session.output.outputPressure == 0 && session.output.currentSpeed == 0)
            assert(session.buttons.flags.isEmpty && session.buttons.heldMouse == nil && session.buttons.releaseAll().isEmpty)
            let fresh = PenOutput(); fresh.settings = session.output.settings
            let actual = session.output.events(for: raw, time: 3), expected = fresh.events(for: raw, time: 3)
            assert(actual.map(\.type) == expected.map(\.type) && actual.last!.location == expected.last!.location)
            assert(session.output.outputPressure == fresh.outputPressure, "Cleanup must clear positional and pressure history")
            session.stop()
        }
    }
    print("Priority pipeline: all family variants at 0/50/100% accuracy round-trip settings and preserve event types, speed, pressure/tilt/buttons/tool changes; no-tail lift, master bypass, deferred configuration and held-modifier/mouse cleanup through reset/pause/stop passed. No events posted.")
}

func checkVanishingMeasurements() throws {
    var settings = RulerSettings(); settings.kind = .vanishing; settings.enabled = true
    settings.vanishingPoints = [RulerPoint(x: 1000, y: 0), RulerPoint(x: 0, y: 1000)]
    settings.fixedReference = RulerPoint(x: 0, y: 0)
    settings.measureSettings = RulerMeasurements(visible: true, distance: 100, divisions: 2)
    settings.familyMeasurements = [settings.measureSettings, RulerMeasurements(visible: true, distance: 40, divisions: 4)]
    try settings.validate()
    let ticks = RulerGeometry.ticks(settings, anchor: .zero, family: 0)
    for unit in [0.5, 1.0, 2.0, 5.0, -1.0, -5.0] {
        // Independent pinhole scene: world (x,z)=(n,9+n), focal length 1000.
        let expected = 1000 * unit / (9 + unit)
        assert(ticks.contains { abs($0.point.x - expected) < 1e-8 && abs($0.point.y) < 1e-8 && $0.major == (unit.rounded() == unit) })
    }
    assert(ticks.allSatisfy { $0.point.x < 1000 && $0.point.x.isFinite }, "No reflected ticks beyond the depth pole")
    let calibrated = settings.editing(.familyMeasure(0), delta: CGPoint(x: 50, y: 100))!
    assert(calibrated.measurement(for: 0).distance == 150 && calibrated.measurement(for: 1).distance == 40)
    let horizon = RulerGeometry.horizon(settings)!
    assert(abs(horizon.origin.x + horizon.origin.y - 1000) < 1e-8)
    let constrained = settings.editing(.vanishing(0), delta: CGPoint(x: 0, y: 100), snap: true)!
    assert(abs(constrained.vanishingPoints[0].x - 950) < 1e-8 && abs(constrained.vanishingPoints[0].y - 50) < 1e-8)
    let aligned = settings.editing(.vanishing(0), delta: CGPoint(x: -998, y: 3), screenSpace: true)!
    assert(aligned.vanishingPoints[0] == RulerPoint(x: 0, y: 3))
    settings.matchScene(true)
    let original = settings.sceneLines![0]
    let translated = settings.editing(.scenePoint(0, 0), delta: CGPoint(x: 25, y: -12), snap: true)!
    for i in 0..<2 { assert(translated.sceneLines![0][i] == RulerPoint(x: original[i].x + 25, y: original[i].y - 12)) }
    assert(translated.sceneLines![0][2...] == original[2...])
    let pair = [RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 20), RulerPoint(x: 0, y: 100), RulerPoint(x: 100, y: 100)]
    let horizontal = RulerGeometry.editSceneLine(pair, index: 1, delta: CGPoint(x: 0, y: -18), translate: false, align: true)!
    assert(horizontal[1] == RulerPoint(x: 100, y: 0))
    settings.sceneLines = [RulerGeometry.sceneLines(toward: SIMD3(1, 0, 0), center: .zero), RulerGeometry.sceneLines(toward: SIMD3(0, 1, 0), center: .zero)]
    assert(RulerGeometry.horizon(settings) == nil)
    let parallel = RulerGeometry.ticks(settings, anchor: .zero, family: 1)
    assert(parallel.contains { abs($0.point.y - 40) < 1e-8 && abs($0.point.x) < 1e-8 && $0.major })
    settings.measureSettings.visible = false
    assert(RulerGeometry.ticks(settings, anchor: .zero, family: 1).isEmpty)
    settings.measureSettings.visible = true
    let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
    assert(restored == settings)
    settings.sceneLines = nil; settings.familyMeasurements = nil
    assert(RulerGeometry.ticks(settings, anchor: .zero, family: 0).contains { abs($0.point.x - 200) < 1e-8 }, "Absent calibration must preserve legacy screen ticks")
    settings.familyMeasurements = [RulerMeasurements(visible: true, distance: .nan, divisions: 2)]
    do { try settings.validate(); assertionFailure("Invalid calibration accepted") } catch {}
    settings.familyMeasurements = [RulerMeasurements(visible: true, distance: 1000, divisions: 2)]
    assert(RulerGeometry.ticks(settings, anchor: .zero, family: 0).isEmpty, "Unit at VP must not reflect or explode")
    print("Vanishing measurements: independent projective-depth oracle, per-family subdivisions, infinite directions, legacy ticks, horizon constraints, pair translation/alignment, calibration isolation and JSON passed.")
}

func checkEllipseDepth() throws {
    var settings = RulerSettings(); settings.kind = .perspectiveEllipse; settings.enabled = true; settings.accuracy = 1
    let center = SIMD3(50.0, 40, 1400), a = SIMD3(200.0, 0, 100), b = SIMD3(0.0, 160, 50), direction = SIMD3(0.4, -0.7, 1.0)
    let focal = 900.0
    func project(_ p: SIMD3<Double>) -> CGPoint { CGPoint(x: 700 + focal * p.x / p.z, y: 450 + focal * p.y / p.z) }
    let corners = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    settings.corners = corners.map { let p = project(center + a * ($0.x - 0.5) + b * ($0.y - 0.5)); return RulerPoint(x: p.x, y: p.y) }
    settings.depthSettings.vanishingPoint = RulerPoint(x: 700 + focal * direction.x, y: 450 + focal * direction.y)
    settings.enableDepth(true); settings.depthSettings.offset = 75
    let worldDistance = settings.depthSettings.offset * center.z / (focal * hypot(direction.x - center.x / center.z, direction.y - center.y / center.z))
    for unit in corners + [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.75)] {
        let expected = project(center + a * (unit.x - 0.5) + b * (unit.y - 0.5) + direction * worldDistance)
        let actual = settings.sectionPoint(unit, offset: 75)!
        assert(hypot(expected.x - actual.x, expected.y - actual.y) < 1e-8, "Depth sections must match independent 3D projection")
    }
    try settings.validate()
    let start = settings.editingCenter, moved = settings.editing(.ellipseDepth, delta: CGPoint(x: 20, y: -30))!
    let expectedLine = RulerGeometry.line(CGPoint(x: start.x + 20, y: start.y - 30), origin: start,
        direction: CGPoint(x: settings.depthSettings.vanishingPoint.x - start.x, y: settings.depthSettings.vanishingPoint.y - start.y))
    // Handle uses the strongest component to preserve the cursor's progress along the axis.
    assert(hypot(moved.editingCenter.x - start.x, moved.editingCenter.y - start.y) > 1 && expectedLine.x.isFinite)
    let shift = CGPoint(x: 0.12, y: -0.08)
    let target = settings.sectionPoint(CGPoint(x: 0.5 + shift.x, y: 0.5 + shift.y), offset: 75)!
    let cylinderMoved = settings.editing(.move, delta: CGPoint(x: target.x - start.x, y: target.y - start.y))!
    assert(cylinderMoved.depthSettings.offset != 0 && cylinderMoved.depthSettings.scale == settings.depthSettings.scale)
    for unit in corners {
        let expected = project(center + a * (unit.x + shift.x - 0.5) + b * (unit.y + shift.y - 0.5) + direction * worldDistance)
        let actual = cylinderMoved.sectionPoint(unit, offset: cylinderMoved.depthSettings.offset)!
        assert(hypot(expected.x - actual.x, expected.y - actual.y) < 1e-7, "Plane movement must preserve cylinder depth and independent 3D translation")
    }
    for (handle, delta) in [(RulerHandleID.move, CGPoint(x: 15, y: -12)), (.rotate, CGPoint(x: 12, y: 4)), (.size, CGPoint(x: 15, y: 0)), (.corner(0), CGPoint(x: 3, y: -2)), (.edge(1), CGPoint(x: 4, y: 0))] {
        let edited = settings.editing(handle, delta: delta, screenSpace: handle == .move)!
        assert(edited.depthSettings.offset != 0 && edited.depthSettings.enabled && edited.depthSettings.scale == settings.depthSettings.scale)
        assert(edited.depthTangents(radius: edited.sectionRadius).count == settings.depthTangents(radius: settings.sectionRadius).count)
        try edited.validate()
    }
    for radius in [0.2, 1, 2] {
        var frameSettings = settings; frameSettings.circleRadius = radius
        let frame = RulerPlane(frameSettings.ellipseEditFrame())!
        for point in RulerGeometry.projectedCircle(frameSettings.sectionCorners, radius: frameSettings.sectionRadius)! {
            let unit = frame.unit(point)!
            assert((0...1).contains(unit.x) && (0...1).contains(unit.y), "The deformation frame must enclose the displayed circle at every radius")
        }
    }
    let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
    assert(restored == settings)
    settings.matchDepthScene(true)
    let paired = settings.depthVector!, direct = restored.depthVector!
    assert(sqrt((paired - direct).x * (paired - direct).x + (paired - direct).y * (paired - direct).y + (paired - direct).z * (paired - direct).z) < 1e-7)
    // An affine reference plane with a third direction at infinity gives parallel cylinder sides.
    settings.corners = [RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 0), RulerPoint(x: 100, y: 100), RulerPoint(x: 0, y: 100)]
    settings.depthSettings.sceneLines = RulerGeometry.sceneLines(toward: SIMD3(1, 0, 0), center: CGPoint(x: 50, y: 50))
    // A direction in the reference plane cannot define 3D depth, even at infinity.
    assert(settings.depthVector == nil)
    do { try settings.validate(); assertionFailure("In-plane depth accepted") } catch {}
    // Tilt the plane: a finite horizontal depth ray then has visible cylinder/cone tangents.
    settings.corners = [RulerPoint(x: 0, y: 0), RulerPoint(x: 120, y: 10), RulerPoint(x: 100, y: 100), RulerPoint(x: 20, y: 90)]
    settings.depthSettings.sceneLines = RulerGeometry.sceneLines(toward: SIMD3(1, 0, 0), center: CGPoint(x: 60, y: 50))
    settings.depthSettings.offset = 100
    try settings.validate()
    for scale in [0.6, 1.0, 1.4] {
        settings.depthSettings.scale = scale
        let tangents = settings.depthTangents(radius: settings.sectionRadius)
        assert(tangents.count == 2, "Visible cylinder/cone must have two tangents")
        for (base, top) in tangents {
            for (point, quad, radius) in [(base, settings.corners, settings.circleRadius), (top, settings.sectionCorners, settings.sectionRadius)] {
                let plane = RulerPlane(quad)!, unit = plane.unit(point)!
                assert(abs(hypot(unit.x - 0.5, unit.y - 0.5) - radius / 2) < 1e-7)
                let angle = atan2(unit.y - 0.5, unit.x - 0.5), epsilon = 1e-5
                let before = plane.screen(CGPoint(x: 0.5 + radius / 2 * cos(angle - epsilon), y: 0.5 + radius / 2 * sin(angle - epsilon)))!
                let after = plane.screen(CGPoint(x: 0.5 + radius / 2 * cos(angle + epsilon), y: 0.5 + radius / 2 * sin(angle + epsilon)))!
                let dx = top.x - base.x, dy = top.y - base.y, tx = after.x - before.x, ty = after.y - before.y
                assert(abs(dx * ty - dy * tx) / (hypot(dx, dy) * hypot(tx, ty)) < 1e-6, "Generator must be tangent to both projected circles")
            }
        }
    }
    var projection = RulerProjection(); projection.configure(settings)
    let curve = RulerGeometry.projectedCircle(settings.sectionCorners, radius: settings.sectionRadius)!
    let point = curve[100], output = projection.process(point, settings: settings)
    assert(hypot(output.x - point.x, output.y - point.y) < 1e-8)
    projection.reset(); settings.accuracy = 0.5
    let raw = CGPoint(x: point.x + 8, y: point.y - 6), closest = RulerGeometry.nearest(raw, on: curve)
    let blended = projection.process(raw, settings: settings)
    assert(hypot(blended.x - (raw.x + closest.x) / 2, blended.y - (raw.y + closest.y) / 2) < 1e-8)
    projection.reset(); settings.accuracy = 0
    assert(projection.process(CGPoint(x: 30, y: 80), settings: settings) == CGPoint(x: 30, y: 80))
    settings.depthSettings.sceneLines = [RulerPoint(x: 0, y: 0)]
    do { try settings.validate(); assertionFailure("Malformed depth lines accepted") } catch {}
    settings = RulerSettings(); settings.kind = .perspectiveEllipse; settings.enableDepth(true)
    settings.depthSettings.vanishingPoint = RulerPoint(x: settings.editingCenter.x, y: settings.editingCenter.y)
    settings.depthSettings.sceneLines = nil
    assert(settings.editing(.ellipseDepth, delta: CGPoint(x: 20, y: 0))?.depthSettings.offset == 20, "Axial view must still allow depth scaling")
    assert(settings.editing(.ellipseDepth, delta: CGPoint(x: 34, y: 0), snap: true)?.depthSettings.offset == 25)
    assert(settings.editing(.ellipseDepth, delta: .zero)?.depthSettings.offset == 25)
    assert(settings.editing(.ellipseDepth, delta: .zero, snap: true)?.depthSettings.offset == -25)
    settings.enableDepth(false)
    settings.corners = [RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 0), RulerPoint(x: 100, y: 100), RulerPoint(x: 0, y: 100)]
    let translated = settings.editing(.move, delta: CGPoint(x: 34, y: 18), snap: true)!
    assert(translated.corners[0] == RulerPoint(x: 25, y: 25))
    let symmetric = settings.editing(.edge(1), delta: CGPoint(x: 24, y: 0), snap: true)!
    assert(symmetric.corners[0].x == -25 && symmetric.corners[1].x == 125)
    let resized = settings.editing(.corner(2), delta: CGPoint(x: 26, y: 26), snap: true)!
    assert(hypot(resized.corners[0].x + 25, resized.corners[0].y + 25) < 1e-8 && hypot(resized.corners[2].x - 125, resized.corners[2].y - 125) < 1e-8)
    let constrained = settings.editing(.corner(0), delta: CGPoint(x: -10, y: -30), screenSpace: true)!
    let oldFrame = settings.ellipseEditFrame(), constrainedFrame = constrained.ellipseEditFrame()
    assert(hypot(constrainedFrame[0].x - oldFrame[0].x, constrainedFrame[0].y - oldFrame[0].y + 30) < 1e-8)
    var nearHorizon = RulerSettings(); nearHorizon.kind = .perspectiveEllipse; nearHorizon.circleRadius = 2.2
    nearHorizon.corners = [RulerPoint(x: 0, y: 0), RulerPoint(x: 50, y: 0), RulerPoint(x: 100 / 3, y: 100 / 3), RulerPoint(x: 0, y: 50)]
    try nearHorizon.validate()
    let finiteFrame = RulerPlane(nearHorizon.ellipseEditFrame())!
    for point in RulerGeometry.projectedCircle(nearHorizon.corners, radius: 2.2)! {
        let unit = finiteFrame.unit(point)!
        assert((0...1).contains(unit.x) && (0...1).contains(unit.y), "Near-horizon circles need a finite enclosing deformation frame")
    }
    settings.ellipsePlaneStep = .nan
    do { try settings.validate(); assertionFailure("Invalid plane step accepted") } catch {}
    print("Ellipse depth: independent 3D section oracle, finite/infinite scene matching, in-plane guards, cylinder/cone double-tangent oracle, snapping/bypass, depth-preserving plane/global edits, enclosing deformation frames, axial scaling and JSON passed.")
}

func checkCameraInclinesAndPlanes() throws {
    func length(_ v: SIMD3<Double>) -> Double { sqrt(v.x * v.x + v.y * v.y + v.z * v.z) }
    func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    var camera = RulerCamera()
    let baseline = camera.axes
    camera.enableCustomAxes(true)
    assert(zip(camera.axes, baseline).allSatisfy { length($0 - $1) < 1e-12 })
    camera.worldAxesSettings[0].incline = 15
    assert(length(camera.axes[0] - baseline[0]) > 0.1 && length(camera.axes[1] - baseline[1]) < 1e-12 && length(camera.axes[2] - baseline[2]) < 1e-12)
    let before = camera.axes
    camera.yaw += 30
    for i in 0..<3 { assert(abs(length(camera.axes[i]) - 1) < 1e-12) }
    assert(abs(dot(camera.axes[0], camera.axes[1]) - dot(before[0], before[1])) < 1e-12)
    var settings = RulerSettings(); settings.kind = .perspective; settings.camera = camera
    settings.fixedReference = RulerPoint(x: 400, y: 300)
    for plane in RulerCameraPlane.allCases {
        settings.circlePlane = plane
        let ellipse = settings.cameraEllipse()!
        try ellipse.validate()
        assert(ellipse.kind == .perspectiveEllipse && ellipse.camera == settings.camera && ellipse.circleRadius == 1)
        assert(hypot(ellipse.editingCenter.x - 400, ellipse.editingCenter.y - 300) < 1e-8)
        let pair = plane.axes, a = camera.axes[pair.0], b = camera.axes[pair.1]
        let normal = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        let origin = SIMD3(400 - settings.centerX, 300 - settings.centerY, camera.focalLength)
        let curve = RulerGeometry.projectedCircle(ellipse.corners)!
        for index in stride(from: 0, through: 512, by: 32) {
            let point = curve[index], ray = SIMD3((point.x - settings.centerX) / camera.focalLength, (point.y - settings.centerY) / camera.focalLength, 1)
            let world = ray * (dot(normal, origin) / dot(normal, ray)) - origin
            assert(abs(length(world) - settings.circleDiameter / 2) < 1e-7, "Projected helper must be a true world-plane circle even with non-orthogonal custom axes")
        }
    }
    let payload = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(RulerSettings.self, from: payload)
    assert(restored == settings)
    settings.fixedReference = nil
    settings.camera!.points = 1; settings.camera!.customAxes = nil; settings.circlePlane = .xz
    assert(settings.cameraEllipse() == nil, "Edge-on circle planes must be rejected")
    settings.camera = camera; settings.circleDiameter = 10000
    assert(settings.cameraEllipse() == nil, "Circle planes crossing the camera must be rejected")
    camera.points = 1; camera.yaw = 45; camera.pitch = 20; camera.customAxes = nil
    let onePoint = camera.axes
    camera.enableCustomAxes(true)
    assert(camera.points == 3 && zip(camera.axes, onePoint).allSatisfy { length($0 - $1) < 1e-12 }, "Enabling inclines must preserve the current base view")
    camera.worldAxesSettings[1].incline = 91
    do { try camera.validate(); assertionFailure("Invalid axis incline accepted") } catch {}
    print("Camera inclines/planes: independent 3D axes, preserved base views, shared projection, true-circle ray/plane oracle, pinned origins, edge-on/near-plane guards and JSON passed.")
}

func checkAutomaticRulerAxes() throws {
    var settings = RulerSettings()
    settings.enabled = true; settings.kind = .isometric; settings.axisAngles = [0, 90, 45]
    settings.accuracy = 1; settings.family = 1; settings.changesAxesAutomatically = true
    var projection = RulerProjection(); projection.configure(settings)
    _ = projection.process(.zero, settings: settings)
    for x in stride(from: 4.0, through: 40, by: 4) { _ = projection.process(CGPoint(x: x, y: 0), settings: settings) }
    for y in 1...20 { _ = projection.process(CGPoint(x: 40, y: y), settings: settings) }
    assert(projection.selectedFamily == 1)
    assert(projection.process(CGPoint(x: 40, y: 24), settings: settings) == CGPoint(x: 40, y: 24))
    for x in 41...64 { _ = projection.process(CGPoint(x: x, y: 24), settings: settings) }
    assert(projection.selectedFamily == 0)
    assert(projection.process(CGPoint(x: 68, y: 24), settings: settings) == CGPoint(x: 68, y: 24))
    projection.reset(); _ = projection.process(.zero, settings: settings)
    for x in 1...100 {
        _ = projection.process(CGPoint(x: Double(x), y: sin(Double(x)) * 0.4), settings: settings)
        assert(projection.selectedFamily == 0, "Small oscillations must not change axis")
    }
    let held = projection.process(CGPoint(x: 100, y: 0), settings: settings)
    for _ in 0..<20 { assert(projection.process(CGPoint(x: 100, y: 0), settings: settings) == held) }
    settings.changesAxesAutomatically = false
    projection.configure(settings); _ = projection.process(.zero, settings: settings)
    _ = projection.process(CGPoint(x: 40, y: 0), settings: settings)
    for y in 1...30 { _ = projection.process(CGPoint(x: 40, y: y), settings: settings) }
    assert(projection.selectedFamily == 0, "Default/manual mode must retain the locked axis")
    settings.changesAxesAutomatically = true; settings.axisAngles = [0, 0.5, 90]
    projection.configure(settings); _ = projection.process(.zero, settings: settings)
    for x in 1...100 { _ = projection.process(CGPoint(x: Double(x), y: Double(x) * tan(0.5 * .pi / 180)), settings: settings) }
    assert(projection.selectedFamily == 0, "Ambiguous nearly parallel movement must not chatter")
    for kind in [RulerKind.isometric, .perspective] {
        settings.kind = kind; settings.axisAngles = [0, 90, 45]; settings.camera = kind == .perspective ? RulerCamera() : nil
        settings.boxSettings.enabled = true; settings.boxSettings.learnsDimensions = true
        let origin = kind == .perspective ? settings.center : CGPoint.zero
        projection.configure(settings); _ = projection.process(origin, settings: settings)
        var last = origin
        let legs = [(SIMD3(0.0, 0, 0), SIMD3(80.0, 0, 0)), (SIMD3(80.0, 0, 0), SIMD3(80.0, 60, 0)),
                    (SIMD3(80.0, 60, 0), SIMD3(80.0, 60, 40)), (SIMD3(80.0, 60, 40), SIMD3(40.0, 60, 40))]
        for (start, end) in legs {
            for step in 1...20 {
                let world = start + (end - start) * Double(step) / 20
                last = projection.process(RulerGeometry.projectWorld(settings, anchor: origin, world: world)!, settings: settings)
            }
        }
        let extents = projection.guideSettings(settings).boxSettings.extents
        assert(zip(extents, [80.0, 60, 40]).allSatisfy { abs($0 - $1) < 1e-6 }, "Automatic learning must capture the original turn corner, not drift during acquisition")
        let expected = RulerGeometry.projectWorld(settings, anchor: origin, world: SIMD3(40, 60, 40))!
        assert(hypot(last.x - expected.x, last.y - expected.y) < 1e-6)
        projection.reset(); assert(projection.guideSettings(settings) == settings)
    }
    let roundTrip = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
    assert(roundTrip == settings)
    assert(RulerSettings().changesAxesAutomatically == false)
    print("Automatic axes: clear turns, stationary/noisy/near-parallel hysteresis, opt-in bypass, original-corner learned boxes for camera/isometric, reset and JSON passed.")
}

func checkLearnedRulerBoxes() throws {
    for kind in [RulerKind.isometric, .perspective] {
        for accuracy in [0.5, 1.0] {
            var settings = RulerSettings()
            settings.kind = kind; settings.enabled = true; settings.accuracy = accuracy; settings.family = 1
            settings.axisAngles = [0, 90, 45]; settings.camera = kind == .perspective ? RulerCamera() : nil
            settings.boxSettings.enabled = true; settings.boxSettings.learnsDimensions = true
            let origin = kind == .perspective ? settings.center : CGPoint.zero
            var projection = RulerProjection(); projection.configure(settings)
            _ = projection.process(origin, settings: settings)
            for (i, world) in [SIMD3(80.0, 0, 0), SIMD3(80, 60, 0), SIMD3(80, 60, 40)].enumerated() {
                let point = RulerGeometry.projectWorld(settings, anchor: origin, world: world)!
                let output = projection.process(point, settings: settings)
                assert(hypot(output.x - point.x, output.y - point.y) < 1e-7)
                assert(projection.cycleAxis(at: output, input: point, settings: settings))
                let stationary = projection.process(point, settings: settings)
                assert(hypot(stationary.x - output.x, stationary.y - output.y) < 1e-7, "Learning/cycling must preserve stationary output")
                assert(abs(projection.guideSettings(settings).boxSettings.extents[i] - [80.0, 60, 40][i]) < 1e-7)
            }
            let learned = projection.guideSettings(settings).boxSettings.extents
            assert(zip(learned, [80.0, 60, 40]).allSatisfy { abs($0 - $1) < 1e-7 })
            assert(settings.boxSettings.extents == [100, 100, 100], "Per-stroke learning must never overwrite saved explicit extents")
            let outside = RulerGeometry.projectWorld(settings, anchor: origin, world: SIMD3(-20, 60, 40))!
            let corner = RulerGeometry.projectWorld(settings, anchor: origin, world: SIMD3(0, 60, 40))!
            let bounded = projection.process(outside, settings: settings)
            let blended = CGPoint(x: outside.x + (corner.x - outside.x) * accuracy, y: outside.y + (corner.y - outside.y) * accuracy)
            assert(hypot(bounded.x - blended.x, bounded.y - blended.y) < 1e-7, "Completed learned box must clamp to learned dimensions")
            projection.reset()
            assert(projection.guideSettings(settings) == settings)
            _ = projection.process(origin, settings: settings)
            assert(projection.guideSettings(settings).boxSettings.extents == [100, 100, 100])
            let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
            assert(restored == settings)
            // Partial-accuracy first-axis error must not jump when captured.
            projection.reset()
            _ = projection.process(origin, settings: settings)
            let point = RulerGeometry.projectWorld(settings, anchor: origin, world: SIMD3(80, 0, 0))!
            let direction = RulerGeometry.directions(settings, anchor: origin)[0], length = hypot(direction.x, direction.y)
            let offAxis = CGPoint(x: point.x - direction.y / length * 10, y: point.y + direction.x / length * 10)
            let output = projection.process(offAxis, settings: settings)
            assert(projection.cycleAxis(at: output, input: offAxis, settings: settings))
            let stationary = projection.process(offAxis, settings: settings)
            assert(hypot(output.x - stationary.x, output.y - stationary.y) < 1e-7)
        }
    }
    let oldBox = try JSONDecoder().decode(RulerBoxSettings.self, from: Data("{\"enabled\":true,\"extents\":[100,100,100]}".utf8))
    assert(!oldBox.learnsDimensions, "Older explicit boxes must retain their behavior")
    print("Learned boxes: camera/isometric capture, partial/full continuity, learned bounds, saved-size preservation, lift/reset and legacy JSON passed.")
}

func checkRulerAxisAndReference() throws {
    var settings = RulerSettings()
    settings.enabled = true; settings.kind = .isometric; settings.axisAngles = [0, 90, 45]; settings.family = 1
    for accuracy in [0.5, 1.0] {
        settings.accuracy = accuracy
        var projection = RulerProjection(); projection.configure(settings)
        _ = projection.process(CGPoint(x: 20, y: 20), settings: settings)
        let input = CGPoint(x: 40, y: 30), delivered = projection.process(input, settings: settings)
        assert(projection.cycleAxis(at: delivered, input: input, settings: settings))
        assert(projection.selectedFamily == 1)
        let stationary = projection.process(input, settings: settings)
        assert(hypot(stationary.x - delivered.x, stationary.y - delivered.y) < 1e-8, "Axis switch must not jump at partial or full accuracy")
        let next = projection.process(CGPoint(x: 40, y: 40), settings: settings)
        assert(abs(next.x - stationary.x) < 1e-8 && abs(next.y - stationary.y - 10) < 1e-8)
        projection.reset()
        _ = projection.process(input, settings: settings)
        assert(projection.selectedFamily == 0, "Per-stroke axis changes must not replace the saved starting family")
    }
    settings.accuracy = 0
    var bypass = RulerProjection(); bypass.configure(settings)
    assert(!bypass.cycleAxis(at: .zero, input: .zero, settings: settings))
    settings.accuracy = 1; settings.axisAngles = [0, 180, 0]
    _ = bypass.process(.zero, settings: settings)
    assert(!bypass.cycleAxis(at: .zero, input: .zero, settings: settings), "Cycling must not select a duplicate parallel family")
    settings.axisAngles = [0, 90, 45]
    let origin = CGPoint(x: 100, y: 200)
    let pinned = settings.editing(.reference, delta: .zero, referenceOrigin: origin)!
    assert(pinned.fixedReference?.cg == origin)
    let moved = pinned.editing(.reference, delta: CGPoint(x: 20, y: -30))!
    assert(moved.fixedReference?.cg == CGPoint(x: 120, y: 170))
    assert(moved.editing(.reference, delta: .zero)!.fixedReference == nil)
    let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(moved))
    assert(restored == moved)
    var invalid = moved; invalid.fixedReference = RulerPoint(x: .nan, y: 0)
    do { try invalid.validate(); assertionFailure("Invalid fixed reference accepted") } catch {}
    let output = PenOutput()
    var driver = DriverSettings(); driver.advancedFeaturesEnabled = true; driver.ruler = settings
    output.settings = driver
    var sample = PenSample(); sample.inProximity = true; sample.pressure = 1000; sample.x = 4000; sample.y = 5000
    _ = output.events(for: sample, time: 1)
    sample.x += 500; sample.y += 200
    _ = output.events(for: sample, time: 1.01)
    let before = output.outputLocation, pressure = output.outputPressure
    let changed = output.events(for: sample, time: 1.02, controlHeld: true)
    assert(hypot(output.outputLocation.x - before.x, output.outputLocation.y - before.y) < 1e-8)
    assert(changed.count == 1 && changed[0].type == .leftMouseDragged && output.outputPressure == pressure)
    let family = output.rulerGuideFamily
    _ = output.events(for: sample, time: 1.03, controlHeld: true)
    assert(output.rulerGuideFamily == family, "Holding Control must not repeatedly cycle")
    _ = output.events(for: sample, time: 1.04)
    _ = output.events(for: sample, time: 1.05, controlHeld: true)
    assert(output.rulerGuideFamily != family)
    sample.pressure = 0
    let release = output.events(for: sample, time: 1.06, controlHeld: true).first { $0.type == .leftMouseUp }!
    assert(!output.isContact && release.getDoubleValueField(.tabletEventPointPressure) == 0 && !output.cycleRulerAxis())
    print("Ruler axis/reference: continuous partial/full-accuracy changes, one change per Control press, saved family retention, degenerate/bypass guards, pin/move/unpin, validation/JSON and immediate lift passed.")
}

func checkRulerBoxes() throws {
    var settings = RulerSettings()
    settings.kind = .isometric; settings.axisAngles = [0, 90, 45]; settings.boxSettings.enabled = true
    settings.enabled = true; settings.accuracy = 1
    let vertices = RulerGeometry.boxVertices(settings, anchor: .zero)!
    assert(vertices.count == 8 && RulerGeometry.boxEdges.count == 12 && vertices[1] == CGPoint(x: 100, y: 0))
    assert(abs(vertices[2].x) < 1e-9 && vertices[2].y == 100)
    var projection = RulerProjection(); projection.configure(settings)
    assert(projection.process(.zero, settings: settings) == .zero)
    _ = projection.process(CGPoint(x: 10, y: 0), settings: settings)
    assert(projection.process(CGPoint(x: 15, y: 0), settings: settings) == CGPoint(x: 15, y: 0))
    assert(projection.process(CGPoint(x: 50, y: 50), settings: settings) == CGPoint(x: 50, y: 0), "Active edge must not jump across projected intersections")
    assert(projection.process(CGPoint(x: 120, y: 0), settings: settings) == CGPoint(x: 100, y: 0), "Box corner must stop overshoot")
    _ = projection.process(CGPoint(x: 100, y: 10), settings: settings)
    let alongY = projection.process(CGPoint(x: 100, y: 15), settings: settings)
    assert(hypot(alongY.x - 100, alongY.y - 15) < 1e-8 && projection.selectedFamily == 1)
    let corner = projection.process(CGPoint(x: 100, y: 120), settings: settings)
    assert(hypot(corner.x - 100, corner.y - 100) < 1e-8)
    projection.reset()
    let next = CGPoint(x: 300, y: 300)
    assert(projection.process(next, settings: settings) == next)
    settings.family = 1
    for accuracy in [0.0, 0.5, 1.0] {
        settings.accuracy = accuracy
        projection.configure(settings)
        _ = projection.process(.zero, settings: settings)
        let result = projection.process(CGPoint(x: 120, y: 0), settings: settings)
        assert(abs(result.x - (120 - 20 * accuracy)) < 1e-8 && result.y == 0)
    }
    settings.kind = .perspective; settings.camera = RulerCamera(); settings.accuracy = 1
    let cameraVertices = RulerGeometry.boxVertices(settings, anchor: settings.center)!
    for edge in RulerGeometry.boxEdges {
        let a = cameraVertices[edge.from], b = cameraVertices[edge.to]
        let direction = settings.camera!.directions(center: settings.center, anchor: a)[edge.family]
        assert(abs((b.x - a.x) * direction.y - (b.y - a.y) * direction.x) < 1e-7, "Box edges and camera guides must share vanishing directions")
    }
    let handle = settings.editHandles.first { $0.id == .boxSize(0) }!.point
    let edited = settings.editing(.boxSize(0), delta: CGPoint(x: (handle.x - settings.centerX) * 0.1, y: (handle.y - settings.centerY) * 0.1))!
    assert(edited.boxSettings.extents[0] > 100 && edited.boxSettings.extents[1] == 100)
    settings.camera!.viewRadius = 20; settings.boxSettings.extents = [-10000, 10000, 10000]
    assert(RulerGeometry.boxVertices(settings, anchor: settings.center) == nil)
    projection.configure(settings)
    _ = projection.process(settings.center, settings: settings)
    let raw = CGPoint(x: settings.centerX + 20, y: settings.centerY + 30)
    assert(projection.process(raw, settings: settings) == raw, "Near-plane crossing must bypass invalid box geometry")
    settings.boxSettings.extents = [100, 100, 100]
    let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
    assert(restored == settings)
    settings.boxSettings.extents = [0, 100, 100]
    do { try settings.validate(); assertionFailure("Collapsed box accepted") } catch {}
    print("Ruler boxes: shared camera/isometric geometry, bounded edges/corners, incident-edge changes, no branch jumps, accuracy, reset, on-canvas sizing, near-plane bypass and JSON passed.")
}

func checkRadialAndIsometric() throws {
    var settings = RulerSettings()
    assert(settings.radialSettings.locked && settings.radialSettings.bend == 0 && settings.axisAngles == nil)
    settings.kind = .radial; settings.centerX = 0; settings.centerY = 0; settings.enabled = true
    settings.radialSettings.locked = false; settings.radialSettings.bend = 0.3
    let direction = RulerGeometry.direction(14.3)
    let start = RulerGeometry.radialPoint(center: .zero, direction: direction, bend: 0.3, parameter: 500)
    let inferred = RulerGeometry.directions(settings, anchor: start)[0]
    assert(hypot(inferred.x - direction.x, inferred.y - direction.y) < 1e-10, "Free curved ray must pass through its hovering start")
    for bend in [-2.0, -0.3, 0.3, 2.0, 1e-9] {
        for input in [CGPoint(x: -400, y: 300), CGPoint(x: 900, y: 900), CGPoint(x: 0, y: 1000)] {
            let nearest = RulerGeometry.nearestRadial(input, center: .zero, direction: CGPoint(x: 1, y: 0), bend: bend, previous: nil)
            assert(nearest.parameter >= 0 && nearest.point.x.isFinite && nearest.point.y.isFinite)
            assert(abs(nearest.point.y - bend * nearest.point.x * nearest.point.x / 1000) < 1e-6)
            let sampled = (0...10000).map { RulerGeometry.radialPoint(center: .zero, direction: CGPoint(x: 1, y: 0), bend: bend, parameter: Double($0) * 0.3) }
                .map { hypot($0.x - input.x, $0.y - input.y) }.min()!
            assert(hypot(nearest.point.x - input.x, nearest.point.y - input.y) <= sampled + 1e-6, "Analytic projection must be at least as close as a dense independent sample")
        }
    }
    settings.radialSettings.bend = 0.5
    let first = CGPoint(x: 100, y: 5), input = CGPoint(x: 200, y: 100)
    let projected = RulerGeometry.nearestRadial(input, center: .zero, direction: CGPoint(x: 1, y: 0), bend: 0.5, previous: 100).point
    for accuracy in [0.0, 0.5, 1.0] {
        settings.accuracy = accuracy
        var projection = RulerProjection(); projection.configure(settings)
        _ = projection.process(first, settings: settings)
        let result = projection.process(input, settings: settings)
        assert(hypot(result.x - (input.x + (projected.x - input.x) * accuracy), result.y - (input.y + (projected.y - input.y) * accuracy)) < 1e-7)
        projection.reset()
        assert(projection.selected == nil)
    }
    settings.accuracy = 1
    var centerStart = RulerProjection(); centerStart.configure(settings)
    assert(centerStart.process(.zero, settings: settings) == .zero && centerStart.selected == nil)
    _ = centerStart.process(CGPoint(x: 0, y: 50), settings: settings)
    assert(centerStart.selected != nil, "Center start must acquire from outward movement rather than arbitrary center angle")
    settings.radialSettings.bend = 0
    settings.radialSettings.locked = true; settings.spacing = 30
    let locked = RulerGeometry.directions(settings, anchor: CGPoint(x: 100, y: 2))[0]
    assert(locked == CGPoint(x: 1, y: 0))
    let straight = RulerGeometry.nearestRadial(CGPoint(x: -100, y: 50), center: .zero, direction: locked, bend: 0, previous: nil)
    assert(straight.point == CGPoint(x: -100, y: 0), "Legacy straight lines extend through the center")
    settings.radialSettings.bend = .infinity
    do { try settings.validate(); assertionFailure("Non-finite bend accepted") } catch {}
    settings.radialSettings.bend = 0.3
    settings.kind = .isometric
    settings.useIsometricPreset(1)
    assert(abs(tan(settings.angle * .pi / 180) - 0.5) < 1e-10 && settings.axisAngles == nil)
    settings.useIsometricPreset(2)
    assert(settings.isometricAngles == [15, 150, 90])
    let before = settings.isometricAngles
    let edited = settings.editing(.isometricAxis(1), delta: CGPoint(x: 20, y: 30))!
    assert(edited.isometricAngles[0] == before[0] && edited.isometricAngles[2] == before[2] && edited.isometricAngles[1] != before[1])
    settings.orientation = 30
    assert(hypot(RulerGeometry.directions(settings, anchor: .zero)[0].x - cos(.pi / 4), RulerGeometry.directions(settings, anchor: .zero)[0].y - sin(.pi / 4)) < 1e-10)
    let restored = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
    assert(restored == settings)
    settings.axisAngles = [0, 90]
    do { try settings.validate(); assertionFailure("Invalid axis count accepted") } catch {}
    print("Radial/isometric: free/locked curved rays, analytic nearest-point oracle, center/lift, accuracy, legacy straight lines, independent axes/presets, invalid values and JSON passed.")
}

func checkRulerConstructions() throws {
    var colored = RulerSettings()
    let custom = RulerGuideColor(red: 0.12, green: 0.34, blue: 0.56)
    assert(colored.guideColor(at: 0) == nil)
    colored.setGuideColor(custom, at: 2)
    try colored.validate()
    let restoredColors = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(colored))
    assert(restoredColors == colored && restoredColors.guideColor(at: 2) == custom)
    colored.kind = .isometric
    assert(colored.guideColor(at: 2) == nil, "Overrides belong to their ruler")
    colored.setGuideColor(custom, at: 0)
    colored.resetGuideColors()
    colored.kind = .radial
    assert(colored.guideColor(at: 2) == custom, "Reset must preserve other ruler palettes")
    colored.setGuideColor(nil, at: 2)
    assert(colored.guideColors == nil, "Reset restores absent/default palette")
    colored.setGuideColor(RulerGuideColor(red: 2, green: 0, blue: 0), at: 0)
    do { try colored.validate(); assertionFailure("Invalid color accepted") } catch {}
    colored.guideColors = ["unknown": [custom]]
    do { try colored.validate(); assertionFailure("Unknown palette accepted") } catch {}

    func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 1e-7) -> Bool { hypot(a.x - b.x, a.y - b.y) < tolerance }
    var camera = RulerCamera()
    for points in 1...3 {
        camera.points = points
        try camera.validate()
        let axes = camera.axes
        for i in 0..<3 {
            assert(abs(axes[i].x * axes[i].x + axes[i].y * axes[i].y + axes[i].z * axes[i].z - 1) < 1e-10)
            for j in 0..<i { assert(abs(axes[i].x * axes[j].x + axes[i].y * axes[j].y + axes[i].z * axes[j].z) < 1e-10) }
        }
        let directions = camera.directions(center: CGPoint(x: 700, y: 450), anchor: CGPoint(x: 850, y: 600))
        assert(directions.count == 3 && directions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        if points == 1 { assert(abs(directions[0].y) < 1e-10 && abs(directions[1].x) < 1e-10) }
        if points == 2 { assert(abs(directions[1].x) < 1e-10) }
    }
    var settings = RulerSettings()
    settings.kind = .perspective; settings.camera = camera; settings.enabled = true; settings.family = 1
    let anchor = CGPoint(x: 900, y: 700), input = CGPoint(x: 1100, y: 740)
    let expected = RulerGeometry.line(input, origin: anchor, direction: RulerGeometry.directions(settings, anchor: anchor)[0])
    for accuracy in [0.0, 0.5, 1.0] {
        settings.accuracy = accuracy
        var projection = RulerProjection(); projection.configure(settings)
        _ = projection.process(anchor, settings: settings)
        let result = projection.process(input, settings: settings)
        assert(near(result, CGPoint(x: input.x + (expected.x - input.x) * accuracy, y: input.y + (expected.y - input.y) * accuracy)))
        if accuracy > 0 { assert(projection.selected == RulerGeometry.directions(settings, anchor: anchor)[0]) }
    }
    settings.measureSettings.visible = true
    let ticks = RulerGeometry.ticks(settings, anchor: settings.center, family: 0).filter { $0.point.x > settings.centerX }
    assert(ticks.count > 2)
    assert(hypot(ticks[2].point.x - ticks[1].point.x, ticks[2].point.y - ticks[1].point.y) < hypot(ticks[1].point.x - ticks[0].point.x, ticks[1].point.y - ticks[0].point.y), "Equal world steps compress toward the vanishing point")
    settings.measureSettings.divisions = 10
    assert(RulerGeometry.ticks(settings, anchor: anchor, family: 2).count <= 400)
    let movedCamera = settings.editing(.move, delta: CGPoint(x: -50, y: 20))!
    assert(movedCamera.centerX == settings.centerX - 50 && movedCamera.vanishingPoints == settings.vanishingPoints)
    assert(settings.editing(.viewTilt, delta: CGPoint(x: 0, y: 60))!.camera!.pitch == camera.pitch + 20)
    assert(settings.editing(.fieldOfView, delta: CGPoint(x: 40, y: 0))!.camera!.fieldOfView == camera.fieldOfView + 10)
    var badCamera = camera; badCamera.fieldOfView = .nan
    do { try badCamera.validate(); assertionFailure() } catch {}
    let legacy = try JSONDecoder().decode(RulerSettings.self, from: Data("{\"enabled\":true,\"visible\":true,\"kind\":\"perspective\",\"accuracy\":1,\"opacity\":0.25,\"centerX\":700,\"centerY\":450,\"angle\":30,\"spacing\":15,\"vanishingPoints\":[{\"x\":100,\"y\":400}],\"corners\":[{\"x\":0,\"y\":0},{\"x\":100,\"y\":0},{\"x\":100,\"y\":100},{\"x\":0,\"y\":100}]}".utf8))
    assert(legacy.camera == nil && legacy.ellipseSizing == .fixed && !legacy.measureSettings.visible)
    let restoredConstruction = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(settings))
    assert(restoredConstruction == settings)
    settings.kind = .vanishing; settings.camera = nil; settings.family = 1
    settings.vanishingPoints = [RulerPoint(x: 1000, y: 400)]
    settings.matchScene(true)
    try settings.validate()
    let sceneDirection = RulerGeometry.directions(settings, anchor: .zero)[0]
    assert(abs(sceneDirection.y / sceneDirection.x - 0.4) < 1e-8)
    settings.sceneLines = [[RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 10), RulerPoint(x: 0, y: 50), RulerPoint(x: 100, y: 60)]]
    try settings.validate()
    let scenePayload = try JSONEncoder().encode(settings)
    let restoredScene = try JSONDecoder().decode(RulerSettings.self, from: scenePayload)
    assert(restoredScene == settings)
    let infinity = RulerGeometry.sceneVanishingPoint(settings.sceneLines![0])!
    assert(infinity.z == 0 && abs(infinity.y / infinity.x - 0.1) < 1e-8)
    settings.accuracy = 1
    var infiniteProjection = RulerProjection(); infiniteProjection.configure(settings)
    _ = infiniteProjection.process(CGPoint(x: 800, y: 600), settings: settings)
    assert(near(infiniteProjection.process(CGPoint(x: 900, y: 600), settings: settings), RulerGeometry.line(CGPoint(x: 900, y: 600), origin: CGPoint(x: 800, y: 600), direction: CGPoint(x: 1, y: 0.1))))
    settings.sceneLines![0][1] = settings.sceneLines![0][0]
    do { try settings.validate(); assertionFailure("Collapsed scene line accepted") } catch {}
    settings.sceneLines = nil
    settings.kind = .perspectiveEllipse
    settings.corners = [RulerPoint(x: 100, y: 100), RulerPoint(x: 400, y: 150), RulerPoint(x: 350, y: 400), RulerPoint(x: 150, y: 350)]
    let plane = RulerPlane(settings.corners)!
    for unit in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.7)] {
        assert(near(plane.unit(plane.screen(unit)!)!, unit))
    }
    let center = plane.screen(CGPoint(x: 0.5, y: 0.5))!
    assert(near(center, settings.editingCenter))
    let moved = settings.editing(.move, delta: CGPoint(x: 20, y: 15))!
    assert(near(moved.editingCenter, CGPoint(x: center.x + 20, y: center.y + 15)))
    let inverse = moved.corners.compactMap { plane.unit($0.cg) }
    assert(inverse.count == 4 && abs(inverse[1].x - inverse[0].x - 1) < 1e-7 && abs(inverse[3].y - inverse[0].y - 1) < 1e-7, "Plane move preserves dimensions in world plane")
    let free = settings.editing(.move, delta: CGPoint(x: 20, y: 15), screenSpace: true)!
    assert(free.corners[0].x == 120 && free.corners[0].y == 115)
    let edge = settings.editing(.edge(0), delta: CGPoint(x: 0, y: -10))!
    let topLeft = plane.unit(edge.corners[0].cg)!, topRight = plane.unit(edge.corners[1].cg)!
    assert(abs(topLeft.y - topRight.y) < 1e-7, "Edge slides preserve the plane's vanishing points")
    settings.ellipseSizing = .concentric
    let through = plane.screen(CGPoint(x: 0.75, y: 0.5))!
    assert(abs(RulerGeometry.ellipseRadius(settings, through: through) - 0.5) < 1e-7)
    settings.accuracy = 1
    var projection = RulerProjection(); projection.configure(settings)
    assert(near(projection.process(through, settings: settings), through))
    let outside = plane.screen(CGPoint(x: 0.5, y: 0.9))!
    let onLockedCircle = RulerGeometry.nearest(outside, on: RulerGeometry.projectedCircle(settings.corners, radius: 0.5)!)
    assert(near(projection.process(outside, settings: settings), onLockedCircle, 0.02), "Concentric size locks for a stroke")
    projection.reset()
    let nextStart = plane.screen(CGPoint(x: 0.9, y: 0.5))!
    assert(near(projection.process(nextStart, settings: settings), nextStart, 0.02))
    for accuracy in [0.0, 0.5, 1.0] {
        settings.ellipseSizing = .fixed; settings.circleRadius = 0.5; settings.accuracy = accuracy
        var fixed = RulerProjection(); fixed.configure(settings)
        let result = fixed.process(outside, settings: settings)
        assert(near(result, CGPoint(x: outside.x + (onLockedCircle.x - outside.x) * accuracy, y: outside.y + (onLockedCircle.y - outside.y) * accuracy), 0.02))
    }
    settings.circleRadius = 1
    settings.ellipseSizing = .stepped
    settings.circleStep = 0.25
    assert(abs(RulerGeometry.ellipseRadius(settings, through: plane.screen(CGPoint(x: 0.82, y: 0.5))!) - 0.75) < 1e-7)
    assert(settings.editing(.corner(0), delta: CGPoint(x: 200, y: 200)) == nil)
    print("Ruler constructions: camera orthogonality/1–3 point/infinite axes, accuracy, ticks, editing, legacy JSON, projective plane round trip, plane edits and concentric stroke locks passed.")
}

func checkNewRulerConstructions() throws {
    func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 0.03) -> Bool { hypot(a.x - b.x, a.y - b.y) < tolerance }
    var r = RulerSettings(); r.enabled = true; r.accuracy = 1; r.kind = .straight
    r.constructionSettings.start = RulerPoint(x: 0, y: 0)
    r.constructionSettings.end = RulerPoint(x: 100, y: 0)
    for bounded in [false, true] {
        r.constructionSettings.bounded = bounded
        for accuracy in [0.0, 0.5, 1.0] {
            r.accuracy = accuracy
            var p = RulerProjection(); p.configure(r)
            let result = p.process(CGPoint(x: 150, y: 20), settings: r)
            assert(near(result, CGPoint(x: 150 + ((bounded ? 100 : 150) - 150) * accuracy, y: 20 * (1 - accuracy))))
        }
    }
    r.accuracy = 1
    assert(r.editing(.corner(1), delta: CGPoint(x: -100, y: 0)) == nil)
    r.kind = .parallel; r.angle = 0; r.centerX = 0; r.centerY = 0
    r.constructionSettings.fixed = true; r.constructionSettings.spacing = 50; r.constructionSettings.offset = 10
    r.constructionSettings.tolerance = 3
    var p = RulerProjection(); p.configure(r)
    assert(near(p.process(CGPoint(x: 1, y: 38), settings: r), CGPoint(x: 0, y: 60)))
    assert(near(p.process(CGPoint(x: 48, y: -100), settings: r), CGPoint(x: 50, y: 60)), "Parallel branch retains pen-down offset")
    p.finishStroke(settings: r)
    assert(near(p.process(CGPoint(x: 20, y: -43), settings: r), CGPoint(x: 20, y: -40)))
    r.constructionSettings.fixed = false; r.constructionSettings.tolerance = 0
    p.configure(r)
    _ = p.process(CGPoint(x: 10, y: 23), settings: r)
    assert(near(p.process(CGPoint(x: 40, y: 80), settings: r), CGPoint(x: 40, y: 23)))
    r.kind = .connected; r.constructionSettings.angleStep = 90
    p.configure(r)
    _ = p.process(.zero, settings: r)
    assert(near(p.process(CGPoint(x: 100, y: 4), settings: r), CGPoint(x: 100, y: 0)))
    p.finishStroke(settings: r)
    assert(near(p.process(CGPoint(x: 105, y: 2), settings: r), CGPoint(x: 100, y: 0)))
    assert(near(p.process(CGPoint(x: 102, y: 100), settings: r), CGPoint(x: 100, y: 98)))
    p.finishStroke(settings: r)
    r.constructionSettings.attachment = 1
    assert(near(p.process(CGPoint(x: 100, y: 50), settings: r), CGPoint(x: 100, y: 49)))
    p.reset()
    assert(near(p.process(CGPoint(x: 7, y: 8), settings: r), CGPoint(x: 7, y: 8)), "Reset discards chain")
    r.kind = .ellipse; r.angle = 37; r.centerX = 20; r.centerY = -40
    r.constructionSettings.radiusX = 300; r.constructionSettings.radiusY = 0.1
    let d = RulerGeometry.direction(r.angle)
    let input = CGPoint(x: r.centerX + 320 * d.x, y: r.centerY + 320 * d.y)
    let expected = CGPoint(x: r.centerX + 300 * d.x, y: r.centerY + 300 * d.y)
    for accuracy in [0.0, 0.5, 1.0] {
        r.accuracy = accuracy; p.configure(r)
        assert(near(p.process(input, settings: r), CGPoint(x: input.x + (expected.x - input.x) * accuracy, y: input.y + (expected.y - input.y) * accuracy)))
    }
    r.accuracy = 1; r.angle = 0; r.centerX = 0; r.centerY = 0
    r.constructionSettings.radiusX = 100; r.constructionSettings.radiusY = 50
    r.constructionSettings.sizing = .concentric
    p.configure(r)
    assert(near(p.process(CGPoint(x: 200, y: 0), settings: r), CGPoint(x: 200, y: 0)))
    assert(near(p.process(CGPoint(x: 0, y: 70), settings: r), CGPoint(x: 0, y: 100), 0.15))
    assert(p.guideSettings(r).constructionSettings.radiusX == 200)
    p.finishStroke(settings: r)
    assert(near(p.process(CGPoint(x: 100, y: 0), settings: r), CGPoint(x: 100, y: 0)))
    r.constructionSettings.sizing = .fixed; r.constructionSettings.radial = true
    p.configure(r); _ = p.process(.zero, settings: r)
    assert(near(p.process(CGPoint(x: 20, y: 20), settings: r), CGPoint(x: 20, y: 20)))
    assert(near(p.process(CGPoint(x: 40, y: 0), settings: r), CGPoint(x: 20, y: 20)))
    r.constructionSettings.radial = false; r.constructionSettings.connect = true
    p.configure(r)
    let first = p.process(CGPoint(x: 100, y: 0), settings: r)
    _ = p.process(CGPoint(x: 0, y: 50), settings: r)
    assert(p.process(CGPoint(x: 100, y: 0.5), settings: r) == first, "Endpoint capture closes the traced loop")
    r.accuracy = 0.5; p.configure(r)
    let partialStart = p.process(CGPoint(x: 110, y: 0), settings: r)
    assert(near(partialStart, CGPoint(x: 100, y: 0)))
    _ = p.process(CGPoint(x: 0, y: 60), settings: r)
    assert(p.process(CGPoint(x: 110, y: 0.5), settings: r) == partialStart, "Connection captures both endpoints at partial accuracy")
    r.accuracy = 1
    p.configure(r)
    _ = p.process(CGPoint(x: 0, y: 60), settings: r)
    assert(near(p.process(.zero, settings: r), CGPoint(x: 0, y: 50), 0.15), "Ambiguous ellipse branches retain the previous side")
    assert(p.process(CGPoint(x: 0, y: -0.001), settings: r).y > 0, "Center noise must not flip the ellipse branch")
    for accuracy in [0.5, 1.0] {
        var settings = DriverSettings(); settings.advancedFeaturesEnabled = true
        settings.rulerSettings.enabled = true; settings.rulerSettings.accuracy = accuracy
        settings.rulerSettings.kind = .connected
        let output = PenOutput(); output.settings = settings
        let a = PenSample(x: 10000, y: 10000, pressure: 1000, inProximity: true, toolID: 1)
        var b = a; b.x = 20000
        _ = output.events(for: a, time: 1); _ = output.events(for: b, time: 1.01)
        let end = output.outputLocation
        var hover = b; hover.pressure = 0
        assert(output.events(for: hover, time: 1.02).first?.type == .leftMouseUp)
        var next = b; next.x = 30000; next.y = 20000
        let attached = output.events(for: next, time: 1.03)
        assert(attached.last?.type == .leftMouseDown && near(attached.last!.location, end), "Real stroke boundaries attach at the delivered endpoint")
        _ = output.events(for: PenSample(), time: 1.04)
        assert(near(output.events(for: next, time: 1.05).last!.location, output.mappedLocation(for: next)), "Disconnect clears chain without synthetic contact")
        next.toolID = 2
        assert(near(output.events(for: next, time: 1.06).last!.location, output.mappedLocation(for: next)), "Tool switch clears chain")
    }
    for kind in [RulerKind.straight, .parallel, .connected, .ellipse] {
        r.kind = kind; try r.validate()
        let decoded = try JSONDecoder().decode(RulerSettings.self, from: JSONEncoder().encode(r))
        assert(decoded == r)
        for handle in r.editHandles { assert(r.editing(handle.id, delta: .zero) != nil) }
    }
    for bad in [0.0, -1, Double.infinity, Double.nan] {
        var invalid = r; invalid.constructionSettings.radiusX = bad
        do { try invalid.validate(); assertionFailure("Invalid radius accepted") } catch {}
    }
    print("New rulers: bounded/extended blend, collapsed endpoints, fixed/anchored parallel branches and magnetic ticks, retained chain attachments/reset, rotated thin ellipse, stroke-locked rings, radial snapping, handles and JSON passed.")
}

func checkRulerStartAcquisition() {
    var mapping = DriverSettings(); mapping.preserveAspect = false
    let bounds = CGRect(x: -3440, y: 0, width: 3440, height: 1440)
    func mapped(_ dx: Int, _ dy: Int) -> CGPoint {
        mapping.location(x: 10000 + dx, y: 10000 + dy, bounds: bounds, tabletSize: SupportedTablet.medium.penSize)
    }
    let origin = mapped(0, 0)
    let trace = [(1, 1), (-1, 2), (3, 1), (8, 3), (16, -2), (32, 2), (64, -1), (96, 1), (144, 0), (200, 0), (240, 0)]
    for kind in [RulerKind.isometric, .perspective, .vanishing] {
        for accuracy in [0.0, 0.5, 1.0] {
            var settings = RulerSettings(); settings.enabled = true; settings.kind = kind; settings.accuracy = accuracy
            settings.isometricAngles = [0, 90, 45]
            settings.vanishingPoints = [RulerPoint(x: origin.x + 10000, y: origin.y), RulerPoint(x: origin.x, y: origin.y + 10000)]
            var projection = RulerProjection(); projection.configure(settings)
            assert(projection.process(origin, settings: settings) == origin)
            for (dx, dy) in trace {
                let input = mapped(dx, dy), output = projection.process(input, settings: settings)
                if accuracy == 0 { assert(output == input, "Zero accuracy must retain exact bypass") }
                else if projection.selectedFamily == nil {
                    let expected = CGPoint(x: input.x + (origin.x - input.x) * accuracy, y: input.y + (origin.y - input.y) * accuracy)
                    assert(hypot(output.x - expected.x, output.y - expected.y) < 1e-8, "Unacquired ruler motion must blend toward the stroke origin, not leak raw startup wiggles")
                } else {
                    assert(projection.selectedFamily == 0)
                    assert(abs(output.y - (input.y + (origin.y - input.y) * accuracy)) < 1e-8)
                }
            }
            if accuracy > 0 { assert(projection.selectedFamily == 0, "Clear mapped movement must still acquire the intended axis") }
            projection.finishStroke(settings: settings)
            assert(projection.anchor == nil && projection.selectedFamily == nil)
        }
    }
    print("Ruler starts: noisy Medium-tablet/wide-display acquisition stays at the origin at full accuracy, blends at partial accuracy, bypasses exactly at zero, then locks and clears on lift for all ordinary axis families.")
}

func checkRulers() throws {
    checkRulerStartAcquisition()
    try checkNewRulerConstructions()
    try checkRulerPickerShortcut()
    try checkPriorityRulerPipeline()
    try checkVanishingMeasurements()
    try checkEllipseDepth()
    try checkCameraInclinesAndPlanes()
    try checkAutomaticRulerAxes()
    try checkLearnedRulerBoxes()
    try checkRulerAxisAndReference()
    try checkRulerBoxes()
    try checkRadialAndIsometric()
    try checkRulerConstructions()
    var editable = RulerSettings()
    editable.kind = .perspectiveEllipse
    editable.corners = [RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 0), RulerPoint(x: 100, y: 100), RulerPoint(x: 0, y: 100)]
    let shifted = editable.editing(.move, delta: CGPoint(x: 20, y: -10))!
    assert(hypot(shifted.corners[0].x - 20, shifted.corners[0].y + 10) < 1e-7 && hypot(shifted.corners[2].x - 120, shifted.corners[2].y - 90) < 1e-7)
    assert(shifted.vanishingPoints == editable.vanishingPoints, "Editing must not move unrelated family geometry")
    let edge = editable.editing(.edge(0), delta: CGPoint(x: 0, y: -20))!
    assert(abs(edge.corners[0].y + 20) < 1e-7 && abs(edge.corners[1].y + 20) < 1e-7 && edge.corners[2].y == 100)
    assert(editable.editing(.corner(0), delta: CGPoint(x: 150, y: 150)) == nil, "Crossed preview must be rejected")
    assert(editable.editing(.corner(9), delta: .zero) == nil)
    assert(editable.editing(.move, delta: CGPoint(x: Double.nan, y: 0)) == nil)
    let pivot = editable.editingCenter
    let rotateHandle = editable.editHandles.first { $0.id == .rotate }!.point
    let radius = pivot.y - rotateHandle.y
    let rotated = editable.editing(.rotate, delta: CGPoint(x: radius, y: radius))!
    assert(abs(rotated.corners[0].x - 100) < 1e-8 && abs(rotated.corners[0].y) < 1e-8)
    let sizeHandle = editable.editHandles.first { $0.id == .size }!.point
    let enlarged = editable.editing(.size, delta: CGPoint(x: sizeHandle.x - pivot.x, y: 0))!
    assert(enlarged.corners[0] == RulerPoint(x: -50, y: -50))
    editable.kind = .isometric
    let turned = editable.editing(.rotate, delta: CGPoint(x: 80, y: 80))!
    assert(abs(turned.orientation - 90) < 1e-8)
    assert(abs(RulerGeometry.directions(turned, anchor: .zero)[0].x - cos(120 * Double.pi / 180)) < 1e-8)
    var close = RulerSettings()
    close.enabled = true; close.accuracy = 1; close.kind = .perspective
    close.vanishingPoints = [RulerPoint(x: 1000, y: 0), RulerPoint(x: 1000, y: 176), RulerPoint(x: 0, y: 1000)]
    var closeProjection = RulerProjection(); closeProjection.configure(close)
    _ = closeProjection.process(.zero, settings: close)
    _ = closeProjection.process(CGPoint(x: 2.1, y: 0), settings: close)
    let intended = CGPoint(x: 20, y: 3.52)
    let acquired = closeProjection.process(intended, settings: close)
    assert(acquired == .zero && closeProjection.selectedFamily == nil, "Initial wobble must neither lock a nearby family nor ink an unselected path")
    let confirmed = closeProjection.process(CGPoint(x: 24, y: 4.224), settings: close)
    assert(closeProjection.selectedFamily == 1 && hypot(confirmed.x - 24, confirmed.y - 4.224) < 0.01)
    closeProjection.reset()
    close.family = 2
    _ = closeProjection.process(.zero, settings: close)
    let manual = closeProjection.process(CGPoint(x: 2, y: 0), settings: close)
    assert(abs(manual.y / manual.x - 0.176) < 1e-9, "Manual family must bypass acquisition ambiguity")
    close.family = 0
    close.vanishingPoints = [RulerPoint(x: 0, y: 0), RulerPoint(x: 1000, y: 0)]
    closeProjection.reset()
    _ = closeProjection.process(.zero, settings: close)
    _ = closeProjection.process(CGPoint(x: 12, y: 1), settings: close)
    assert(closeProjection.process(CGPoint(x: 20, y: 1), settings: close).y == 0, "Coincident vanishing point must not shadow a valid direction")
    var config = RulerSettings()
    try config.validate()
    let circle = RulerGeometry.projectedCircle([RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 0), RulerPoint(x: 100, y: 100), RulerPoint(x: 0, y: 100)])!
    assert(circle.count == 513)
    for p in circle { assert(abs(hypot(p.x - 50, p.y - 50) - 50) < 1e-9) }
    assert(RulerGeometry.projectedCircle([RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 100), RulerPoint(x: 100, y: 0), RulerPoint(x: 0, y: 100)]) == nil)
    config.enabled = true; config.kind = .isometric; config.angle = 0; config.accuracy = 1
    var projection = RulerProjection(); projection.configure(config)
    assert(projection.process(.zero, settings: config) == .zero)
    // A single first report must not lock the wrong axis after touch-down wobble.
    assert(projection.process(CGPoint(x: 8, y: 0), settings: config) == .zero && projection.selectedFamily == nil)
    _ = projection.process(CGPoint(x: 1, y: 10), settings: config)
    assert(projection.process(CGPoint(x: 1, y: 15), settings: config).x < 1e-8)
    projection.reset()
    _ = projection.process(.zero, settings: config)
    _ = projection.process(CGPoint(x: 8, y: 1), settings: config)
    assert(projection.process(CGPoint(x: 13, y: 1), settings: config) == CGPoint(x: 13, y: 0))
    // Axis stays locked even when a later point is closer to another family.
    assert(projection.process(CGPoint(x: 11, y: 40), settings: config) == CGPoint(x: 11, y: 0))
    config.accuracy = 0.5
    assert(projection.process(CGPoint(x: 12, y: 8), settings: config) == CGPoint(x: 12, y: 4))
    config.accuracy = 0
    assert(projection.process(CGPoint(x: 12, y: 8), settings: config) == CGPoint(x: 12, y: 8))
    var settings = DriverSettings(); settings.ruler = config
    let restored = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(settings))
    assert(restored == settings)
    config.spacing = 0
    do { try config.validate(); assertionFailure("Invalid ruler spacing accepted") } catch { }
    let output = PenOutput()
    settings.advancedFeaturesEnabled = true
    settings.rulerSettings = RulerSettings()
    settings.rulerSettings.enabled = true; settings.rulerSettings.accuracy = 1
    output.settings = settings
    var sample = PenSample(); sample.inProximity = true; sample.pressure = 1000
    _ = output.events(for: sample, time: 1)
    sample.x = 1000; sample.y = 2000
    _ = output.events(for: sample, time: 1.01)
    let last = output.outputLocation
    sample.pressure = 0
    let release = output.events(for: sample, time: 1.02).first { $0.type == .leftMouseUp }
    assert(release?.location == last && release?.getDoubleValueField(.tabletEventPointPressure) == 0)
    assert(!output.isContact)

}

func checkDrawingPresets() throws {
    func profileBytes(_ store: PressureProfileStore, _ id: UUID) -> Data { try! Data(contentsOf: store.directory.appendingPathComponent(id.uuidString + ".json")) }
    let root = URL.temporaryDirectory.appendingPathComponent("waccom-presets-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PressureProfileStore(directory: root.appendingPathComponent("profiles"))
    var source = DriverSettings()
    source.advancedFeaturesEnabled = true; source.stringSettings.enabled = true; source.stringSettings.length = 75
    source.processingSettings.enabled = true; source.processingSettings.mode = .fixed; source.processingSettings.fixedValue = 0.7
    source.advancedPressureCurve = EditablePressureCurve(); source.rulerSettings.enabled = true; source.rulerSettings.kind = .ellipse
    source.rulerSettings.centerX = -800; source.rulerSettings.centerY = 300; source.speedSettings.enabled = true
    let oldDisplay = PresetDisplay(uuid: UUID().uuidString, bounds: CGRect(x: -1600, y: 0, width: 1600, height: 1000))
    let newDisplay = PresetDisplay(uuid: UUID().uuidString, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800))
    var profiles: [PressureProfile] = []
    for scope in DrawingPresetScope.allCases {
        let profile = PressureProfile.capture(name: scope.title, scope: scope, settings: source, display: oldDisplay)
        try profile.validate(); assert(profile.matches(source))
        try store.save(profile)
        let restored = try PressureProfileStore.read(store.directory.appendingPathComponent(profile.id.uuidString + ".json"))
        assert(restored == profile && restored.scope == scope)
        var target = DriverSettings(); target.tabletButtons[1] = .shift; target.usesDedicatedInputThread = false
        let before = target
        restored.apply(to: &target)
        assert(!target.advancedFeaturesEnabled && target.tabletButtons == before.tabletButtons && target.usesDedicatedInputThread == before.usesDedicatedInputThread)
        assert(target.pressureProfileID == profile.id)
        if scope.includes(.position) { assert(target.stringSettings == source.stringSettings) } else { assert(target.pulledString == before.pulledString) }
        if scope.includes(.pressure) { assert(target.processingSettings == source.processingSettings) } else { assert(target.pressureProcessing == before.pressureProcessing) }
        if scope.includes(.ruler) { assert(target.ruler == source.ruler) } else { assert(target.ruler == before.ruler) }
        if scope.includes(.speed) { assert(target.pressureSpeed == source.pressureSpeed) } else { assert(target.pressureSpeed == before.pressureSpeed) }
        if scope.includes(.curve) || scope == .basic { assert(target.advancedPressureCurve == source.advancedPressureCurve) } else { assert(target.advancedPressureCurve == before.advancedPressureCurve) }
        if scope == .all { assert(target.sensitivity == source.sensitivity && target.contactThreshold == source.contactThreshold) }
        else if scope != .basic { assert(target.sensitivity == before.sensitivity && target.contactThreshold == before.contactThreshold) }
        profiles.append(profile)
    }
    source.sensitivity = 0.8; source.contactThreshold = 100; source.pressureSmoothing = 25
    source.pressureCurve = PressureCurve(light: 0.3, medium: 0.6, firm: 0.9)
    let full = PressureProfile.capture(name: "Everything", settings: source)
    assert(full.scope == .all && full.matches(source))
    try store.save(full)
    let fullReloaded = try PressureProfileStore.read(store.directory.appendingPathComponent(full.id.uuidString + ".json"))
    assert(fullReloaded == full)
    var fullTarget = DriverSettings(); fullReloaded.apply(to: &fullTarget)
    assert(fullTarget.sensitivity == 0.8 && fullTarget.contactThreshold == 100 && fullTarget.pressureCurve == source.pressureCurve && fullTarget.pressureSmoothing == 25)
    assert(fullTarget.stringSettings == source.stringSettings && fullTarget.processingSettings == source.processingSettings && fullTarget.ruler == source.ruler && fullTarget.speedSettings == source.speedSettings && fullTarget.advancedPressureCurve == source.advancedPressureCurve)
    assert(!fullTarget.advancedFeaturesEnabled)
    fullTarget.sensitivity = 0.2; assert(!full.matches(fullTarget))
    let implicit = PressureProfile.capture(name: "Defaults", scope: .combined, settings: DriverSettings())
    assert(implicit.matches(DriverSettings()), "Implicit settings defaults are not modified values")
    let combined = profiles.first { $0.scope == .combined }!
    let (mapped, changed) = try combined.drawing!.remapped(to: [newDisplay])
    assert(changed && mapped.display == newDisplay && mapped.ruler!.editingCenter == CGPoint(x: 600, y: 400))
    assert(mapped.ruler!.constructionSettings.radiusX == source.rulerSettings.constructionSettings.radiusX)
    var perspective = source; perspective.rulerSettings.kind = .perspectiveEllipse
    perspective.rulerSettings.enableDepth(true); perspective.rulerSettings.depthSettings.offset = 30
    perspective.rulerSettings.fixedReference = RulerPoint(x: 500, y: 400)
    let (depth, _) = try DrawingPreset(scope: .ruler, settings: perspective, display: oldDisplay).remapped(to: [newDisplay])
    let dx = depth.ruler!.corners[0].x - perspective.rulerSettings.corners[0].x
    assert(depth.ruler!.depthSettings.offset == 30 && depth.ruler!.fixedReference!.x == 500 + dx)
    assert(PressureProfile.next(in: profiles.reversed(), after: nil) == PressureProfile.sorted(profiles).first)
    let settingsURL = root.appendingPathComponent("settings.json")
    var backup = source; backup.pressureProfiles = profiles
    try SettingsFile.write(backup, to: settingsURL)
    let roundTrip = try SettingsFile.read(settingsURL)
    assert(roundTrip == backup)
    let original = try Data(contentsOf: store.directory.appendingPathComponent(combined.id.uuidString + ".json"))
    var invalid = combined; invalid.version = 999
    do { try store.save(invalid); assertionFailure("Unknown version accepted") } catch {}
    assert(profileBytes(store, combined.id) == original)
    var mismatch = combined; mismatch.drawing!.scope = .curve
    do { try mismatch.validate(); assertionFailure("Out-of-scope payload accepted") } catch {}
    let oversized = root.appendingPathComponent("oversized.json")
    try Data(repeating: 32, count: 1_048_577).write(to: oversized)
    do { _ = try PressureProfileStore.read(oversized); assertionFailure("Oversized JSON accepted") } catch {}
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: settingsURL)
    do { _ = try SettingsFile.read(link); assertionFailure("Symlink accepted") } catch {}
    // Force a failure after the first profile write, then compare exact old bytes.
    let blocker = root.appendingPathComponent("not-a-directory")
    try Data([1]).write(to: blocker)
    var changedProfile = combined; changedProfile.name = "Changed"
    do { try store.save([changedProfile], settings: source, to: blocker.appendingPathComponent("settings.json")); assertionFailure("Filesystem failure expected") } catch {}
    assert(profileBytes(store, combined.id) == original)
    let created = PressureProfile.capture(name: "Rollback new file", scope: .speed, settings: source)
    do { try store.save([created], settings: source, to: blocker.appendingPathComponent("settings.json")); assertionFailure("Filesystem failure expected") } catch {}
    assert(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(created.id.uuidString + ".json").path))
    let session = TabletSession(logging: false)
    var active = DriverSettings(); active.advancedFeaturesEnabled = true
    active.tabletButtons[1] = .shift; active.tabletButtons[2] = .rightClick; active.penButtons[0] = .rightClick
    session.configure(active)
    _ = session.buttons.pad(6); _ = session.buttons.pen(1)
    let sample = PenSample(x: 12000, y: 12000, pressure: 1000, inProximity: true, toolID: 1)
    _ = session.output.events(for: sample, time: 1)
    session.applyPressureProfile(combined)
    assert(session.processingChangePending && session.output.settings.pulledString == active.pulledString)
    session.resetPen()
    assert(!session.processingChangePending && session.output.settings.stringSettings == source.stringSettings)
    assert(session.buttons.flags.contains(.maskShift) && session.buttons.heldMouse == .right, "Preset activation must preserve held pad modifiers and mouse buttons through lift")
    assert(session.buttons.pad(0).map(\.type) == [.rightMouseUp, .flagsChanged])
    var buttons = DriverSettings(); buttons.tabletButtons[1] = .cycleAdvancedProfile
    buttons.penButtons[0] = .selectDrawingProfile; buttons.profileBindings = ["pen.0": combined.id]
    try buttons.validate()
    let mapper = ButtonMapper(); mapper.configure(buttons)
    var actions: [UUID?] = []; mapper.onDrawingProfile = { actions.append($0) }
    _ = mapper.pen(1); assert(actions.isEmpty); _ = mapper.releaseAll(); mapper.posting = true
    _ = mapper.pen(1); _ = mapper.pen(1); _ = mapper.pad(2); _ = mapper.pad(2)
    assert(actions.count == 2 && actions[0] == combined.id && actions[1] == nil)
    _ = mapper.releaseAll(); assert(actions.count == 2)
    print("Drawing presets: all scopes/legacy JSON, isolation/master preservation, restart/backup round trips, display/depth remap, deterministic cycling, invalid/oversized/symlink rejection, exact-file rollback, mid-stroke activation and held-button lifecycle passed. No events posted.")
}

func checkSettingsAndButtons() throws {
    try checkDrawingPresets()
    var delivery = PenDeliveryTiming()
    for i in 0..<513 { delivery.record(arrival: Double(i) / 120, finished: Double(i) / 120 + 0.0001, inProximity: true, posted: 1) }
    delivery.recordMainLoopTick(0)
    delivery.recordMainLoopTick(0.08)
    delivery.recordDiscoveryDuration(0.003)
    assert(delivery.summary.contains("nominal 50): 80.000"))
    assert(delivery.summary.contains("discovery max duration ms: 3.000"))
    assert(delivery.reports == 513 && delivery.postedEvents == 513)
    assert(delivery.summary.contains("120.000 reports/s"))
    assert(delivery.summary.contains("latest window: 512 intervals"))
    delivery.record(arrival: 10, finished: 10, inProximity: false, posted: 0)
    delivery.record(arrival: 20, finished: 20, inProximity: true, posted: 1)
    assert(delivery.summary.contains("max 8.333"), "Proximity gaps must not count as delivery stalls")
    try checkRulers()
    try checkPressureSpeed()
    try checkPulledString()
    try checkEditablePressureCurve()
    try checkAdvancedPressure()
    var custom = DriverSettings()
    custom.penButtons = [.customKey, .customKey]
    custom.tabletButtons[1] = .customKey
    let eyedropper = CustomKeyShortcut(keyCode: 34, modifiers: 0, label: "I")
    custom[shortcut: "pen.0"] = eyedropper
    custom[shortcut: "pen.1"] = CustomKeyShortcut(keyCode: 11, modifiers: CGEventFlags.maskCommand.rawValue, label: "⌘B")
    custom[shortcut: "tablet.1"] = eyedropper
    try custom.validate()
    let roundTrip = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(custom))
    assert(roundTrip == custom)
    let customMapper = ButtonMapper()
    customMapper.configure(custom)
    let keyDown = customMapper.pen(1)
    assert(keyDown.count == 1 && keyDown[0].type == .keyDown && keyDown[0].getIntegerValueField(.keyboardEventKeycode) == 34)
    assert(customMapper.pen(1).isEmpty)
    assert(customMapper.pad(2).isEmpty, "Same shortcut across buttons stays held")
    assert(customMapper.pen(0).isEmpty)
    let keyUp = customMapper.pad(0)
    assert(keyUp.count == 1 && keyUp[0].type == .keyUp)
    let combination = customMapper.pen(2)
    assert(combination.count == 1 && combination[0].flags.contains(.maskCommand))
    assert(customMapper.releaseAll().first?.type == .keyUp)
    custom[shortcut: "pen.0"] = nil
    do { try custom.validate(); assertionFailure("Missing custom shortcut accepted") } catch { }
    custom[shortcut: "pen.0"] = CustomKeyShortcut(keyCode: 200, modifiers: 0, label: "Invalid")
    do { try custom.validate(); assertionFailure("Invalid key code accepted") } catch { }
    var curved = DriverSettings()
    curved.pressureCurve = PressureCurve(light: 0.1, medium: 0.7, firm: 0.9)
    try curved.validate()
    assert(abs(curved.pressure(1024) - 0.7) < 0.001)
    assert(curved.pressure(-1) == 0 && curved.pressure(4095) == 1)
    for raw in 1...2047 { assert(curved.pressure(raw) >= curved.pressure(raw - 1)) }
    let curveData = try JSONEncoder().encode(curved)
    let curveRestored = try JSONDecoder().decode(DriverSettings.self, from: curveData)
    assert(curveRestored == curved)
    let curveProfile = PressureProfile(name: "Detailed", sensitivity: 0.5, contactThreshold: 10, pressureCurve: curved.pressureCurve)
    let restoredCurveProfile = try JSONDecoder().decode(PressureProfile.self, from: JSONEncoder().encode(curveProfile))
    var appliedCurve = DriverSettings()
    restoredCurveProfile.apply(to: &appliedCurve)
    assert(appliedCurve.pressureCurve == curved.pressureCurve)
    PressureProfile(name: "Legacy", sensitivity: 0.5, contactThreshold: 10).apply(to: &appliedCurve)
    assert(appliedCurve.pressureCurve == nil)
    let legacyProfileData = Data(#"{"name":"Old","version":1,"id":"11111111-1111-1111-1111-111111111111","sensitivity":0.5,"contactThreshold":10}"#.utf8)
    let legacyCurveProfile = try JSONDecoder().decode(PressureProfile.self, from: legacyProfileData)
    assert(legacyCurveProfile.pressureCurve == nil)
    curved.pressureCurve = PressureCurve(light: 0.8, medium: 0.2, firm: 0.9)
    do { try curved.validate(); assertionFailure("Decreasing pressure curve accepted") } catch { }
    curved.pressureCurve = PressureCurve(light: .nan)
    do { try curved.validate(); assertionFailure("Nonfinite pressure curve accepted") } catch { }
    let smoothOutput = PenOutput()
    smoothOutput.settings.smoothingMilliseconds = 12
    var smoothSample = PenSample(pressure: 256, inProximity: true, toolID: 1)
    func outputPressure(_ events: [CGEvent]) -> Double { events.last!.getDoubleValueField(.tabletEventPointPressure) }
    let initialPressure = outputPressure(smoothOutput.events(for: smoothSample, time: 1))
    smoothSample.pressure = 1536
    let softened = outputPressure(smoothOutput.events(for: smoothSample, time: 1.005))
    assert(softened > initialPressure && softened < smoothOutput.settings.pressure(1536))
    let converging = outputPressure(smoothOutput.events(for: smoothSample, time: 1.010))
    assert(converging > softened)
    smoothSample.pressure = 0
    let lifted = smoothOutput.events(for: smoothSample, time: 1.011)
    assert(lifted.allSatisfy { $0.getDoubleValueField(.tabletEventPointPressure) == 0 })
    smoothSample.pressure = 256
    assert(abs(outputPressure(smoothOutput.events(for: smoothSample, time: 1.015)) - initialPressure) < 0.000001)
    smoothOutput.settings.smoothingMilliseconds = 0
    smoothSample.pressure = 1536
    assert(abs(outputPressure(smoothOutput.events(for: smoothSample, time: 1.020)) - smoothOutput.settings.pressure(1536)) < 0.0001)
    var invalidSmoothing = DriverSettings(); invalidSmoothing.smoothingMilliseconds = .nan
    do { try invalidSmoothing.validate(); assertionFailure("Nonfinite smoothing accepted") } catch { }
    // Every constant-pressure circle sample must survive delivery, at full mapped precision.
    let motionOutput = PenOutput()
    motionOutput.flags = .maskShift
    for index in 0..<240 {
        let angle = Double(index) * 2 * .pi / 240
        let sample = PenSample(x: 32000 + Int(8000 * cos(angle)), y: 20000 + Int(8000 * sin(angle)), pressure: 1024, inProximity: true, toolID: 1)
        let events = motionOutput.events(for: sample, time: 2 + Double(index) / 200)
        let point = events.last!
        assert(point.type == (index == 0 ? .leftMouseDown : .leftMouseDragged))
        assert(point.flags.contains([.maskNonCoalesced, .maskShift]))
        let expected = motionOutput.mappedLocation(for: sample)
        assert(abs(point.location.x - expected.x) < 0.00001 && abs(point.location.y - expected.y) < 0.00001)
        assert(point.getIntegerValueField(.tabletEventPointX) == sample.x)
        assert(point.getIntegerValueField(.tabletEventPointY) == sample.y)
    }
    assert(motionOutput.events(for: PenSample(), time: 4).map(\.type) == [.leftMouseUp, .tabletProximity])
    let mediumOutput = PenOutput()
    mediumOutput.tablet = .medium
    var mediumSettings = DriverSettings()
    let testBounds = CGRect(x: -100, y: 50, width: 1001, height: 801)
    assert(mediumSettings.location(x: 44704, y: 27940, bounds: testBounds, tabletSize: SupportedTablet.medium.penSize) == CGPoint(x: 900, y: 850))
    assert(mediumSettings.location(x: 22352, y: 13970, bounds: testBounds, tabletSize: SupportedTablet.medium.penSize) == CGPoint(x: 400, y: 450))
    mediumSettings.rotate180 = true
    assert(mediumSettings.location(x: 44704, y: 27940, bounds: testBounds, tabletSize: SupportedTablet.medium.penSize) == CGPoint(x: -100, y: 50))
    mediumSettings.preserveAspect = true
    let mediumArea = mediumSettings.activeArea(in: testBounds, tabletSize: SupportedTablet.medium.penSize)
    assert(abs(mediumArea.width * 44704 / (mediumArea.height * 27940) - testBounds.width / testBounds.height) < 0.000001)
    let mediumEvents = mediumOutput.events(for: PenSample(x: 44704, y: 27940, pressure: 1024, inProximity: true, toolID: 1))
    assert(mediumEvents.first?.getIntegerValueField(.tabletProximityEventTabletID) == 0x0315)
    assert(mediumEvents.last?.location == mediumOutput.mappedLocation(for: PenSample(x: 44704, y: 27940)))
    let noBatteryReading = TabletPowerStatus.fromBatteryByte(0, moduleInstalled: true)
    assert(noBatteryReading.showsUSBPower(usbConnected: true))
    assert(!noBatteryReading.showsUSBPower(usbConnected: false))
    assert(noBatteryReading.chargingDescription == "Not reported")
    assert(TabletPowerStatus.fromBatteryByte(0, moduleInstalled: false).showsUSBPower(usbConnected: true))
    assert(!TabletPowerStatus.fromBatteryByte(0x80, moduleInstalled: true).showsUSBPower(usbConnected: true), "A charging battery at 0% must still show charging")
    assert(!TabletPowerStatus.fromBatteryByte(29, moduleInstalled: true).showsUSBPower(usbConnected: true), "Known battery state must remain visible")
    let directory = URL.temporaryDirectory.appendingPathComponent("waccom-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    var settings = DriverSettings()
    try SettingsFile.write(settings, to: url)
    let restored = try SettingsFile.read(url)
    assert(restored == settings)
    let original = try Data(contentsOf: url)
    settings.areaWidth = 0
    do { try SettingsFile.write(settings, to: url); assertionFailure("Invalid area accepted") }
    catch { }
    let afterInvalidWrite = try Data(contentsOf: url)
    assert(afterInvalidWrite == original, "Invalid write must preserve saved data")
    settings = DriverSettings()
    settings.version = 2
    do { try settings.validate(); assertionFailure("Future version accepted") } catch { }
    let invalidURL = directory.appendingPathComponent("invalid.json")
    let encoder = JSONEncoder()
    try encoder.encode(settings).write(to: invalidURL)
    do { _ = try SettingsFile.read(invalidURL); assertionFailure("Invalid import accepted") } catch { }
    let afterImport = try Data(contentsOf: url)
    assert(afterImport == original)
    settings = DriverSettings()
    settings.penButtons = [.none]
    do { try settings.validate(); assertionFailure("Bad button count accepted") } catch { }
    settings = DriverSettings()
    settings.sensitivity = .nan
    do { try settings.validate(); assertionFailure("NaN accepted") } catch { }
    settings = DriverSettings()
    let bounds = CGRect(x: -1000, y: 100, width: 1000, height: 800)
    assert(settings.location(x: 0, y: 0, bounds: bounds) == CGPoint(x: -1000, y: 100))
    assert(settings.location(x: 65024, y: 40640, bounds: bounds) == CGPoint(x: -1, y: 899))
    settings.rotate180 = true
    assert(settings.location(x: 0, y: 0, bounds: bounds) == CGPoint(x: -1, y: 899))
    settings.rotate180 = false; settings.preserveAspect = true
    assert(settings.location(x: 32512, y: 20320, bounds: bounds) == CGPoint(x: -500.5, y: 499.5))
    settings.preserveAspect = false
    let linear = settings.pressure(1024)
    settings.sensitivity = 1; assert(settings.pressure(1024) > linear)
    settings.sensitivity = 0; assert(settings.pressure(1024) < linear)
    assert(settings.pressure(-100) == 0 && settings.pressure(5000) == 1)
    let pad = PadSample.decode([3, 0, 0x85, 1, 0x81, 0xff, 0, 0, 0, 0])!
    assert(pad.buttons == 0x103 && pad.ring == 5)
    assert(PadSample.decode([3, 0, 0, 0, 0, 0xff, 0, 0, 0, 0])?.buttons == 0, "Capacitive contact is not a press")
    assert(PadSample.decode(Array(repeating: 0, count: 64)) == nil)
    let mapper = ButtonMapper()
    settings = DriverSettings()
    settings.penButtons = [.rightClick, .rightClick]
    settings.tabletButtons[1] = .space
    mapper.configure(settings)
    assert(mapper.pen(1).map(\.type) == [.rightMouseDown])
    assert(mapper.pen(3).isEmpty)
    assert(mapper.pen(2).isEmpty, "Shared mapping must stay down until every source releases")
    assert(mapper.pen(0).map(\.type) == [.rightMouseUp])
    assert(mapper.pad(2).map(\.type) == [.keyDown])
    assert(mapper.pad(2).isEmpty, "Repeated reports must not repeat actions")
    assert(mapper.releaseAll().map(\.type) == [.keyUp])
    settings.penButtons = [.shift, .undo]
    mapper.configure(settings)
    assert(mapper.pen(1).first?.flags.contains(.maskShift) == true)
    assert(mapper.pen(3).map(\.type) == [.keyDown, .keyUp])
    assert(mapper.releaseAll().map(\.type) == [.flagsChanged])
    assert(mapper.flags.isEmpty)
    // Touch toggle is a driver action, not a synthetic key, and fires once per press.
    settings = DriverSettings()
    settings.penButtons[0] = .toggleTouch
    settings.tabletButtons[1] = .toggleTouch
    mapper.configure(settings)
    var toggles = 0
    mapper.onToggleTouch = { toggles += 1 }
    assert(mapper.pen(1).isEmpty && toggles == 0, "Paused input must not toggle touch")
    _ = mapper.releaseAll()
    mapper.posting = true
    assert(mapper.pen(1).isEmpty && toggles == 1)
    assert(mapper.pen(1).isEmpty && toggles == 1, "Held reports must not toggle repeatedly")
    assert(mapper.pad(2).isEmpty && toggles == 1, "Shared actions remain held across sources")
    _ = mapper.pen(0); _ = mapper.pad(0)
    assert(mapper.pad(2).isEmpty && toggles == 2)
    _ = mapper.releaseAll()
    mapper.posting = false
    try SettingsFile.write(settings, to: url)
    let toggleSettings = try SettingsFile.read(url)
    assert(toggleSettings.penButtons[0] == .toggleTouch)
    let toggleSession = TabletSession(logging: false)
    toggleSession.configure(settings)
    toggleSession.buttons.posting = true // Only the non-event toggle action is assigned.
    var enabledStates: [Bool] = []
    toggleSession.onTouchEnabledChanged = { enabledStates.append($0) }
    _ = toggleSession.buttons.pad(2)
    assert(toggleSession.touch.settings.enabled)
    _ = toggleSession.buttons.pad(2)
    _ = toggleSession.buttons.pad(0)
    _ = toggleSession.buttons.pad(2)
    assert(!toggleSession.touch.settings.enabled && enabledStates == [true, false])
    for (level, icon) in [(0, "10"), (10, "10"), (11, "20"), (20, "20"), (21, "50"), (50, "50"), (51, "80"), (80, "80"), (81, "full"), (100, "full")] {
        assert(TabletPowerStatus(wirelessModuleInstalled: true, batteryPercent: level, charging: false).batteryIcon == "battery-status-" + icon)
    }
    assert(TabletPowerStatus(wirelessModuleInstalled: true, batteryPercent: 100, charging: true).batteryIcon == "battery-status-charging")
    assert(TabletPowerStatus(wirelessModuleInstalled: true, batteryPercent: nil, charging: nil).batteryIcon == "battery-status-10-1")
    assert(TabletPowerStatus(wirelessModuleInstalled: false, batteryPercent: nil, charging: nil).batteryIcon == nil)
    // Profiles are independent local JSON files and survive settings backups.
    let profiles = PressureProfileStore(directory: directory.appendingPathComponent("profiles"))
    let firm = PressureProfile(name: "Firm", sensitivity: 0.2, contactThreshold: 120)
    let soft = PressureProfile(name: "Soft", sensitivity: 0.8, contactThreshold: 20)
    let emptyProfiles = try profiles.load()
    assert(emptyProfiles.isEmpty)
    try profiles.save(soft); try profiles.save(firm)
    let listedProfiles = try profiles.load()
    assert(listedProfiles.map(\.name) == ["Firm", "Soft"])
    assert(PressureProfile.next(in: [], after: nil) == nil)
    assert(PressureProfile.next(in: listedProfiles, after: nil) == firm)
    assert(PressureProfile.next(in: listedProfiles, after: firm.id) == soft)
    assert(PressureProfile.next(in: listedProfiles, after: soft.id) == firm)
    assert(PressureProfile.next(in: listedProfiles, after: UUID()) == firm)
    var profileSettings = DriverSettings()
    firm.apply(to: &profileSettings)
    assert(profileSettings.sensitivity == 0.2 && profileSettings.contactThreshold == 120 && profileSettings.pressureProfileID == firm.id)
    profileSettings.pressureProfiles = listedProfiles
    try SettingsFile.write(profileSettings, to: url)
    let profileBackup = try SettingsFile.read(url)
    assert(profileBackup.pressureProfiles == listedProfiles)
    var broken = firm; broken.sensitivity = .nan
    do { try profiles.save(broken); assertionFailure("Invalid profile accepted") } catch { }
    let preservedProfiles = try profiles.load()
    assert(preservedProfiles == listedProfiles, "Invalid saves must preserve profile files")
    profileSettings.pressureProfiles = [firm, firm]
    do { try profileSettings.validate(); assertionFailure("Duplicate imported profile IDs accepted") } catch { }
    mapper.configure(DriverSettings())
    var cycles = 0
    mapper.onCyclePressureProfile = { cycles += 1 }
    settings = DriverSettings(); settings.tabletButtons[1] = .cyclePressureProfile
    mapper.configure(settings)
    assert(mapper.pad(2).isEmpty && cycles == 0)
    _ = mapper.releaseAll(); mapper.posting = true
    assert(mapper.pad(2).isEmpty && cycles == 1)
    assert(mapper.pad(2).isEmpty && cycles == 1)
    _ = mapper.pad(0)
    assert(mapper.pad(2).isEmpty && cycles == 2)
    _ = mapper.releaseAll(); mapper.posting = false
    let profileSession = TabletSession(logging: false)
    profileSession.configure(settings)
    profileSession.applyPressureProfile(soft)
    assert(profileSession.output.settings.sensitivity == soft.sensitivity && profileSession.output.contactThreshold == soft.contactThreshold)
    // Ring positions and wraparound are taken from the captured physical device.
    settings = DriverSettings()
    mapper.configure(settings)
    func keyDowns(_ events: [CGEvent]) -> [Int64] {
        events.filter { $0.type == .keyDown }.map { $0.getIntegerValueField(.keyboardEventKeycode) }
    }
    assert(mapper.ring(70).isEmpty)
    let clockwise = mapper.ring(1)
    assert(clockwise.map(\.type) == [.keyDown, .keyUp] && keyDowns(clockwise) == [30])
    assert(mapper.ring(71).isEmpty)
    assert(keyDowns(mapper.ring(70)) == [33])
    assert(mapper.ring(nil).isEmpty)
    assert(mapper.ring(40).isEmpty, "Finger lift must discard the old position")
    assert(mapper.ring(40).isEmpty, "Stationary reports must not repeat a shortcut")
    mapper.releaseAll()
    assert(mapper.ring(10).isEmpty, "Pause/disconnect cleanup must reset ring state")
    settings.ringSettings.reversed = true
    mapper.configure(settings)
    _ = mapper.ring(10)
    assert(keyDowns(mapper.ring(13)) == [33])
    settings.ringSettings.enabled = false
    mapper.configure(settings)
    assert(mapper.ring(10).isEmpty && mapper.ring(40).isEmpty)
    settings.ringSettings.enabled = true
    settings.ringSettings.reversed = false
    settings.ringSettings.stepsPerShortcut = 1
    mapper.configure(settings)
    _ = mapper.ring(0)
    assert(mapper.ring(36).isEmpty, "Half-turn jumps have no reliable direction")
    assert(mapper.ring(127).isEmpty)
    assert(mapper.ring(0).isEmpty)
    assert(keyDowns(mapper.ring(3)) == [30, 30, 30])
    settings.ringSettings.stepsPerShortcut = 0
    do { try settings.validate(); assertionFailure("Invalid ring response accepted") } catch { }
    let legacy = try JSONDecoder().decode(DriverSettings.self, from: original)
    assert(legacy.touchRing == nil && legacy.ringSettings == RingSettings(), "Existing backups must keep loading")
    settings = DriverSettings()
    settings.ringSettings.reversed = true
    settings.ringSettings.stepsPerShortcut = 5
    try SettingsFile.write(settings, to: url)
    let restoredRing = try SettingsFile.read(url)
    assert(restoredRing == settings)
    // Captured 8-byte contact messages inside the 64-byte surface report.
    func touchPacket(_ message: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 2; bytes[1] = 1
        bytes.replaceSubrange(2..<10, with: message)
        return bytes
    }
    var surface = TouchDecoder()
    let firstContact = touchPacket([2, 0xC0, 0x9A, 0xD1, 0xA9, 3, 3, 0])
    assert(surface.decode(firstContact) == [TouchContact(id: 2, x: 2474, y: 3353)])
    assert(surface.decode(touchPacket([3, 0x90, 0x9B, 0xCE, 0xA2, 3, 2, 0]))?.count == 2)
    assert(surface.decode(touchPacket([129, 0, 0, 0, 0, 0, 0, 0])) == nil)
    assert(surface.contacts.count == 2, "Status messages must not erase active contacts")
    assert(surface.decode(touchPacket([2, 0x20, 0, 0, 0, 0, 0, 0]))?.count == 1)
    assert(surface.decode(Array(firstContact.prefix(63))) == nil)
    assert(surface.decode(touchPacket([3, 0x20, 0, 0, 0, 0, 0, 0]))?.isEmpty == true)
    let touch = TouchOutput()
    touch.controlled = true
    var touchSettings = TouchSettings()
    touchSettings.enabled = true
    touch.configure(touchSettings)
    let finger = TouchContact(id: 2, x: 100, y: 100)
    let moved = TouchContact(id: 2, x: 140, y: 100)
    let cursor = CGPoint(x: 500, y: 500)
    assert(touch.events(for: [finger], now: 10, cursor: cursor).isEmpty)
    let motion = touch.events(for: [moved], now: 10.1, cursor: cursor)
    assert(motion.map(\.type) == [.mouseMoved] && motion[0].location.x == 560)
    assert(touch.events(for: [], now: 10.2, cursor: cursor).isEmpty, "A swipe must not become a tap")
    _ = touch.events(for: [finger], now: 11, cursor: cursor)
    assert(touch.events(for: [], now: 11.1, cursor: cursor).map(\.type) == [.leftMouseDown, .leftMouseUp])
    let second = TouchContact(id: 3, x: 200, y: 100)
    _ = touch.events(for: [finger, second], now: 12, cursor: cursor)
    assert(touch.events(for: [TouchContact(id: 2, x: 100, y: 110), TouchContact(id: 3, x: 200, y: 110)], now: 12.1, cursor: cursor).map(\.type) == [.scrollWheel])
    assert(touch.events(for: [finger, second, TouchContact(id: 4, x: 300, y: 100)], now: 12.2, cursor: cursor).isEmpty)
    touch.updatePen(inRange: true)
    assert(touch.events(for: [finger], now: 12.3, cursor: cursor).isEmpty)
    touch.updatePen(inRange: false)
    assert(touch.events(for: [moved], now: 12.4, cursor: cursor).isEmpty, "A resting palm must stay blocked after the pen leaves")
    assert(touch.events(for: [], now: 12.5, cursor: cursor).isEmpty)
    assert(touch.events(for: [finger], now: 12.6, cursor: cursor).isEmpty)
    assert(touch.events(for: [moved], now: 12.7, cursor: cursor).map(\.type) == [.mouseMoved])
    touchSettings.enabled = false; touch.configure(touchSettings)
    assert(touch.events(for: [finger], now: 13, cursor: cursor).isEmpty)
    touchSettings.enabled = true; touch.configure(touchSettings)
    assert(touch.events(for: [moved], now: 13.1, cursor: cursor).isEmpty, "Enabling under an existing contact requires a lift")
    touch.reset(); touch.controlled = false
    assert(touch.events(for: [finger], now: 14, cursor: cursor).isEmpty, "No touch output without exclusive control")
    var rangeDecoder = PenDecoder()
    let entering = rangeDecoder.decode([2, 0xC2, 0x80, 0x24, 0xB8, 9, 0x5D, 0x31, 0, 0])!
    assert(entering.inRange && !entering.inProximity, "Palm rejection starts before the first position report")
    assert(rangeDecoder.decode([2, 0x20, 0, 0, 0, 0, 0, 0, 0, 0])?.inRange == true)
    assert(rangeDecoder.decode([2, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])?.inRange == false)
    assert(legacy.surfaceTouch == nil && !legacy.touchSettings.enabled && legacy.touchSettings.palmRejection)
    settings = DriverSettings(); settings.touchSettings = touchSettings
    try SettingsFile.write(settings, to: url)
    let restoredTouch = try SettingsFile.read(url)
    assert(restoredTouch == settings)
    settings.touchSettings.pointerSpeed = .infinity
    do { try settings.validate(); assertionFailure("Invalid touch speed accepted") } catch { }
    let chargingPacket: [UInt8] = [0xC0, 0, 0, 1, 0x10, 0xE0, 0x18, 0x46, 0x9E, 3]
    let power = TabletPowerStatus.decode(chargingPacket)!
    assert(power.wirelessModuleInstalled && power.batteryPercent == 96 && power.charging == true)
    var earlier = chargingPacket; earlier[8] = 0x90
    assert(TabletPowerStatus.decode(earlier)?.batteryPercent == 51)
    var full = chargingPacket; full[8] = 31
    assert(TabletPowerStatus.decode(full)?.chargingDescription == "Discharging")
    assert(TabletPowerStatus.fromBatteryByte(29, moduleInstalled: true).chargingDescription == "Discharging")
    assert(TabletPowerStatus.fromBatteryByte(0x80 | 29, moduleInstalled: true).chargingDescription == "Charging")
    assert(TabletPowerStatus.fromBatteryByte(29, moduleInstalled: false).chargingDescription == "Unavailable")
    var discharging = chargingPacket; discharging[8] = 15
    assert(TabletPowerStatus.decode(discharging)?.charging == false)
    assert(TabletPowerStatus.decode(discharging)?.batteryPercent == 48)
    var absent = chargingPacket; absent[9] = 1
    let noModule = TabletPowerStatus.decode(absent)!
    assert(!noModule.wirelessModuleInstalled && noModule.batteryPercent == nil && noModule.charging == nil)
    var unknown = chargingPacket; unknown[8] = 0
    assert(TabletPowerStatus.decode(unknown)?.batteryPercent == nil)
    unknown[8] = 0xBF
    assert(TabletPowerStatus.decode(unknown)?.batteryPercent == nil)
    assert(TabletPowerStatus.decode(Array(chargingPacket.prefix(9))) == nil)
    assert(TabletPowerStatus.decode([UInt8](repeating: 0, count: 64)) == nil)
    let powerSession = TabletSession(logging: false)
    var powerUpdates: [TabletPowerStatus?] = []
    powerSession.onPower = { powerUpdates.append($0) }
    powerSession.report(chargingPacket, id: 192)
    powerSession.report(chargingPacket, id: 192)
    assert(powerUpdates.count == 1 && powerUpdates[0] == power, "Repeated readings should refresh age without repeated UI updates")
    powerSession.report(absent, id: 192)
    assert(powerUpdates.last! == noModule)
    powerSession.stop()
    assert(powerUpdates.last! == nil, "Disconnect/stop must clear previous power readings")
    print("Captured module/battery/charging decoding, reserved values, update deduplication, and disconnect reset checks passed.")
    print("Surface contact decoding, pen-range palm rejection, lift-to-resume, disabled state, pointer/scroll/tap, and legacy-settings checks passed.")
    print("Touch-ring wraparound, touch release, direction, response, reset, and legacy-settings checks passed.")
    print("Settings round-trip, invalid-import boundaries, mapping, sensitivity, pad and button-action checks passed.")
}


func checkAdvancedPressure() throws {
    var settings = DriverSettings()
    assert(!settings.advancedFeaturesEnabled && settings.pressureProcessing == nil)
    settings.advancedFeaturesEnabled = true
    settings.processingSettings.enabled = true
    for mode in PressureProcessingMode.allCases {
        settings.processingSettings.mode = mode
        try settings.validate()
        let restored = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(settings))
        assert(restored == settings)
        for rate in [50.0, 133.0, 200.0, 1000.0] {
            var processor = PressureProcessor()
            for index in 0..<3000 {
                let input = Double(index % 101) / 100
                let result = processor.process(input, time: Double(index) / rate, settings: settings)
                assert(result.isFinite && (0...1).contains(result))
                if mode == .bypass { assert(result == input) }
                if mode == .fixed { assert(result == 0.5) }
            }
            processor.reset()
            let result = processor.process(0.25, time: 100, settings: settings)
            assert(result == (mode == .fixed ? 0.5 : 0.25))
        }
    }
    // Pressure modes must preserve every point on an identical curved motion trace.
    for rate in [50.0, 133.0, 200.0] {
        let baseline = PenOutput()
        let variants = PressureProcessingMode.allCases.map { mode in
            let output = PenOutput()
            var variant = settings
            variant.processingSettings.mode = mode
            output.settings = variant
            return output
        }
        for index in 0..<600 {
            let angle = Double(index) * 2 * .pi / 200
            let sample = PenSample(x: 32000 + Int(12000 * cos(angle)), y: 20000 + Int(6000 * sin(angle)),
                                   pressure: 256 + (index * 37) % 1700, inProximity: true, toolID: 1)
            let timestamp = 1 + Double(index) / rate
            let expected = baseline.events(for: sample, time: timestamp)
            for (mode, output) in zip(PressureProcessingMode.allCases, variants) {
                let actual = output.events(for: sample, time: timestamp)
                assert(actual.count == expected.count && actual.map(\.type) == expected.map(\.type))
                for (point, reference) in zip(actual, expected) {
                    assert(point.location == reference.location, "Pressure processing changed motion")
                    // Other flags inherit live OS modifiers, which may change between events.
                    assert(point.flags.contains(.maskNonCoalesced) == reference.flags.contains(.maskNonCoalesced))
                    assert(point.getIntegerValueField(.tabletEventPointX) == reference.getIntegerValueField(.tabletEventPointX))
                    assert(point.getIntegerValueField(.tabletEventPointY) == reference.getIntegerValueField(.tabletEventPointY))
                }
                if mode == .ema {
                    assert(output.outputPressure == baseline.outputPressure, "EMA 12 ms must match legacy pressure exactly")
                }
            }
        }
    }
    print("Motion differential: all five modes preserve every curved-trace point; advanced EMA 12 ms matches legacy exactly.")
    settings.processingSettings.mode = .sampleAndHold
    settings.processingSettings.sampleCount = 2
    var processor = PressureProcessor()
    assert(processor.process(0.2, time: 1, settings: settings) == 0.2)
    assert(abs(processor.process(0.6, time: 1.005, settings: settings) - 0.4) < 1e-12)
    assert(abs(processor.process(1, time: 1.01, settings: settings) - 0.4) < 1e-12)
    processor.reset()
    settings.processingSettings.sampleCount = 64
    assert(processor.process(0.2, time: 2, settings: settings) == 0.2)
    assert(processor.process(1, time: 2.1, settings: settings) == 0.2)
    settings.processingSettings.mode = .movingAverage
    settings.processingSettings.windowMilliseconds = 10
    processor.reset()
    assert(processor.process(0.2, time: 1, settings: settings) == 0.2)
    assert(abs(processor.process(0.6, time: 1.005, settings: settings) - 0.4) < 1e-12)
    assert(abs(processor.process(1, time: 1.02, settings: settings) - 1) < 1e-12)
    for master in [false, true] {
        settings.advancedFeaturesEnabled = master
        settings.processingSettings.enabled = !master
        processor.reset()
        var expected = 0.2
        assert(processor.process(expected, time: 1, settings: settings) == expected)
        expected += (0.8 - expected) * (1 - exp(-0.007 / 0.012))
        assert(abs(processor.process(0.8, time: 1.007, settings: settings) - expected) < 1e-12)
    }
    settings.advancedFeaturesEnabled = true
    settings.processingSettings.enabled = true
    settings.processingSettings.mode = .fixed
    settings.processingSettings.fixedValue = 0
    let output = PenOutput()
    output.settings = settings
    var sample = PenSample(pressure: 1000, inProximity: true, toolID: 1)
    assert(output.events(for: sample, time: 1).last?.type == .leftMouseDown)
    assert(output.outputPressure == 0)
    sample.pressure = 0
    assert(output.events(for: sample, time: 1.001).first?.type == .leftMouseUp)
    assert(output.outputPressure == 0)
    settings.processingSettings.fixedValue = 1
    output.settings = settings
    assert(output.events(for: sample, time: 1.002).last?.type == .mouseMoved && output.outputPressure == 0)
    sample.pressure = 1000
    _ = output.events(for: sample, time: 2)
    sample.toolID = 2
    let switched = output.events(for: sample, time: 2.001)
    assert(switched.first?.type == .leftMouseUp)
    assert(switched.first?.getDoubleValueField(.tabletEventPointPressure) == 0)
    let session = TabletSession(logging: false)
    session.configure(settings)
    _ = session.output.events(for: sample, time: 3)
    var next = settings; next.advancedFeaturesEnabled = false
    session.configure(next)
    assert(session.processingChangePending && session.output.settings.advancedFeaturesEnabled)
    session.resetPen()
    assert(!session.processingChangePending && !session.output.isContact && session.output.outputPressure == 0)
    assert(!session.output.settings.advancedFeaturesEnabled)
    for reset in 0..<3 {
        session.configure(settings)
        _ = session.output.events(for: sample, time: 4)
        switch reset {
        case 0: session.reset()
        case 1: session.setPosting(false)
        default: session.stop()
        }
        assert(!session.output.isContact && session.output.outputPressure == 0)
    }
    settings.processingSettings.mode = .ema
    processor.reset()
    let times = [1.0, 1.001, 1.019, 1.021, 1.09, 1.2]
    for time in times { assert(processor.process(0.5, time: time, settings: settings) == 0.5) }
    settings.processingSettings.mode = .movingAverage
    processor.reset()
    for index in 0..<100_000 {
        let result = processor.process(index.isMultiple(of: 2) ? 0 : 1, time: 1 + Double(index) / 100_000, settings: settings)
        assert(result.isFinite && (0...1).contains(result))
    }
    for invalid in [Double.nan, -Double.infinity, -1, 101] {
        var bad = settings; bad.processingSettings.windowMilliseconds = invalid
        do { try bad.validate(); assertionFailure("Invalid pressure setting accepted") } catch {}
    }
    // Closed-form EMA step response at irregular report intervals.
    settings.processingSettings.mode = .ema
    settings.processingSettings.emaMilliseconds = 12
    processor.reset()
    _ = processor.process(0, time: 0, settings: settings)
    for time in [0.001, 0.007, 0.019, 0.043, 0.09] {
        assert(abs(processor.process(1, time: time, settings: settings) - (1 - exp(-time / 0.012))) < 1e-12)
    }
    // Reference timestamp-window average for irregular noisy/ramp reports.
    settings.processingSettings.mode = .movingAverage
    settings.processingSettings.windowMilliseconds = 30
    processor.reset()
    var reference: [(Double, Double)] = []
    var timestamp = 0.0
    for index in 0..<1000 {
        timestamp += [0.001, 0.007, 0.019, 0.003][index % 4]
        let input = Double((index * 37) % 101) / 100
        reference.append((timestamp, input))
        reference.removeAll { timestamp - $0.0 > 0.03 }
        let expected = reference.reduce(0) { $0 + $1.1 } / Double(reference.count)
        assert(abs(processor.process(input, time: timestamp, settings: settings) - expected) < 1e-12)
    }
    // Exercise the actual decoder/session route, not only direct event generation.
    let tool: [UInt8] = [2, 0xC2, 0x80, 0x24, 0xB8, 9, 0x5D, 0x31, 0, 0]
    let contact: [UInt8] = [2, 0xE0, 0x19, 0x76, 0x38, 0xDC, 0x44, 0x26, 0x52, 0x4D]
    var lift = contact; lift[6] = 0; lift[7] &= 0x3F
    var monitor = [UInt8](repeating: 0, count: 32)
    monitor[0] = 0x80; monitor[1] = 1; monitor[6] = 3; monitor[7] = 0x17
    for mode in PressureProcessingMode.allCases {
        settings.processingSettings.mode = mode
        for reset in 0..<7 {
            let routed = TabletSession(logging: false)
            routed.configure(settings)
            routed.receiverReport(monitor, id: 128)
            routed.report(tool, id: 2); routed.report(contact, id: 2)
            assert(routed.output.isContact)
            switch reset {
            case 0: routed.report(lift, id: 2)
            case 1: routed.resetPen() // watchdog/shared error cleanup
            case 2: routed.setPosting(false)
            case 3: routed.stop()
            case 4: routed.report(tool, id: 2) // new tool identity releases old tool
            case 5:
                var disconnected = monitor; disconnected[1] = 0
                routed.receiverReport(disconnected, id: 128)
            default:
                var medium = monitor; medium[7] = 0x15
                routed.receiverReport(medium, id: 128)
                assert(routed.output.tablet == .medium)
            }
            assert(!routed.output.isContact && routed.output.outputPressure == 0)
            routed.report(tool, id: 2); routed.report(contact, id: 2)
            let fresh = PenOutput(); fresh.settings = settings
            _ = fresh.events(for: routed.decoder.sample)
            let expected = fresh.outputPressure
            assert(abs(routed.output.outputPressure - expected) < 1e-12, "History must not survive reset: \(mode) / \(reset): \(routed.output.outputPressure) vs \(expected)")
        }
    }
    // A profile queued during contact preserves held pad modifiers at lift.
    let routed = TabletSession(logging: false)
    settings.tabletButtons[1] = .shift
    routed.configure(settings)
    _ = routed.buttons.pad(2)
    routed.report(tool, id: 2); routed.report(contact, id: 2)
    let profile = PressureProfile(name: "Queued", sensitivity: 0.2, contactThreshold: 20)
    routed.applyPressureProfile(profile)
    assert(routed.processingChangePending && routed.output.settings.sensitivity != 0.2)
    routed.report(lift, id: 2)
    assert(!routed.processingChangePending && routed.output.settings.sensitivity == 0.2)
    assert(routed.buttons.flags.contains(.maskShift))
    routed.report(contact, id: 2)
    var changed = settings; changed.advancedFeaturesEnabled = false
    routed.configure(changed)
    assert(routed.processingChangePending)
    routed.report(lift, id: 2)
    assert(!routed.processingChangePending && !routed.output.settings.advancedFeaturesEnabled)
    assert(!routed.output.isContact && routed.output.outputPressure == 0)
    // Every parameter rejects nonfinite/out-of-range input at settings validation.
    for keyPath in [\PressureProcessingSettings.fixedValue, \.acquisitionMilliseconds, \.windowMilliseconds, \.emaMilliseconds] {
        for invalid in [Double.nan, Double.infinity, -1, 101] {
            var bad = settings; bad.processingSettings[keyPath: keyPath] = invalid
            do { try bad.validate(); assertionFailure("Invalid parameter accepted") } catch {}
        }
    }
    for count in [0, 65] {
        var bad = settings; bad.processingSettings.sampleCount = count
        do { try bad.validate(); assertionFailure("Invalid count accepted") } catch {}
    }
    print("Advanced pressure modes, cadence, bounds, timeout, master bypass and lifecycle checks passed.")
}


func checkEditablePressureCurve() throws {
    // Slider bounds must allow valid edits in either direction, including plateaus.
    for inverted in [false, true] {
        var curve = EditablePressureCurve(inverted: inverted, anchors: [
            PressureAnchor(input: 0, output: inverted ? 1 : 0),
            PressureAnchor(input: 0.4, output: 0.5),
            PressureAnchor(input: 0.6, output: 0.5),
            PressureAnchor(input: 1, output: inverted ? 0 : 1)
        ])
        for index in curve.anchors.indices {
            for input in [true, false] {
                let range = input ? curve.inputRange(at: index) : curve.outputRange(at: index)
                for value in [range.lowerBound, range.upperBound] {
                    var edited = curve
                    if input { edited.anchors[index].input = value }
                    else { edited.anchors[index].output = value }
                    try edited.validate()
                }
            }
        }
        assert(curve.inputRange(at: 0) == 0...0 && curve.inputRange(at: 3) == 1...1)
        curve.anchors[2].input = curve.anchors[1].input.nextUp.nextUp
        assert(curve.inputRange(at: 1).upperBound < curve.anchors[2].input)
    }
    let legacyJSON = Data(#"{"light":0.1,"medium":0.7,"firm":0.9}"#.utf8)
    let legacy = try JSONDecoder().decode(PressureCurve.self, from: legacyJSON)
    for (x, expected) in zip([0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1], [0.0, 0.05, 0.1, 0.4, 0.7, 0.8, 0.9, 0.95, 1]) {
        assert(abs(legacy.response(x) - expected) < 1e-14)
    }
    var settings = DriverSettings()
    settings.pressureCurve = legacy
    let before = (0...2047).map { settings.pressure($0) }
    var converted = EditablePressureCurve.converting(settings)
    converted.interpolation = .linear
    let linear = CompiledPressureCurve(converted)
    for raw in 0...2047 { assert(abs(linear.response(Double(raw) / 2047) - before[raw]) < 1e-14) }
    let oldProfile = try JSONDecoder().decode(PressureProfile.self, from: Data(#"{"name":"Legacy","version":1,"id":"11111111-1111-1111-1111-111111111111","sensitivity":0.5,"contactThreshold":10,"pressureCurve":{"light":0.1,"medium":0.7,"firm":0.9}}"#.utf8))
    assert(oldProfile.advancedPressureCurve == nil)
    oldProfile.apply(to: &settings)
    assert((0...2047).map { settings.pressure($0) } == before)
    settings.advancedPressureCurve = EditablePressureCurve()
    let stored = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(DriverSettings.self, from: stored)
    assert(restored == settings && !restored.advancedFeaturesEnabled)
    assert((0...2047).map { restored.pressure($0) } == before)
    for interpolation in EditablePressureCurve.Interpolation.allCases {
        for inverted in [false, true] {
            for shape in 0..<40 {
                var curve = EditablePressureCurve()
                curve.interpolation = interpolation; curve.inverted = inverted
                let count = 2 + shape % 7
                curve.anchors = (0..<count).map { index in
                    let x = Double(index) / Double(count - 1)
                    let y = pow(x, Double(1 + shape % 5))
                    return PressureAnchor(input: x, output: inverted ? 1 - y : y)
                }
                try curve.validate()
                let prepared = CompiledPressureCurve(curve)
                var previous = prepared.response(0)
                for raw in 0...2047 {
                    let x = Double(raw) / 2047
                    let value = prepared.response(x)
                    assert(value.isFinite && (0...1).contains(value))
                    assert(inverted ? value <= previous + 1e-14 : value >= previous - 1e-14)
                    previous = value
                    let index = min(count - 2, Int(x * Double(count - 1)))
                    let a = curve.anchors[index].output, b = curve.anchors[index + 1].output
                    assert(value >= min(a, b) - 1e-14 && value <= max(a, b) + 1e-14)
                }
                for anchor in curve.anchors { assert(abs(prepared.response(anchor.input) - anchor.output) < 1e-14) }
                // Interior derivatives from either side agree on nondegenerate smooth segments.
                if interpolation == .smooth {
                    for anchor in curve.anchors.dropFirst().dropLast() {
                        let epsilon = 1e-7
                        let left = (prepared.response(anchor.input) - prepared.response(anchor.input - epsilon)) / epsilon
                        let right = (prepared.response(anchor.input + epsilon) - prepared.response(anchor.input)) / epsilon
                        assert(abs(left - right) < 0.001)
                    }
                }
            }
        }
    }
    var plateau = EditablePressureCurve(anchors: [
        PressureAnchor(input: 0, output: 0), PressureAnchor(input: 0.3, output: 1), PressureAnchor(input: 1, output: 1)])
    for inverted in [false, true] {
        plateau.inverted = inverted
        if inverted { plateau.anchors = plateau.anchors.map { PressureAnchor(input: $0.input, output: 1 - $0.output) } }
        let prepared = CompiledPressureCurve(plateau)
        for raw in 615...2047 { assert(abs(prepared.response(Double(raw) / 2047) - (inverted ? 0 : 1)) < 1e-14) }
    }
    let close = EditablePressureCurve(anchors: [
        PressureAnchor(input: 0, output: 0), PressureAnchor(input: 0.5, output: 0.2),
        PressureAnchor(input: 0.5.nextUp, output: 0.8), PressureAnchor(input: 1, output: 1)])
    try close.validate()
    let closePrepared = CompiledPressureCurve(close)
    for raw in 0...2047 { assert(closePrepared.response(Double(raw) / 2047).isFinite) }
    for invalid in [
        EditablePressureCurve(anchors: []),
        EditablePressureCurve(anchors: [PressureAnchor(input: 0, output: 0), PressureAnchor(input: 0, output: 0.5), PressureAnchor(input: 1, output: 1)]),
        EditablePressureCurve(anchors: [PressureAnchor(input: 0, output: 1), PressureAnchor(input: 1, output: 0)]),
        EditablePressureCurve(anchors: [PressureAnchor(input: 0, output: .nan), PressureAnchor(input: 1, output: 1)])
    ] {
        do { try invalid.validate(); assertionFailure("Invalid editable curve accepted") } catch {}
    }
    settings.advancedPressureCurve = plateau
    settings.advancedFeaturesEnabled = true
    settings.smoothingMilliseconds = 0
    let output = PenOutput(); output.settings = settings
    let sample = PenSample(pressure: 1200, inProximity: true, toolID: 1)
    _ = output.events(for: sample, time: 1)
    assert(output.outputPressure == settings.pressure(sample.pressure))
    let up = output.events(for: PenSample(), time: 1.001)
    assert(output.outputPressure == 0 && up.first?.getDoubleValueField(.tabletEventPointPressure) == 0)
    settings.advancedFeaturesEnabled = false; output.settings = settings
    _ = output.events(for: sample, time: 2)
    assert(output.outputPressure == settings.baselinePressureResponse(Double(sample.pressure) / 2047))
    _ = output.events(for: PenSample(), time: 2.001)
    settings.advancedFeaturesEnabled = true; output.settings = settings
    _ = output.events(for: sample, time: 3)
    assert(output.outputPressure == settings.pressure(sample.pressure) && output.settings.advancedPressureCurve == plateau)
    let directory = URL.temporaryDirectory.appendingPathComponent("waccom-curve-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    try SettingsFile.write(settings, to: url)
    let validData = try Data(contentsOf: url)
    var invalidSettings = settings
    invalidSettings.advancedPressureCurve!.anchors[1].input = 0
    do { try SettingsFile.write(invalidSettings, to: url); assertionFailure("Invalid curve overwrote file") } catch {}
    let preservedData = try Data(contentsOf: url)
    assert(preservedData == validData)
    let reloadedSettings = try SettingsFile.read(url)
    assert(reloadedSettings == settings)
    let profile = PressureProfile(name: "Advanced", sensitivity: 0.5, contactThreshold: 10, pressureCurve: legacy, advancedPressureCurve: plateau)
    let reloaded = try JSONDecoder().decode(PressureProfile.self, from: JSONEncoder().encode(profile))
    try reloaded.validate()
    var applied = DriverSettings(); reloaded.apply(to: &applied)
    assert(applied.advancedPressureCurve == plateau && !applied.advancedFeaturesEnabled)
    assert((0...2047).map { applied.pressure($0) } == before)
    applied.advancedFeaturesEnabled = true
    assert(applied.pressure(1200) == settings.pressure(1200))
    print("Editable curves: legacy golden values, all native inputs, shape bounds, derivatives, inversion, plateaus, close anchors, JSON, master gate and lift passed.")
}


func checkPulledString() throws {
    var string = PulledString()
    assert(string.process(.zero, length: 10) == .zero)
    assert(string.process(.zero, length: 10) == .zero)
    assert(string.process(CGPoint(x: 6, y: 8), length: 10) == .zero)
    assert(string.process(CGPoint(x: 20, y: 0), length: 10) == CGPoint(x: 10, y: 0))
    let turn = string.process(CGPoint(x: 20, y: 20), length: 10)
    assert(abs(hypot(20 - turn.x, 20 - turn.y) - 10) < 1e-12)
    assert(abs(turn.x - (20 - 100 / sqrt(500.0))) < 1e-12)
    for index in 0..<1000 {
        let angle = Double(index) * 2 * .pi / 200
        let input = CGPoint(x: 100 * cos(angle), y: 100 * sin(angle))
        let result = string.process(input, length: 10)
        assert(hypot(input.x - result.x, input.y - result.y) <= 10 + 1e-12)
    }
    assert(string.process(CGPoint(x: -100, y: 200), length: 0) == CGPoint(x: -100, y: 200))
    string.reset()
    assert(string.process(CGPoint(x: 12, y: 34), length: 10) == CGPoint(x: 12, y: 34))
    var settings = DriverSettings()
    assert(!settings.stringSettings.enabled && settings.pulledString == nil)
    settings.advancedFeaturesEnabled = true
    settings.stringSettings.enabled = true
    settings.stringSettings.length = 500
    settings.smoothingMilliseconds = 0
    try settings.validate()
    let decoded = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(settings))
    assert(decoded == settings)
    for length in [Double.nan, Double.infinity, -0.1, 500.1] {
        var invalid = settings; invalid.stringSettings.length = length
        do { try invalid.validate(); assertionFailure("Invalid string length accepted") } catch {}
    }
    for tablet in SupportedTablet.allCases {
        for rotated in [false, true] {
            for bypass in 0..<4 {
                let output = PenOutput(); output.tablet = tablet
                var config = settings
                config.rotate180 = rotated; config.preserveAspect = true
                config.areaX = 0.1; config.areaY = 0.2; config.areaWidth = 0.7; config.areaHeight = 0.6
                if bypass == 0 { config.advancedFeaturesEnabled = false }
                if bypass == 1 { config.stringSettings.enabled = false }
                if bypass == 2 { config.stringSettings.length = 0 }
                output.settings = config
                var mappedReference = PulledString()
                for i in 0..<200 {
                    let sample = PenSample(x: Int(tablet.penSize.width * Double(i) / 199),
                                           y: Int(tablet.penSize.height * Double(199 - i) / 199),
                                           pressure: 1000, inProximity: true, toolID: 1)
                    let point = output.events(for: sample, time: 1 + Double(i) / 200).last!
                    let mapped = output.mappedLocation(for: sample)
                    let expected = bypass == 3 ? mappedReference.process(mapped, length: 500) : mapped
                    assert(point.location == expected)
                    assert(output.buttonLocation(for: sample) == expected)
                }
            }
        }
    }
    let output = PenOutput(); output.settings = settings
    var sample = PenSample(x: 20000, y: 10000, pressure: 500, tiltX: 16, inProximity: true, toolID: 1)
    let start = output.events(for: sample, time: 1).last!.location
    sample.x += 1; sample.pressure = 1500; sample.tiltX = 32
    let held = output.events(for: sample, time: 1.005).last!
    assert(held.location == start && output.outputPressure == settings.pressure(1500))
    let tiltReference = PenOutput().events(for: sample, time: 1.005).last!
    assert(held.getDoubleValueField(.tabletEventTiltX) == tiltReference.getDoubleValueField(.tabletEventTiltX))
    assert(output.buttonLocation(for: sample) == start)
    sample.pressure = 0; sample.x += 5000
    let lift = output.events(for: sample, time: 1.01)
    assert(lift.first?.type == .leftMouseUp && lift.allSatisfy { $0.location == start })
    assert(lift.allSatisfy { $0.getDoubleValueField(.tabletEventPointPressure) == 0 })
    let hover = output.events(for: sample, time: 1.015).last!
    assert(hover.type == .mouseMoved && hover.location == output.mappedLocation(for: sample))
    output.heldMouse = .right
    assert(output.events(for: sample, time: 1.02).last?.type == .rightMouseDragged)
    assert(output.outputLocation == output.mappedLocation(for: sample))
    output.heldMouse = nil
    sample.pressure = 1000
    _ = output.events(for: sample, time: 2)
    sample.x += 2000; sample.toolID = 2
    let switched = output.events(for: sample, time: 2.005)
    assert(switched.first?.type == .leftMouseUp)
    assert(switched.last?.type == .leftMouseDown && switched.last?.location == output.mappedLocation(for: sample))
    let session = TabletSession(logging: false); session.configure(settings)
    _ = session.output.events(for: sample, time: 3)
    var next = settings; next.stringSettings.length = 25
    session.configure(next)
    assert(session.processingChangePending && session.output.settings.stringSettings.length == 500)
    session.resetPen()
    assert(!session.processingChangePending && session.output.settings.stringSettings.length == 25)
    assert(session.output.outputPressure == 0 && !session.output.isContact)
    let tool: [UInt8] = [2, 0xC2, 0x80, 0x24, 0xB8, 9, 0x5D, 0x31, 0, 0]
    let packet: [UInt8] = [2, 0xE0, 0x19, 0x76, 0x38, 0xDC, 0x44, 0x26, 0x52, 0x4D]
    var moved = packet; moved[2] = 0x29
    var monitor = [UInt8](repeating: 0, count: 32)
    monitor[0] = 0x80; monitor[1] = 1; monitor[6] = 3; monitor[7] = 0x17
    for reset in 0..<7 {
        let routed = TabletSession(logging: false); routed.configure(settings)
        routed.receiverReport(monitor, id: 128)
        routed.report(tool, id: 2); routed.report(packet, id: 2); routed.report(moved, id: 2)
        switch reset {
        case 0: var up = moved; up[6] = 0; up[7] &= 0x3F; routed.report(up, id: 2)
        case 1: routed.resetPen()
        case 2: routed.setPosting(false)
        case 3: routed.stop()
        case 4: routed.report(tool, id: 2)
        case 5: var disconnected = monitor; disconnected[1] = 0; routed.receiverReport(disconnected, id: 128)
        default: var medium = monitor; medium[7] = 0x15; routed.receiverReport(medium, id: 128)
        }
        assert(!routed.output.isContact && routed.output.outputPressure == 0)
        routed.report(tool, id: 2); routed.report(packet, id: 2)
        assert(routed.output.outputLocation == routed.output.mappedLocation(for: routed.decoder.sample))
    }
    // Guide snapshots are derived from effective delivered state, with no UI work here.
    let guideOutput = PenOutput(); guideOutput.settings = settings
    guideOutput.posting = true // events(for:) does not post, even with this flag.
    assert(guideOutput.stringGuide == nil)
    var guideSample = PenSample(x: 20000, y: 10000, pressure: 1000, inProximity: true, toolID: 1)
    _ = guideOutput.events(for: guideSample, time: 1)
    guideSample.x += 100
    _ = guideOutput.events(for: guideSample, time: 1.005)
    let guide = guideOutput.stringGuide!
    assert(guide.input == guideOutput.mappedLocation(for: guideSample) && guide.output == guideOutput.outputLocation)
    assert(guide.bounds.contains(guide.input) && guide.bounds.contains(guide.output))
    guideSample.pressure = 0
    _ = guideOutput.events(for: guideSample, time: 1.01)
    assert(guideOutput.stringGuide == nil)
    for gate in 0..<4 {
        var config = settings
        if gate == 0 { config.advancedFeaturesEnabled = false }
        if gate == 1 { config.stringSettings.enabled = false }
        if gate == 2 { config.stringSettings.length = 0 }
        if gate == 3 { config.stringSettings.guideVisible = false }
        guideOutput.settings = config; guideSample.pressure = 1000
        _ = guideOutput.events(for: guideSample, time: 2)
        assert(guideOutput.stringGuide == nil)
    }
    let negativeGuide = StringGuideSnapshot(input: CGPoint(x: -100, y: -200), output: CGPoint(x: -140, y: -220), length: 40, displayBounds: CGRect(x: -1000, y: -1000, width: 1000, height: 1000))
    assert(negativeGuide.bounds.minX == -188 && negativeGuide.bounds.minY == -268)
    let legacyString = try JSONDecoder().decode(PulledStringSettings.self, from: Data(#"{"enabled":true,"length":12}"#.utf8))
    assert(legacyString.guideVisible)
    print("Pulled string: geometry, turns/circles, repeated points, all bypass gates, mapping/models, held pressure/tilt, immediate lift, hover/button drags and deferred settings passed.")
}


func checkPressureSpeed() throws {
    var config = PressureSpeedSettings()
    assert(!config.enabled && config.slowGain == 1 && config.fastGain == 1)
    config.enabled = true; config.slowGain = 0.5; config.fastGain = 2
    assert(config.gain(at: 0) == 0.5 && config.gain(at: 500) == 1.25 && config.gain(at: 2000) == 2)
    config.slowGain = 2; config.fastGain = 0.5
    assert(config.gain(at: 0) == 2 && config.gain(at: 500) == 1.25 && config.gain(at: 2000) == 0.5)
    config.averagingMilliseconds = 20
    for rate in [50.0, 100.0, 200.0, 1000.0] {
        var velocity = PressureVelocity()
        assert(velocity.update(.zero, time: 0, settings: config) == 1)
        for i in 1...Int(rate) {
            let t = Double(i) / rate
            _ = velocity.update(CGPoint(x: 1000 * t, y: 0), time: t, settings: config)
            assert(abs(velocity.speed - 1000 * (1 - exp(-t / 0.02))) < 1e-7)
        }
        let beforeStop = velocity.speed
        _ = velocity.update(CGPoint(x: 1000, y: 0), time: 1 + 1 / rate, settings: config)
        assert(abs(velocity.speed - beforeStop * exp(-1 / rate / 0.02)) < 1e-7)
        velocity.reset()
        for i in 0..<100 {
            let t = Double(i) / rate
            let gain = velocity.update(CGPoint(x: 100 * t * t, y: 0), time: t, settings: config)
            assert(gain.isFinite && (0.5...2).contains(gain))
        }
    }
    for invalidTime in [Double.nan, Double.infinity, 1, 0.5, 1.0000000001, 2] {
        var velocity = PressureVelocity()
        _ = velocity.update(.zero, time: 1, settings: config)
        assert(velocity.update(CGPoint(x: 1000, y: 0), time: invalidTime, settings: config) == 1)
        assert(velocity.speed == 0 && velocity.gain == 1)
    }
    for key in [\PressureSpeedSettings.slowSpeed, \.fastSpeed, \.slowGain, \.fastGain, \.averagingMilliseconds] {
        for invalid in [Double.nan, Double.infinity, -1, 10001] {
            var bad = config; bad[keyPath: key] = invalid
            do { try bad.validate(); assertionFailure("Invalid speed setting accepted") } catch {}
        }
    }
    var bad = config; bad.fastSpeed = bad.slowSpeed
    do { try bad.validate(); assertionFailure("Duplicate thresholds accepted") } catch {}
    var settings = DriverSettings()
    assert(settings.pressureSpeed == nil)
    settings.advancedFeaturesEnabled = true; settings.speedSettings.enabled = true
    settings.processingSettings.enabled = true
    for mode in PressureProcessingMode.allCases {
        settings.processingSettings.mode = mode
        let neutral = PenOutput(); neutral.settings = settings
        var baselineSettings = settings; baselineSettings.speedSettings.enabled = false
        let baseline = PenOutput(); baseline.settings = baselineSettings
        var amplifiedSettings = settings
        amplifiedSettings.speedSettings.slowGain = 0.5; amplifiedSettings.speedSettings.fastGain = 2
        let amplified = PenOutput(); amplified.settings = amplifiedSettings
        for i in 0..<100 {
            let sample = PenSample(x: 20000 + i * 100, y: 10000, pressure: 600 + i * 10, inProximity: true, toolID: 1)
            let time = 1 + Double(i) / 200
            let a = neutral.events(for: sample, time: time)
            let b = baseline.events(for: sample, time: time)
            _ = amplified.events(for: sample, time: time)
            assert(neutral.outputPressure == baseline.outputPressure && a.map(\.type) == b.map(\.type))
            assert(a.last?.location == b.last?.location)
            assert(abs(amplified.outputPressure - min(1, baseline.outputPressure * amplified.currentSpeedGain)) < 1e-12)
        }
        _ = amplified.events(for: PenSample(), time: 1.5)
        assert(amplified.outputPressure == 0 && amplified.currentSpeed == 0 && amplified.currentSpeedGain == 1)
    }
    settings.speedSettings.slowGain = 0.5; settings.speedSettings.fastGain = 2
    settings.stringSettings.enabled = true; settings.stringSettings.length = 500
    let held = PenOutput(); held.settings = settings
    var sample = PenSample(x: 20000, y: 10000, pressure: 1000, inProximity: true, toolID: 1)
    let start = held.events(for: sample, time: 1).last!.location
    sample.x += 10
    assert(held.events(for: sample, time: 1.005).last!.location == start)
    assert(held.currentSpeed > 0, "Speed must use raw mapped input while output is held")
    var off = settings; off.advancedFeaturesEnabled = false
    held.settings = off
    _ = held.events(for: sample, time: 1.01)
    assert(held.currentSpeedGain == 1 && held.settings.speedSettings == settings.speedSettings)
    for tablet in SupportedTablet.allCases {
        let output = PenOutput(); output.tablet = tablet; output.settings = settings
        var sample = PenSample(x: 10000, y: 10000, pressure: 1000, inProximity: true, toolID: 1)
        _ = output.events(for: sample, time: 1)
        let p = output.mappedLocation(for: sample); sample.x += 100
        let q = output.mappedLocation(for: sample)
        let dt = hypot(q.x - p.x, q.y - p.y) / 1000
        _ = output.events(for: sample, time: 1 + dt)
        assert(abs(output.currentSpeed - 1000) < 1e-6)
    }
    let restored = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(settings))
    assert(restored == settings)
    let session = TabletSession(logging: false)
    var monitor = [UInt8](repeating: 0, count: 32)
    monitor[0] = 0x80; monitor[1] = 1; monitor[6] = 3; monitor[7] = 0x17
    for reset in 0..<8 {
        session.configure(settings)
        session.receiverReport(monitor, id: 128)
        _ = session.output.events(for: sample, time: 1)
        sample.x += 100
        _ = session.output.events(for: sample, time: 1.005)
        assert(session.output.currentSpeed > 0)
        switch reset {
        case 0: session.resetPen()
        case 1: session.setPosting(false)
        case 2: session.stop()
        case 3: _ = session.output.events(for: PenSample(inProximity: false, toolID: 2), time: 1.01)
        case 4:
            var disconnected = monitor; disconnected[1] = 0
            session.receiverReport(disconnected, id: 128)
        case 5:
            var medium = monitor; medium[7] = 0x15
            session.receiverReport(medium, id: 128)
        case 6:
            var mapping = settings; mapping.rotate180 = true
            session.configure(mapping)
            assert(session.processingChangePending)
            session.resetPen()
        default:
            session.applyPressureProfile(PressureProfile(name: "Speed reset", sensitivity: 0.3, contactThreshold: 10))
            assert(session.processingChangePending)
            session.resetPen()
        }
        assert(session.output.currentSpeed == 0 && session.output.currentSpeedGain == 1 && !session.output.isContact)
    }
    print("Speed gain: cadence/averaging, acceleration/stops, invalid times/settings, both gain directions, every pressure mode, raw pre-string velocity, model units, bypass and resets passed.")
}

#endif
