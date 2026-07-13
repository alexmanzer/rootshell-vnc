import CoreGraphics
import Foundation
import IOKit

// Private CoreGraphics SPI. It is present in the macOS 26 CoreGraphics SDK
// export list, but Apple does not publish or guarantee this function.
@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(
    _ configuration: CGDisplayConfigRef?,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

private struct DisplayState {
    let id: CGDirectDisplayID
    let isActive: Bool
    let isBuiltIn: Bool
    let isMain: Bool
    let bounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

private enum RepairError: LocalizedError {
    case coreGraphics(operation: String, code: CGError)
    case noExternalDisplay
    case lidIsOpen
    case noStrandedBuiltInDisplay
    case repairDidNotTakeEffect

    var errorDescription: String? {
        switch self {
        case let .coreGraphics(operation, code):
            return "\(operation) failed with CoreGraphics error \(code.rawValue)."
        case .noExternalDisplay:
            return "No active external display was found; refusing to disable the built-in display."
        case .lidIsOpen:
            return "The lid is open; this does not look like the clamshell Screen Sharing bug."
        case .noStrandedBuiltInDisplay:
            return "The built-in display is not active, so there is nothing to repair."
        case .repairDidNotTakeEffect:
            return "macOS accepted the display transaction, but the built-in display is still active."
        }
    }
}

private let repairDefaults = UserDefaults(
    suiteName: "com.rootshell.ClamshellDisplayRepair")!
private let disabledDisplayIDsKey = "DisabledBuiltInDisplayIDs"

private func onlineDisplays() throws -> [DisplayState] {
    var count: UInt32 = 0
    var result = CGGetOnlineDisplayList(0, nil, &count)
    guard result == .success else {
        throw RepairError.coreGraphics(operation: "Reading the display count", code: result)
    }

    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    result = CGGetOnlineDisplayList(count, &ids, &count)
    guard result == .success else {
        throw RepairError.coreGraphics(operation: "Reading the display list", code: result)
    }

    return ids.prefix(Int(count)).map { id in
        DisplayState(
            id: id,
            isActive: CGDisplayIsActive(id) != 0,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isMain: CGDisplayIsMain(id) != 0,
            bounds: CGDisplayBounds(id),
            pixelWidth: CGDisplayPixelsWide(id),
            pixelHeight: CGDisplayPixelsHigh(id))
    }
}

private func clamshellState() -> Bool? {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    guard let value = IORegistryEntryCreateCFProperty(
        service,
        "AppleClamshellState" as CFString,
        kCFAllocatorDefault,
        0)?.takeRetainedValue() else { return nil }
    return (value as? NSNumber)?.boolValue
}

private func printStatus(_ displays: [DisplayState], lidClosed: Bool?) {
    let lid = lidClosed.map { $0 ? "closed" : "open" } ?? "unknown"
    print("Lid: \(lid); online displays: \(displays.count); active displays: \(displays.filter(\.isActive).count)")
    for display in displays {
        let kind = display.isBuiltIn ? "built-in" : "external"
        let activity = display.isActive ? "active" : "inactive"
        let main = display.isMain ? ", main" : ""
        print(
            "  \(display.id): \(kind), \(activity)\(main), "
                + "\(display.pixelWidth)x\(display.pixelHeight) pixels, bounds \(display.bounds)")
    }
}

private func setEnabled(_ enabled: Bool, displays: [CGDirectDisplayID]) throws {
    var configuration: CGDisplayConfigRef?
    var result = CGBeginDisplayConfiguration(&configuration)
    guard result == .success else {
        throw RepairError.coreGraphics(operation: "Beginning display repair", code: result)
    }

    var completed = false
    defer {
        if !completed {
            CGCancelDisplayConfiguration(configuration)
        }
    }

    for display in displays {
        result = CGSConfigureDisplayEnabled(configuration, display, enabled)
        guard result == .success else {
            throw RepairError.coreGraphics(operation: "Changing display \(display)", code: result)
        }
    }

    result = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard result == .success else {
        throw RepairError.coreGraphics(operation: "Applying display repair", code: result)
    }
    completed = true
}

private func repair() throws {
    let displays = try onlineDisplays()
    guard displays.contains(where: { $0.isActive && !$0.isBuiltIn }) else {
        throw RepairError.noExternalDisplay
    }
    guard clamshellState() == true else { throw RepairError.lidIsOpen }

    let stranded = displays.filter { $0.isActive && $0.isBuiltIn }.map(\.id)
    guard !stranded.isEmpty else { throw RepairError.noStrandedBuiltInDisplay }
    try setEnabled(false, displays: stranded)

    let repaired = try onlineDisplays()
    guard !repaired.contains(where: { $0.isActive && $0.isBuiltIn }) else {
        throw RepairError.repairDidNotTakeEffect
    }
    repairDefaults.set(stranded.map(Int.init), forKey: disabledDisplayIDsKey)
    print("Repair succeeded. The closed built-in display is no longer active.")
    printStatus(repaired, lidClosed: clamshellState())
}

private func enableBuiltInDisplays() throws {
    let onlineBuiltIns = try onlineDisplays().filter(\.isBuiltIn).map(\.id)
    let rememberedBuiltIns = (repairDefaults.array(forKey: disabledDisplayIDsKey) as? [NSNumber])?
        .map { CGDirectDisplayID($0.uint32Value) } ?? []
    // CoreGraphics normally allocates small IDs to local displays. This
    // fallback also makes recovery possible after an older build performed a
    // repair without remembering the ID. Invalid IDs return -1, not 1.
    let discoverableBuiltIns = (1...32)
        .map(CGDirectDisplayID.init)
        .filter { CGDisplayIsBuiltin($0) == 1 }
    let builtIns = Array(Set(
        onlineBuiltIns + rememberedBuiltIns + discoverableBuiltIns))
        .filter { CGDisplayIsBuiltin($0) == 1 }
    guard !builtIns.isEmpty else {
        print("No built-in display was found.")
        return
    }
    try setEnabled(true, displays: builtIns)
    repairDefaults.removeObject(forKey: disabledDisplayIDsKey)
    print("Enabled the built-in display for this login session.")
    printStatus(try onlineDisplays(), lidClosed: clamshellState())
}

do {
    switch CommandLine.arguments.dropFirst().first ?? "--status" {
    case "--status":
        printStatus(try onlineDisplays(), lidClosed: clamshellState())
    case "--repair":
        try repair()
    case "--enable-built-in":
        try enableBuiltInDisplays()
    default:
        print("Usage: ClamshellDisplayRepair [--status | --repair | --enable-built-in]")
        exit(64)
    }
} catch {
    fputs("ClamshellDisplayRepair: \(error.localizedDescription)\n", stderr)
    exit(1)
}
