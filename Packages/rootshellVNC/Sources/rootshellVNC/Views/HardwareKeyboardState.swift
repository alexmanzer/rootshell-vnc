import Foundation

struct HardwareKeyboardTransition: Equatable, Sendable {
    let downFlag: Bool
    let keysym: UInt32
}

/// Platform-independent pressed-key bookkeeping. Physical HID usage is the
/// identity; the keysym chosen at key-down is retained until key-up.
struct HardwareKeyboardState: Sendable {
    private(set) var pressedKeysyms: [UInt32: UInt32] = [:]
    private var pressOrder: [UInt32] = []

    var isEmpty: Bool { pressedKeysyms.isEmpty }

    func contains(_ usage: UInt32) -> Bool {
        pressedKeysyms[usage] != nil
    }

    @discardableResult
    mutating func press(usage: UInt32, keysym: UInt32) -> HardwareKeyboardTransition? {
        guard usage != 0, keysym != 0, pressedKeysyms[usage] == nil else { return nil }
        pressedKeysyms[usage] = keysym
        pressOrder.append(usage)
        return HardwareKeyboardTransition(downFlag: true, keysym: keysym)
    }

    func repeatedPress(usage: UInt32) -> HardwareKeyboardTransition? {
        guard let keysym = pressedKeysyms[usage] else { return nil }
        return HardwareKeyboardTransition(downFlag: true, keysym: keysym)
    }

    mutating func release(usage: UInt32) -> HardwareKeyboardTransition? {
        guard let keysym = pressedKeysyms.removeValue(forKey: usage) else { return nil }
        pressOrder.removeAll { $0 == usage }
        return HardwareKeyboardTransition(downFlag: false, keysym: keysym)
    }

    mutating func releaseAll() -> [HardwareKeyboardTransition] {
        let transitions = pressOrder.reversed().compactMap { usage in
            pressedKeysyms[usage].map {
                HardwareKeyboardTransition(downFlag: false, keysym: $0)
            }
        }
        pressedKeysyms.removeAll(keepingCapacity: true)
        pressOrder.removeAll(keepingCapacity: true)
        return transitions
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class HardwareKeyboardController {
    private let keyboardHandler: KeyboardInputHandler
    private var state = HardwareKeyboardState()
    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    private var repeatingUsage: UInt32?

    init(keyboardHandler: KeyboardInputHandler) {
        self.keyboardHandler = keyboardHandler
    }

    var hasPressedKeys: Bool { !state.isEmpty }

    func contains(usage: UInt32) -> Bool {
        state.contains(usage)
    }

    @discardableResult
    func press(usage: UInt32, keysym: UInt32) -> Bool {
        guard let transition = state.press(usage: usage, keysym: keysym) else {
            // UIKit and UIKeyCommand can both report OS repeat callbacks. The
            // controller owns repeat timing, so duplicate begins are consumed.
            return state.contains(usage)
        }
        send(transition)
        if Self.isRepeatable(usage) {
            startRepeat(for: usage)
        }
        return true
    }

    @discardableResult
    func release(usage: UInt32) -> Bool {
        guard let transition = state.release(usage: usage) else { return false }
        if repeatingUsage == usage { stopRepeat() }
        send(transition)
        return true
    }

    func releaseAll() {
        stopRepeat()
        state.releaseAll().forEach(send)
    }

    private func startRepeat(for usage: UInt32) {
        stopRepeat()
        repeatingUsage = usage
        let timer = Timer(timeInterval: 0.225, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.repeatingUsage == usage else { return }
                self.emitRepeat(for: usage)
                let repeating = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.emitRepeat(for: usage) }
                }
                self.repeatTimer = repeating
                RunLoop.main.add(repeating, forMode: .common)
            }
        }
        delayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emitRepeat(for usage: UInt32) {
        guard repeatingUsage == usage,
              let transition = state.repeatedPress(usage: usage) else {
            stopRepeat()
            return
        }
        send(transition)
    }

    private func stopRepeat() {
        delayTimer?.invalidate()
        delayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingUsage = nil
    }

    private func send(_ transition: HardwareKeyboardTransition) {
        keyboardHandler.handleKeysym(
            downFlag: transition.downFlag,
            keysym: transition.keysym)
    }

    private static func isRepeatable(_ usage: UInt32) -> Bool {
        switch usage {
        case 0x39, 0xE0...0xE7: return false
        default: return true
        }
    }
}
#endif
