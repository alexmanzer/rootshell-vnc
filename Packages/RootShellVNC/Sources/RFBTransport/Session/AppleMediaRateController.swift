import Foundation

/// Receiver-side capacity estimator for Apple's adaptive HEVC stream.
///
/// The previous implementation advertised its requested target as measured
/// bandwidth and then sent the same value as a hard TMMBR ceiling. That feedback
/// loop could never discover spare capacity quickly. This controller keeps a
/// capacity estimate separate from observed screen activity and decreases only
/// for confirmed loss—not for idle screen content. It starts at the negotiated
/// wire ceiling: passive observation cannot discover unused capacity while the
/// sender is application-limited, and starting at an arbitrary low ceiling
/// creates a self-fulfilling low-quality stream. Confirmed loss multiplicatively
/// reduces the estimate; clean intervals recover it toward the ceiling. RCTL is
/// advisory feedback; this class does not impose a second TMMBR ceiling.
final class AppleMediaRateController {
    private struct Config {
        let minimumCapacity: Double
        let maximumCapacity: Double
        let initialCapacity: Double
        let targetUtilization: Double
        let rampFactor: Double
        let decreaseFactor: Double
        let headroomFactor: Double
        let rampInterval: Double
        let cooldown: Double
        let throughputWindow: Double
        let updateInterval: Double

        static func fromEnvironment(maximumCapacity: Double) -> Config {
            let env = ProcessInfo.processInfo.environment
            func value(_ key: String, default fallback: Double) -> Double {
                env[key].flatMap(Double.init) ?? fallback
            }
            let minimum = value("ROOTSHELL_VNC_RC_MIN_KBPS", default: 4_000) * 1_000
            let maximum = value(
                "ROOTSHELL_VNC_RC_MAX_KBPS",
                default: maximumCapacity / 1_000) * 1_000
            let initial = value(
                "ROOTSHELL_VNC_RC_INIT_KBPS",
                default: maximum / 1_000) * 1_000
            return Config(
                minimumCapacity: minimum,
                maximumCapacity: max(minimum, maximum),
                initialCapacity: min(maximum, max(minimum, initial)),
                // The negotiated Viceroy profile already owns its codec
                // headroom. Applying another 90% factor here kept every TMMBR
                // request below the profile's real 20/40/60/75/100 Mbps tiers.
                targetUtilization: value("ROOTSHELL_VNC_RC_TARGET_UTILIZATION", default: 1.0),
                rampFactor: value("ROOTSHELL_VNC_RC_RAMP_FACTOR", default: 1.50),
                decreaseFactor: value("ROOTSHELL_VNC_RC_DECREASE_FACTOR", default: 0.80),
                headroomFactor: value("ROOTSHELL_VNC_RC_HEADROOM", default: 1.25),
                rampInterval: value("ROOTSHELL_VNC_RC_RAMP_INTERVAL", default: 0.50),
                cooldown: value("ROOTSHELL_VNC_RC_COOLDOWN", default: 2.0),
                throughputWindow: value("ROOTSHELL_VNC_RC_TPUT_WINDOW", default: 0.50),
                updateInterval: value("ROOTSHELL_VNC_RC_UPDATE_INTERVAL", default: 0.05))
        }
    }

    private struct ByteSample {
        let time: Double
        let bytes: Int
    }

    private let config: Config
    private var byteSamples: [ByteSample] = []
    private var byteSampleHead = 0
    private var byteSampleTotal = 0
    private var capacityEstimate: Double
    private var target: Double
    private var lastUpdate: Double?
    private var lastRamp: Double?
    private var cooldownUntil: Double = 0
    private var confirmedLossPending = false
    private var intervalReceived = 0
    private var intervalLost = 0

    init(maxTargetBps: Double) {
        config = Config.fromEnvironment(maximumCapacity: maxTargetBps)
        capacityEstimate = config.initialCapacity
        target = config.initialCapacity * config.targetUtilization
    }

    var targetBitrateBps: UInt32 {
        UInt32(clamping: Int64(target.rounded()))
    }

    var bandwidthEstimateBps: UInt32 {
        UInt32(clamping: Int64(capacityEstimate.rounded()))
    }

    /// OWRD is deliberately unavailable for this stream. Captured screen-share
    /// RTP timestamps are constant/undocumented, so reporting zero is safer than
    /// manufacturing queue growth or a fake nominal delay.
    var owrdSeconds: Double { 0 }

    func onVideoPacket(
        ssrc: UInt32,
        rtpTimestamp: UInt32,
        bytes: Int,
        endOfFrame: Bool = false,
        now: Double
    ) {
        _ = ssrc
        _ = rtpTimestamp
        _ = endOfFrame
        guard bytes > 0 else { return }
        byteSamples.append(ByteSample(time: now, bytes: bytes))
        byteSampleTotal += bytes
        intervalReceived += 1
        trimSamples(now: now)
    }

    func onConfirmedLoss(count: Int, now: Double) {
        guard count > 0 else { return }
        intervalLost += count
        confirmedLossPending = true
        cooldownUntil = max(cooldownUntil, now + config.cooldown)
    }

    func throughputBps(now: Double) -> Double {
        trimSamples(now: now)
        guard byteSampleHead < byteSamples.count,
              let last = byteSamples.last else { return 0 }
        let first = byteSamples[byteSampleHead]
        let span = max(0.05, min(config.throughputWindow, last.time - first.time + 0.05))
        return Double(byteSampleTotal) * 8 / span
    }

    @discardableResult
    func update(now: Double) -> UInt32 {
        if lastUpdate == nil {
            lastUpdate = now
            lastRamp = now
            return targetBitrateBps
        }
        guard now - (lastUpdate ?? now) >= config.updateInterval else {
            return targetBitrateBps
        }
        lastUpdate = now

        let observed = throughputBps(now: now)
        let expected = intervalReceived + intervalLost
        let lossFraction = expected > 0 ? Double(intervalLost) / Double(expected) : 0
        let congested = confirmedLossPending || lossFraction > 0.01

        if congested {
            // Screen content can be nearly idle, so observed bitrate is not a
            // link-capacity ceiling. One unrecovered packet gets one bounded
            // reduction; it must not collapse a 20 Mbps session to the 4 Mbps
            // floor merely because the desktop was static at that instant.
            capacityEstimate *= config.decreaseFactor
            cooldownUntil = max(cooldownUntil, now + config.cooldown)
            confirmedLossPending = false
            lastRamp = now
        } else if now >= cooldownUntil,
                  now - (lastRamp ?? now) >= config.rampInterval {
            // An idle or low-complexity desktop is application-limited, not
            // evidence of a low-capacity link. Recover toward the advertised
            // ceiling even when observed bitrate is below the current estimate.
            let probed = max(
                capacityEstimate * config.rampFactor,
                observed * config.headroomFactor)
            capacityEstimate = min(config.maximumCapacity, probed)
            lastRamp = now
        }

        capacityEstimate = min(
            config.maximumCapacity,
            max(config.minimumCapacity, capacityEstimate))
        target = min(
            config.maximumCapacity,
            max(config.minimumCapacity, capacityEstimate * config.targetUtilization))
        intervalReceived = 0
        intervalLost = 0
        return targetBitrateBps
    }

    private func trimSamples(now: Double) {
        while byteSampleHead < byteSamples.count,
              now - byteSamples[byteSampleHead].time > config.throughputWindow {
            byteSampleTotal -= byteSamples[byteSampleHead].bytes
            byteSampleHead += 1
        }
        // Array.removeFirst is O(n) and was previously called per RTP packet.
        // Compact only occasionally so steady-state ingest stays O(1).
        if byteSampleHead >= 1_024,
           byteSampleHead * 2 >= byteSamples.count {
            byteSamples.removeFirst(byteSampleHead)
            byteSampleHead = 0
        }
    }
}
