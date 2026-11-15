#if !APP
import Foundation
import CoreGraphics

func checkRulers() throws {
    var editable = RulerSettings()
    editable.kind = .perspectiveEllipse
    editable.corners = [RulerPoint(x: 0, y: 0), RulerPoint(x: 100, y: 0), RulerPoint(x: 100, y: 100), RulerPoint(x: 0, y: 100)]
    let shifted = editable.editing(.move, delta: CGPoint(x: 20, y: -10))!
    assert(shifted.corners[0] == RulerPoint(x: 20, y: -10) && shifted.corners[2] == RulerPoint(x: 120, y: 90))
    assert(shifted.vanishingPoints == editable.vanishingPoints, "Editing must not move unrelated family geometry")
    let edge = editable.editing(.edge(0), delta: CGPoint(x: 0, y: -20))!
    assert(edge.corners[0].y == -20 && edge.corners[1].y == -20 && edge.corners[2].y == 100)
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
    assert(hypot(acquired.x - intended.x, acquired.y - intended.y) < 0.01, "Initial wobble must not lock a nearby perspective family")
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
    assert(projection.process(CGPoint(x: 8, y: 0), settings: config) == CGPoint(x: 8, y: 0))
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
    settings.stringSettings.enabled = true; settings.stringSettings.length = 50
    settings.rulerSettings.kind = .perspectiveEllipse
    output.settings = settings
    sample.pressure = 1000
    let controlPoint = output.mappedLocation(for: sample)
    output.overlayControlBounds = [CGRect(x: controlPoint.x - 10, y: controlPoint.y - 10, width: 20, height: 20)]
    _ = output.events(for: sample)
    assert(output.outputLocation == controlPoint, "A pen tap on canvas controls must bypass positional filters")
    sample.x += 5000; sample.y += 5000
    _ = output.events(for: sample)
    assert(output.outputLocation == output.mappedLocation(for: sample), "A control gesture stays direct outside the toolbar")
    sample.pressure = 0; _ = output.events(for: sample)
    sample.pressure = 1000; _ = output.events(for: sample)
    assert(output.outputLocation != output.mappedLocation(for: sample), "Drawing outside controls must still snap")
    sample.x -= 5000; sample.y -= 5000
    _ = output.events(for: sample)
    assert(output.outputLocation != controlPoint, "An existing drawing stroke must not switch filters when crossing controls")
    sample.pressure = 0; _ = output.events(for: sample)
    output.overlayMenuTracking = true
    sample.x += 5000; sample.pressure = 1000
    _ = output.events(for: sample)
    assert(output.outputLocation == output.mappedLocation(for: sample), "Ruler menu items must be reachable with the pen")
    sample.pressure = 0; _ = output.events(for: sample)
    output.overlayMenuTracking = false

}

func checkSettingsAndButtons() throws {
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
