import RFBProtocol

/// Selects the conventional RFB wheel-button masks used when the server does
/// not advertise Apple's precise-scroll command.
enum AppleScrollFallback {
    private static let scrollUpButton: UInt8 = 0x08
    private static let scrollDownButton: UInt8 = 0x10
    private static let scrollRightButton: UInt8 = 0x20
    private static let scrollLeftButton: UInt8 = 0x40

    static func wheelButtonMasks(
        for event: AppleScrollEvent,
        includeHorizontal: Bool
    ) -> [UInt8] {
        var masks: [UInt8] = []

        // Apple's legacy path only sends horizontal wheel buttons to an Apple
        // server. Positive X is button 6; negative X is button 7. Preserve the
        // coarse wheel magnitude: collapsing an accelerated trackpad sample to
        // one button click made Standard mode barely scroll at all.
        if includeHorizontal {
            appendClicks(
                event.deltaX,
                positiveMask: scrollRightButton,
                negativeMask: scrollLeftButton,
                to: &masks)
        }

        // This sign is intentional and matches CGEvent/RFB native behavior:
        // positive vertical delta is wheel-up, negative is wheel-down.
        appendClicks(
            event.deltaY,
            positiveMask: scrollUpButton,
            negativeMask: scrollDownButton,
            to: &masks)

        return masks
    }

    private static func appendClicks(
        _ signedCount: Int16,
        positiveMask: UInt8,
        negativeMask: UInt8,
        to masks: inout [UInt8]
    ) {
        guard signedCount != 0 else { return }
        // One UI sample should not monopolize the serialized control channel
        // after an unusually large acceleration spike. Later queued samples
        // still preserve the rest of the gesture's direction and movement.
        let count = min(32, abs(Int(signedCount)))
        masks.append(
            contentsOf: repeatElement(
                signedCount > 0 ? positiveMask : negativeMask,
                count: count))
    }
}
