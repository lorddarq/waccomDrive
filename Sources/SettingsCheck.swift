#if !APP
import Foundation
import CoreGraphics

func checkSettingsAndButtons() throws {
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
    assert(TabletPowerStatus.decode(full)?.chargingDescription == "Fully charged")
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

#endif
