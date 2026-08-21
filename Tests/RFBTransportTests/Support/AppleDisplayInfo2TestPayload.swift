import Foundation
import RFBProtocol

func appleDisplayInfo2TestPayload(
    displays: [AppleDisplayInfo],
    screenFlags: UInt32 = 0,
    lengthIncludesPrefix: Bool = false
) -> Data {
    let headerSize = 22
    let recordSize = 56
    var data = Data(
        repeating: 0,
        count: headerSize + displays.count * recordSize)

    func storeUInt16(_ value: UInt16, at offset: Int) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xff)
    }
    func storeUInt32(_ value: UInt32, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    let encodedLength = lengthIncludesPrefix ? data.count : data.count - 2
    storeUInt16(UInt16(encodedLength), at: 0)
    storeUInt16(5, at: 2)
    storeUInt32(screenFlags, at: 16)
    storeUInt16(UInt16(displays.count), at: 20)

    for (index, display) in displays.enumerated() {
        let originX = Int(display.originX)
        let originY = Int(display.originY)
        let maxX = originX + Int(display.width)
        let maxY = originY + Int(display.height)
        precondition(originX >= 0 && originY >= 0)
        precondition(maxX <= Int(UInt16.max) && maxY <= Int(UInt16.max))

        let recordOffset = headerSize + index * recordSize
        storeUInt32(display.displayIndex, at: recordOffset + 16)
        let boundsOffset = recordOffset + 28
        storeUInt16(UInt16(originY), at: boundsOffset)
        storeUInt16(UInt16(originX), at: boundsOffset + 2)
        storeUInt16(UInt16(maxY), at: boundsOffset + 4)
        storeUInt16(UInt16(maxX), at: boundsOffset + 6)
        storeUInt32(display.flags, at: recordOffset + 36)
    }
    return data
}

func appleMediaDisplayInfo2ControlTestPayload(
    displays: [AppleDisplayInfo],
    screenFlags: UInt32 = 0
) -> Data {
    let body = appleDisplayInfo2TestPayload(
        displays: displays,
        screenFlags: screenFlags,
        lengthIncludesPrefix: true)
    var payload = Data(repeating: 0, count: 16)
    payload[0] = 0x20
    payload[14] = 0x04
    payload[15] = 0x51
    payload.append(body)
    return payload
}
