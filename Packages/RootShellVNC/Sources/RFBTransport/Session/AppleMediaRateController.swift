import Foundation
import RFBProtocol

/// Receiver-side rate controller for the Apple high-performance (HEVC-over-UDP)
/// video path. It estimates a target bitrate from the delay trend of the
/// received stream and its packet loss, and that target is what the client
/// requests from the server as a temporary maximum bitrate (TMMBR) and reports
/// as its bandwidth estimate.
///
/// The estimator is delay-based: it tracks the one-way relative delay (OWRD) —
/// how far recent arrival timing has drifted from the send cadence — and its
/// trend (NOWRD). A rising trend means a queue is building (over-use), so the
/// target ramps down; a low, flat trend with headroom below recent throughput
/// means there is room to grow, so it ramps up. Starting low and only ramping up
/// to what recent throughput supports is what keeps an idle screen at a low
/// bitrate while still reaching full rate under motion.
///
/// Thresholds and windows are not fixed constants on the wire, so we use sensible
/// defaults, each overridable via environment variables for tuning.
final class AppleMediaRateController {

    // MARK: - Tunables

    private struct Config {
        var owrdThreshold: Double          // s; OWRD above this counts as congestion
        var nowrdThreshold: Double         // s; projected OWRD change over the window
        var nowrdAccThreshold: Double      // s; integrated trend
        var lossThreshold: Double          // fraction; loss above this is a loss event
        var wallFactor: Double             // ramp-up ceiling = wallFactor × recent throughput
        var minTarget: Double              // bps
        var maxTarget: Double              // bps
        var initialTarget: Double          // bps
        var crossover: Double              // bps; multiplicative above, additive below
        var rampBase: Double               // multiplicative ramp factor per second
        var additivePerSec: Double         // bps/s additive ramp below crossover
        var nowrdWindow: Double            // s; window for the NOWRD slope
        var throughputWindow: Double       // s; window for the throughput estimate
        var updateInterval: Double         // s; minimum spacing between ramp updates

        static func fromEnvironment(maxTargetBps: Double) -> Config {
            let env = ProcessInfo.processInfo.environment
            func d(_ key: String, _ fallback: Double) -> Double {
                env[key].flatMap(Double.init) ?? fallback
            }
            return Config(
                owrdThreshold: d("ROOTSHELL_VNC_RC_OWRD_THR", 0.050),
                nowrdThreshold: d("ROOTSHELL_VNC_RC_NOWRD_THR", 0.010),
                nowrdAccThreshold: d("ROOTSHELL_VNC_RC_NOWRDACC_THR", 0.030),
                lossThreshold: d("ROOTSHELL_VNC_RC_LOSS_THR", 0.02),
                wallFactor: d("ROOTSHELL_VNC_RC_WALL_FACTOR", 1.5),
                minTarget: d("ROOTSHELL_VNC_RC_MIN_KBPS", 2_000) * 1000,
                maxTarget: d("ROOTSHELL_VNC_RC_MAX_KBPS", maxTargetBps / 1000) * 1000,
                initialTarget: d("ROOTSHELL_VNC_RC_INIT_KBPS", 6_000) * 1000,
                crossover: 228_000,
                rampBase: 1.159,
                additivePerSec: 32_000,
                nowrdWindow: d("ROOTSHELL_VNC_RC_NOWRD_WINDOW", 1.0),
                throughputWindow: d("ROOTSHELL_VNC_RC_TPUT_WINDOW", 0.5),
                updateInterval: d("ROOTSHELL_VNC_RC_UPDATE_INTERVAL", 0.05)
            )
        }
    }

    private let config: Config

    /// RTP timestamp clock rate for the video payload (90 kHz is standard video).
    private let clockRate: Double = 90_000

    // MARK: - Per-source OWRD state

    private struct SourceDelay {
        var sendRefTicks: UInt32 = 0
        var recvRef: Double = 0
        var shortLag: Double = 0
        var longLag: Double = 0
        var haveRef = false
    }
    private var sources: [UInt32: SourceDelay] = [:]

    /// Aggregate OWRD (max across sources — congestion affects the shared path).
    private var owrd: Double = 0

    // MARK: - NOWRD trend

    private struct OWRDSample { let t: Double; let owrd: Double }
    private var owrdRing: [OWRDSample] = []
    private var nowrd: Double = 0
    private var nowrdAcc: Double = 0
    private var lastOwrdZeroSince: Double = 0

    // MARK: - Throughput + loss

    private struct ByteSample { let t: Double; let bytes: Int }
    private var byteRing: [ByteSample] = []
    private var lossReceived: Int = 0
    private var lossLost: Int = 0

    // MARK: - Target

    private(set) var target: Double
    private var lastUpdate: Double = 0
    private var started = false
    private let log = VNCLogger(category: "RateControl")
    private var lastCutLog: Double = 0

    init(maxTargetBps: Double) {
        self.config = Config.fromEnvironment(maxTargetBps: maxTargetBps)
        self.target = config.initialTarget
    }

    /// Current target bitrate to advertise (bps), clamped to the configured range.
    var targetBitrateBps: UInt32 {
        UInt32(min(config.maxTarget, max(config.minTarget, target)).rounded())
    }

    /// The measured aggregate one-way relative delay, in seconds (for RCTL owrd).
    var owrdSeconds: Double { owrd }

    /// Recent received throughput in bits/s (for diagnostics / RCTL BWE).
    func throughputBps(now: Double) -> Double {
        trimAndSum(now: now)
    }

    // MARK: - Ingest

    /// Feed one received video RTP packet.
    func onVideoPacket(ssrc: UInt32, rtpTimestamp: UInt32, bytes: Int, lost: Bool, now: Double) {
        // The OWRD (delay-trend) estimator is DISABLED for this protocol.
        // It needs send timestamps on a known clock (90 kHz) to compute the
        // send cadence; Apple's screen-share video stamps timestamps as 0 at
        // startup and then on some other, undocumented scale. Either way the
        // computed "send delta" is a fraction of real time, so lag ≈ elapsed
        // wall-clock, OWRD climbs ~0.7 s per second (measured live, zero
        // loss), and the target rams down to minTarget (2 Mbps) forever —
        // rendering everything as low-bitrate macroblock soup. Packet loss is
        // the remaining (and sufficient) congestion signal.
        // updateDelayEstimate(ssrc: ssrc, rtpTimestamp: rtpTimestamp, now: now)

        byteRing.append(ByteSample(t: now, bytes: bytes))
        lossReceived += 1
        if lost { lossLost += 1 }
    }

    private func updateDelayEstimate(ssrc: UInt32, rtpTimestamp: UInt32, now: Double) {
        // OWRD per source (each SSRC has its own RTP timestamp base).
        var src = sources[ssrc] ?? SourceDelay()
        if !src.haveRef {
            src.sendRefTicks = rtpTimestamp
            src.recvRef = now
            src.haveRef = true
            sources[ssrc] = src
        } else {
            // Apple's screen-share video does NOT advance the RTP timestamp —
            // every packet of a source carries the same constant (often 0).
            // With no send cadence, `lag = recvDelta - 0` just measures elapsed
            // wall-clock time: it reads as an ever-growing queue → permanent
            // "over-use" → the target decays to minTarget (2 Mbps) and TMMBR/
            // RCTL order the server to crush the encode. That was the constant
            // low-bitrate "macroblock soup". A delay sample is only meaningful
            // when the send timestamp has ADVANCED since the reference; skip
            // everything else (constant, duplicate-frame, or backward stamps).
            let deltaTicks = rtpTimestamp &- src.sendRefTicks
            guard deltaTicks != 0, deltaTicks < 0x8000_0000 else { return }
            let sendDelta = Double(deltaTicks) / clockRate
            let recvDelta = now - src.recvRef
            let lag = recvDelta - sendDelta
            // Discard spurious samples (reorder / clock glitch).
            if abs(lag - src.shortLag) <= 30 {
                src.shortLag = 0.9 * src.shortLag + 0.1 * lag
                src.longLag = 0.9999 * src.longLag + 0.0001 * lag
                sources[ssrc] = src
                let srcOwrd = max(0, src.shortLag - src.longLag)
                if srcOwrd < 8 {          // ignore >= 8 s outliers
                    owrd = max(owrd, srcOwrd)
                }
            } else {
                sources[ssrc] = src
            }
        }
    }

    // MARK: - Update

    /// Run the ramp logic. Returns the (possibly changed) target bitrate in bps.
    /// Throttled to `updateInterval`; call freely (e.g. per packet).
    @discardableResult
    func update(now: Double) -> UInt32 {
        if !started { started = true; lastUpdate = now; lastOwrdZeroSince = now }
        let dt = now - lastUpdate
        guard dt >= config.updateInterval else { return targetBitrateBps }
        lastUpdate = now

        // Push current aggregate OWRD into the trend ring and recompute NOWRD.
        owrdRing.append(OWRDSample(t: now, owrd: owrd))
        while let first = owrdRing.first, now - first.t > config.nowrdWindow {
            owrdRing.removeFirst()
        }
        nowrd = slopeOverWindow() * config.nowrdWindow
        nowrdAcc = max(0, nowrdAcc + nowrd * dt / max(0.001, config.nowrdWindow))
        // Reset the integrator once the queue has been drained for a while.
        if owrd < 0.001 {
            if now - lastOwrdZeroSince > config.nowrdWindow { nowrdAcc = 0 }
        } else {
            lastOwrdZeroSince = now
        }

        // Loss over this interval.
        let expected = lossReceived + lossLost
        let lossFrac = expected > 0 ? Double(lossLost) / Double(expected) : 0
        lossReceived = 0; lossLost = 0

        let throughput = trimAndSum(now: now)          // bps
        let overuse = owrd > config.owrdThreshold
            || nowrd > config.nowrdThreshold
            || nowrdAcc > config.nowrdAccThreshold
            || lossFrac > config.lossThreshold
        let belowWall = target < throughput * config.wallFactor || throughput <= 0

        if overuse {
            // Ramp down; cut harder on a loss event.
            if now - lastCutLog > 1.0 {
                lastCutLog = now
                log.debug("RC cut: owrd=\(String(format: "%.4f", self.owrd)) nowrd=\(String(format: "%.4f", self.nowrd)) acc=\(String(format: "%.4f", self.nowrdAcc)) loss=\(String(format: "%.4f", lossFrac)) tput=\(Int(throughput)) target=\(Int(self.target))")
            }
            let sf = lossFrac > config.lossThreshold ? 2.0 : 1.0
            if target > config.crossover {
                target = target / pow(config.rampBase, sf)
            } else {
                let step: Double = target < 50_000 ? 8_000 : (target < 132_000 ? 16_000 : 32_000)
                target -= step * sf
            }
            // OWRD decays after congestion clears; let the max reading relax.
            owrd *= 0.5
        } else if belowWall {
            // Under-use with headroom → ramp up.
            if target > config.crossover {
                target = target * pow(config.rampBase, dt)
            } else {
                target += config.additivePerSec * dt
            }
            owrd *= 0.8
        } else {
            // Stable / at the bandwidth wall → hold. Let OWRD relax slowly.
            owrd *= 0.9
        }

        target = min(config.maxTarget, max(config.minTarget, target))
        return targetBitrateBps
    }

    // MARK: - Helpers

    private func trimAndSum(now: Double) -> Double {
        while let first = byteRing.first, now - first.t > config.throughputWindow {
            byteRing.removeFirst()
        }
        guard let first = byteRing.first else { return 0 }
        let span = max(0.01, now - first.t)
        let total = byteRing.reduce(0) { $0 + $1.bytes }
        return Double(total) * 8 / span
    }

    /// Difference-of-centroids slope of OWRD over the ring (ΔOWRD/Δt).
    private func slopeOverWindow() -> Double {
        guard owrdRing.count >= 4 else { return 0 }
        let mid = owrdRing.count / 2
        let lower = owrdRing[..<mid]
        let upper = owrdRing[mid...]
        let lowerT = lower.reduce(0.0) { $0 + $1.t } / Double(lower.count)
        let upperT = upper.reduce(0.0) { $0 + $1.t } / Double(upper.count)
        let lowerO = lower.reduce(0.0) { $0 + $1.owrd } / Double(lower.count)
        let upperO = upper.reduce(0.0) { $0 + $1.owrd } / Double(upper.count)
        let dt = upperT - lowerT
        guard dt > 0.001 else { return 0 }
        return (upperO - lowerO) / dt
    }
}

/// RFC 5104 TMMBR MxTBR encoding: exp[6] : mantissa[17] : overhead[9].
/// `exp` is the smallest shift making `bps >> exp` fit in 17 bits.
func appleMediaTMMBRMxTBR(bps: UInt32, overhead: UInt32 = 40) -> UInt32 {
    var exp: UInt32 = 0
    if bps >= (1 << 17) {
        // exp = bitlength(bps >> 17): the smallest shift making bps>>exp < 2^17.
        var n = bps >> 17
        while n > 0 { exp += 1; n >>= 1 }
    }
    let mantissa = (bps >> exp) & 0x1_FFFF
    return (exp << 26) | (mantissa << 9) | (overhead & 0x1FF)
}
