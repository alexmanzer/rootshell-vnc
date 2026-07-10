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
        // server. Positive X is button 6; negative X is button 7.
        if includeHorizontal {
            if event.deltaX > 0 {
                masks.append(scrollRightButton)
            } else if event.deltaX < 0 {
                masks.append(scrollLeftButton)
            }
        }

        // This sign is intentional and matches CGEvent/RFB native behavior:
        // positive vertical delta is wheel-up, negative is wheel-down.
        if event.deltaY > 0 {
            masks.append(scrollUpButton)
        } else if event.deltaY < 0 {
            masks.append(scrollDownButton)
        }

        return masks
    }
}
