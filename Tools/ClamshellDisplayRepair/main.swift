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
    case temporaryPulseFailed(String)
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
        case let .temporaryPulseFailed(message):
            return "The temporary display pulse failed: \(message)"
        case .repairDidNotTakeEffect:
            return "The temporary pulse ended, but the closed built-in display is still active."
        }
    }
}

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

private func temporarilyDisable(displays: [CGDirectDisplayID]) throws {
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
        result = CGSConfigureDisplayEnabled(configuration, display, false)
        guard result == .success else {
            throw RepairError.coreGraphics(operation: "Changing display \(display)", code: result)
        }
    }

    // This is the central safety property: the disable exists only while this
    // short-lived child process is alive. macOS automatically reverts it if
    // the process exits or crashes. The pulse gives clamshell policy a real
    // display-topology transition to react to without leaving a session-wide
    // override behind.
    result = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
    guard result == .success else {
        throw RepairError.coreGraphics(operation: "Applying display repair", code: result)
    }
    completed = true
}

private func strandedBuiltInDisplays() throws -> [CGDirectDisplayID] {
    let displays = try onlineDisplays()
    guard displays.contains(where: { $0.isActive && !$0.isBuiltIn }) else {
        throw RepairError.noExternalDisplay
    }
    guard clamshellState() == true else { throw RepairError.lidIsOpen }

    let stranded = displays.filter { $0.isActive && $0.isBuiltIn }.map(\.id)
    guard !stranded.isEmpty else { throw RepairError.noStrandedBuiltInDisplay }
    return stranded
}

private func runTemporaryPulseChild() throws {
    let stranded = try strandedBuiltInDisplays()
    try temporarilyDisable(displays: stranded)

    let temporaryState = try onlineDisplays()
    guard !temporaryState.contains(where: { $0.isActive && $0.isBuiltIn }) else {
        throw RepairError.repairDidNotTakeEffect
    }
    Thread.sleep(forTimeInterval: 0.5)
    // Do not explicitly enable the panel. Exiting this child removes the
    // application-scoped configuration atomically and safely.
}

private func repair() throws {
    _ = try strandedBuiltInDisplays()

    let process = Process()
    process.executableURL = URL(
        fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--temporary-pulse-child"]
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        throw RepairError.temporaryPulseFailed(error.localizedDescription)
    }

    let childError = String(
        decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw RepairError.temporaryPulseFailed(
            childError.isEmpty ? "child exited with status \(process.terminationStatus)" : childError)
    }

    // This check runs only after the child has exited, so its app-scoped
    // disable no longer exists. One external display here means macOS's own
    // clamshell policy adopted the correct topology.
    Thread.sleep(forTimeInterval: 0.25)
    let repaired = try onlineDisplays()
    guard repaired.contains(where: { $0.isActive && !$0.isBuiltIn }),
          !repaired.contains(where: { $0.isActive && $0.isBuiltIn }) else {
        throw RepairError.repairDidNotTakeEffect
    }
    print("Repair succeeded. The temporary override has ended and the closed built-in display remains inactive.")
    printStatus(repaired, lidClosed: clamshellState())
}

do {
    switch CommandLine.arguments.dropFirst().first ?? "--status" {
    case "--status":
        printStatus(try onlineDisplays(), lidClosed: clamshellState())
    case "--repair":
        try repair()
    case "--temporary-pulse-child":
        try runTemporaryPulseChild()
    default:
        print("Usage: ClamshellDisplayRepair [--status | --repair]")
        exit(64)
    }
} catch {
    fputs("ClamshellDisplayRepair: \(error.localizedDescription)\n", stderr)
    exit(1)
}
