import Foundation

/// Receiver-side capacity estimator for Apple's adaptive HEVC stream.
///
/// The previous implementation advertised its requested target as measured
/// bandwidth. That feedback loop could never discover spare capacity quickly.
/// This controller keeps a
/// capacity estimate separate from observed screen activity. Confirmed loss or
/// measured receiver queueing multiplicatively reduces the estimate. Recovery
/// is deliberately utilization-gated: an idle desktop is not evidence that a
/// link can sustain a higher motion bitrate. RCTL is advisory feedback; this
/// class does not impose a second congestion controller.
final class AppleMediaRateController {
    /// AVConference's RemoteDesktopScreenSharing settings return 20 Mbps from
    /// `minBandwidth`; captured negotiation also contains 40/60 Mbps screen
    /// maxima. Receiver feedback may still report a lower path estimate, so the
    /// controller must not clamp its RCTL value to the media arbitration range.
    static let nativeScreenMinimumBitrateBps: Double = 20_000_000
    static let nativeScreenMaximumBitrateBps: Double = 40_000_000

    private struct Config {
        let minimumCapacity: Double
        let maximumCapacity: Double
        let initialCapacity: Double
        let targetUtilization: Double
        let rampFactor: Double
        let startupRampFactor: Double
        let decreaseFactor: Double
        let utilizationThreshold: Double
        let headroomFactor: Double
        let rampInterval: Double
        let startupRampInterval: Double
        let cooldown: Double
        let backoffInterval: Double
        let queueDelayThreshold: Double
        let throughputWindow: Double
        let updateInterval: Double

        static func fromEnvironment(
            maximumCapacity: Double,
            defaultInitialCapacity: Double?
        ) -> Config {
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
                default: (defaultInitialCapacity ?? maximum) / 1_000) * 1_000
            return Config(
                minimumCapacity: minimum,
                maximumCapacity: max(minimum, maximum),
                initialCapacity: min(maximum, max(minimum, initial)),
                // The negotiated Viceroy profile already owns its codec
                // headroom. Applying another factor here kept feedback below
                // the profile's real 20/40/60/75/100 Mbps tiers.
                targetUtilization: value("ROOTSHELL_VNC_RC_TARGET_UTILIZATION", default: 1.0),
                // Conservative AIMD: native VCRC's low-latency controller logs
                // exponential congestion backoff and continuous recovery. A
                // 10% probe avoids our former 32 -> 40 Mbps one-step pulse.
                rampFactor: value("ROOTSHELL_VNC_RC_RAMP_FACTOR", default: 1.10),
                // Before the first congestion signal, quickly test beyond the
                // route prior. This lets excellent 5G/Wi-Fi links reach full
                // quality without treating their radio class as a cap.
                startupRampFactor: value(
                    "ROOTSHELL_VNC_RC_STARTUP_RAMP_FACTOR",
                    default: 1.35),
                decreaseFactor: value("ROOTSHELL_VNC_RC_DECREASE_FACTOR", default: 0.75),
                utilizationThreshold: value(
                    "ROOTSHELL_VNC_RC_UTILIZATION_THRESHOLD",
                    default: 0.80),
                headroomFactor: value("ROOTSHELL_VNC_RC_HEADROOM", default: 1.10),
                rampInterval: value("ROOTSHELL_VNC_RC_RAMP_INTERVAL", default: 1.0),
                startupRampInterval: value(
                    "ROOTSHELL_VNC_RC_STARTUP_RAMP_INTERVAL",
                    default: 0.5),
                cooldown: value("ROOTSHELL_VNC_RC_COOLDOWN", default: 5.0),
                backoffInterval: value("ROOTSHELL_VNC_RC_BACKOFF_INTERVAL", default: 0.25),
                // One 60 fps frame period of ingress queueing means the viewer
                // is already rendering stale content and must reduce pressure.
                queueDelayThreshold: value(
                    "ROOTSHELL_VNC_RC_QUEUE_DELAY_MS",
                    default: 1000.0 / 60.0) / 1_000,
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
    private var lastBackoff: Double?
    private var hasExperiencedCongestion = false
    private var lastCongestionTime: Double?
    private var confirmedLossPending = false
    private var intervalReceived = 0
    private var intervalLost = 0
    private var intervalMaximumQueueDelay = 0.0
    private(set) var lastMaximumQueueDelaySeconds = 0.0
    private(set) var peakQueueDelaySeconds = 0.0

    init(maxTargetBps: Double, initialTargetBps: Double? = nil) {
        config = Config.fromEnvironment(
            maximumCapacity: maxTargetBps,
            defaultInitialCapacity: initialTargetBps)
        capacityEstimate = config.initialCapacity
        target = capacityEstimate * config.targetUtilization
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
        queueDelaySeconds: Double = 0,
        now: Double
    ) {
        _ = ssrc
        _ = rtpTimestamp
        _ = endOfFrame
        guard bytes > 0 else { return }
        byteSamples.append(ByteSample(time: now, bytes: bytes))
        byteSampleTotal += bytes
        intervalReceived += 1
        let queueDelay = max(0, queueDelaySeconds)
        intervalMaximumQueueDelay = max(intervalMaximumQueueDelay, queueDelay)
        peakQueueDelaySeconds = max(peakQueueDelaySeconds, queueDelay)
        trimSamples(now: now)
    }

    func onConfirmedLoss(count: Int, now: Double) {
        guard count > 0 else { return }
        intervalLost += count
        confirmedLossPending = true
        lastCongestionTime = now
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
        let queueCongested = intervalMaximumQueueDelay >= config.queueDelayThreshold
        let congested = confirmedLossPending || lossFraction > 0.01 || queueCongested
        let mayBackoff = lastBackoff.map { now - $0 >= config.backoffInterval } ?? true

        if congested, mayBackoff {
            // Loss severity strengthens a bounded exponential reduction. A
            // lone missing packet gets ordinary AIMD backoff; losing a material
            // portion of a frame can halve the estimate in one response.
            let severityAdjustment = intervalLost > 1
                ? min(0.25, lossFraction)
                : 0
            let factor = max(0.50, config.decreaseFactor - severityAdjustment)
            capacityEstimate *= factor
            hasExperiencedCongestion = true
            lastCongestionTime = now
            cooldownUntil = max(cooldownUntil, now + config.cooldown)
            confirmedLossPending = false
            intervalLost = 0
            lastBackoff = now
            lastRamp = now
        } else if now >= cooldownUntil,
                  now - (lastRamp ?? now) >= (hasExperiencedCongestion
                    ? config.rampInterval
                    : config.startupRampInterval),
                  observed >= capacityEstimate * config.utilizationThreshold {
            // Probe only while active content is using most of the current
            // allowance. This prevents idle periods from restoring 40 Mbps and
            // recreating the same burst-loss cycle on the next window move.
            let nextProbe = capacityEstimate * (hasExperiencedCongestion
                ? config.rampFactor
                : config.startupRampFactor)
            let demand = max(capacityEstimate, observed * config.headroomFactor)
            capacityEstimate = min(config.maximumCapacity, nextProbe, demand)
            lastRamp = now
        }

        capacityEstimate = min(
            config.maximumCapacity,
            max(config.minimumCapacity, capacityEstimate))
        target = min(
            config.maximumCapacity,
            max(config.minimumCapacity, capacityEstimate * config.targetUtilization))

        intervalReceived = 0
        if !confirmedLossPending { intervalLost = 0 }
        lastMaximumQueueDelaySeconds = intervalMaximumQueueDelay
        intervalMaximumQueueDelay = 0
        return targetBitrateBps
    }

    /// A full intra picture is a large burst. Request it only after the sender
    /// has converged near our advertised receive rate and the path has remained
    /// gap-free long enough for queued traffic to drain.
    func isReadyForKeyframeRecovery(now: Double) -> Bool {
        let observed = throughputBps(now: now)
        guard observed <= target * 1.25 else { return false }
        guard let lastCongestionTime else { return true }
        return now - lastCongestionTime >= 0.75
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
