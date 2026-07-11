import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import RFBProtocol
import os

/// Errors that can occur during HEVC decoding.
public enum HEVCDecoderError: Error, Sendable, LocalizedError {
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case invalidNALUnit(String)
    case noFormatDescription

    public var errorDescription: String? {
        switch self {
        case .formatDescriptionCreationFailed(let status):
            return "Failed to create HEVC format description: OSStatus \(status)"
        case .sessionCreationFailed(let status):
            return "Failed to create decompression session: OSStatus \(status)"
        case .sampleBufferCreationFailed(let status):
            return "Failed to create sample buffer: OSStatus \(status)"
        case .blockBufferCreationFailed(let status):
            return "Failed to create block buffer: OSStatus \(status)"
        case .decodeFailed(let status):
            return "HEVC decode failed: OSStatus \(status)"
        case .invalidNALUnit(let detail):
            return "Invalid NAL unit: \(detail)"
        case .noFormatDescription:
            return "No format description available; feed SPS/PPS/VPS first"
        }
    }
}

/// Metadata that identifies one band inside Apple's compound HEVC screen
/// frame. The private VCP wrapper supplies these same keys before handing a
/// sample to the underlying VideoToolbox decoder.
public struct HEVCTileMetadata: Sendable, Equatable {
    public let tileID: UInt32
    public let tileOrder: UInt32
    public let decodingOrderBase: UInt32

    public init(tileID: UInt32, tileOrder: UInt32, decodingOrderBase: UInt32) {
        self.tileID = tileID
        self.tileOrder = tileOrder
        self.decodingOrderBase = decodingOrderBase
    }

    var sampleAttachments: [String: NSNumber] {
        [
            "TileID": NSNumber(value: tileID),
            "TileOrder": NSNumber(value: tileOrder),
            "decodingOrderBase": NSNumber(value: decodingOrderBase),
        ]
    }
}

/// Decodes HEVC (H.265) NAL units using VideoToolbox hardware decoder.
public final class HEVCDecoder: @unchecked Sendable {

    /// Delivers a decoded frame with its presentation time and the per-frame
    /// tag passed to `decode(...)` (used to route each frame to its screen band).
    public typealias FrameCallback = @Sendable (CVPixelBuffer, CMTime, UInt32) -> Void

    /// Reports an asynchronous VideoToolbox failure for the submitted frame.
    /// `VTDecompressionSessionDecodeFrame` can return success and report a
    /// missing-reference error only later through its output callback, so this
    /// cannot be represented by `decode(...)` throwing.
    public typealias FailureCallback = @Sendable (OSStatus, CMTime, UInt32) -> Void

    private struct CallbackBundle {
        let frame: FrameCallback
        let failure: FailureCallback?
    }

    // MARK: - Private state

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private let numberOfTiles: Int
    private let lock = NSLock()
    private var callbackStorage: UnsafeMutablePointer<CallbackBundle>?

    // MARK: - Init

    public init(
        numberOfTiles: Int = 1,
        frameCallback: @escaping FrameCallback,
        failureCallback: FailureCallback? = nil
    ) {
        self.numberOfTiles = max(1, numberOfTiles)
        // Allocate the callback trampoline storage once and keep it alive for
        // the decoder's whole lifetime. VideoToolbox may invoke the output
        // callback asynchronously *after* a session is invalidated (e.g. when a
        // new IDR's parameter sets force a session recreate). A single bundle
        // also gives the C callback a stable path for asynchronous failures.
        let storage = UnsafeMutablePointer<CallbackBundle>.allocate(capacity: 1)
        storage.initialize(to: CallbackBundle(
            frame: frameCallback,
            failure: failureCallback))
        self.callbackStorage = storage
    }

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        _freeCallbackStorage()
    }

    // MARK: - Format Description

    /// Update the format description from SPS/PPS NAL units.
    /// `vps` (Video Parameter Set) is optional but recommended for HEVC.
    public func updateFormatDescription(sps: Data, pps: Data, vps: Data?) throws {
        lock.lock()
        defer { lock.unlock() }

        try _updateFormatDescription(sps: sps, pps: pps, vps: vps)
    }

    private func _updateFormatDescription(sps: Data, pps: Data, vps: Data?) throws {
        let desc = try Self.makeFormatDescription(sps: sps, pps: pps, vps: vps)

        // Check if format changed; if so, recreate the decompression session
        let formatChanged = formatDescription == nil
            || !CMFormatDescriptionEqual(desc, otherFormatDescription: formatDescription!)

        formatDescription = desc

        if formatChanged {
            try _createDecompressionSession()
        }
    }

    /// Parse coded dimensions from public CoreMedia format-description APIs
    /// without creating a VideoToolbox session. The multi-tile receiver uses
    /// this during startup to derive how many horizontal bands are expected.
    public static func codedDimensions(
        sps: Data,
        pps: Data,
        vps: Data?
    ) throws -> CMVideoDimensions {
        let description = try makeFormatDescription(sps: sps, pps: pps, vps: vps)
        return CMVideoFormatDescriptionGetDimensions(description)
    }

    private static func makeFormatDescription(
        sps: Data,
        pps: Data,
        vps: Data?
    ) throws -> CMFormatDescription {
        // Build parameter set arrays for CMVideoFormatDescriptionCreateFromHEVCParameterSets
        var parameterSets: [Data] = []
        if let vps = vps {
            parameterSets.append(vps)
        }
        parameterSets.append(sps)
        parameterSets.append(pps)

        // Create format description from parameter sets
        var newFormatDescription: CMFormatDescription?

        let status: OSStatus = parameterSets.withContiguousUnsafeBuffers { bufferPointers in
            var sizes = bufferPointers.map { $0.count }
            var pointers = bufferPointers.map { $0.baseAddress! }

            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &newFormatDescription
            )
        }

        guard status == noErr, let desc = newFormatDescription else {
            throw HEVCDecoderError.formatDescriptionCreationFailed(status)
        }
        return desc
    }

    // MARK: - Session Management

    private func _freeCallbackStorage() {
        if let storage = callbackStorage {
            storage.deinitialize(count: 1)
            storage.deallocate()
            callbackStorage = nil
        }
    }

    private func _createDecompressionSession() throws {
        guard let formatDesc = formatDescription else {
            throw HEVCDecoderError.noFormatDescription
        }

        // Drain any in-flight async frames before invalidating, so no output
        // callback fires against a torn-down session. The callback storage is
        // stable for the decoder's lifetime and is deliberately NOT freed here.
        if let existing = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
            decompressionSession = nil
        }

        // Do NOT force a pixel format: requesting 32BGRA makes VideoToolbox run a
        // CPU (NEON) 4:4:4-YUV → BGRA color conversion on every frame
        // (vt_Copy_444vf_rgb_BGRA...), which dominated CPU. Let the decoder hand
        // back its native surface and let the GPU convert it when the CALayer is
        // composited — that's the zero-CPU display path. Only IOSurface backing
        // is required so the layer can reference the buffer without a copy.
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        // Create the output callback record
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: {
                (
                    decompressionOutputRefCon: UnsafeMutableRawPointer?,
                    sourceFrameRefCon: UnsafeMutableRawPointer?,
                    status: OSStatus,
                    infoFlags: VTDecodeInfoFlags,
                    imageBuffer: CVImageBuffer?,
                    presentationTimeStamp: CMTime,
                    presentationDuration: CMTime
                ) in
                let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: sourceFrameRefCon))
                guard let refCon = decompressionOutputRefCon else { return }
                let callbacks = refCon.assumingMemoryBound(to: CallbackBundle.self).pointee

                if status != noErr {
                    if ProcessInfo.processInfo.environment["ROOTSHELL_VNC_TRACE_DECODE"] == "1" {
                        print("VT callback: status=\(status) flags=\(infoFlags.rawValue) hasImage=\(imageBuffer != nil)")
                    }
                    callbacks.failure?(status, presentationTimeStamp, tag)
                    return
                }
                guard let pixelBuffer = imageBuffer else { return }

                callbacks.frame(pixelBuffer, presentationTimeStamp, tag)
            },
            decompressionOutputRefCon: nil
        )

        // Reuse the lifetime-stable callback storage allocated in init.
        outputCallback.decompressionOutputRefCon = callbackStorage.map(UnsafeMutableRawPointer.init)

        var session: VTDecompressionSession?
        let decoderSpecification: CFDictionary? = numberOfTiles > 1
            ? ["NumberOfTiles": numberOfTiles] as CFDictionary
            : nil
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: pixelBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let newSession = session else {
            throw HEVCDecoderError.sessionCreationFailed(status)
        }

        decompressionSession = newSession

        // Always report hardware vs software decode + the output format: if the
        // device can't hardware-decode this stream's chroma (e.g. 4:4:4 HEVC on
        // hardware that only supports 4:2:0), VideoToolbox silently falls back to
        // a CPU decoder — which is the single biggest CPU cost to look for.
        var raw: CFTypeRef?
        let s = VTSessionCopyProperty(
            newSession,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &raw)
        let hw = (s == noErr) ? (raw as? Bool) : nil
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        Logger(subsystem: "com.rootshell.vnc", category: "HEVCDecoder").notice(
            "VT session: \(dims.width, privacy: .public)x\(dims.height, privacy: .public) hardwareAccelerated=\(hw.map(String.init) ?? "unknown", privacy: .public)")
    }

    /// Whether the decoder can accept VCL NAL units (parameter sets seen and a
    /// decompression session exists).
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decompressionSession != nil && formatDescription != nil
    }

    /// Coded dimensions negotiated from the current parameter sets.
    public var formatDimensions: CMVideoDimensions? {
        lock.lock()
        defer { lock.unlock() }
        guard let formatDescription else { return nil }
        return CMVideoFormatDescriptionGetDimensions(formatDescription)
    }

    // MARK: - Decode

    /// Feed a complete HEVC NAL unit for decoding.
    /// The NAL unit should NOT include the start code prefix (0x00000001).
    /// The decoder will call frameCallback on its internal thread when a frame is ready.
    public func decode(
        nalUnit: Data,
        presentationTime: CMTime,
        frameTag: UInt32 = 0,
        tileMetadata: HEVCTileMetadata? = nil
    ) throws {
        try decode(
            nalUnits: [nalUnit],
            presentationTime: presentationTime,
            frameTag: frameTag,
            tileMetadata: tileMetadata)
    }

    /// Feed a complete HEVC access unit for decoding. `frameTag` is handed back
    /// verbatim in the frame callback (we use it to carry the source SSRC).
    /// Each NAL unit should NOT include a start code prefix.
    public func decode(
        nalUnits: [Data],
        presentationTime: CMTime,
        frameTag: UInt32 = 0,
        tileMetadata: HEVCTileMetadata? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let session = decompressionSession,
              let formatDesc = formatDescription else {
            throw HEVCDecoderError.noFormatDescription
        }
        guard !nalUnits.isEmpty else { return }

        // Convert NAL units to AVCC/HVCC sample format: each NAL is prefixed
        // with a 4-byte big-endian length.
        let totalPayloadSize = nalUnits.reduce(0) { $0 + 4 + $1.count }
        var avccData = Data(capacity: totalPayloadSize)
        for nalUnit in nalUnits {
            let nalLength = UInt32(nalUnit.count)
            withUnsafeBytes(of: nalLength.bigEndian) { avccData.append(contentsOf: $0) }
            avccData.append(nalUnit)
        }

        // Create CMBlockBuffer from the AVCC data
        let avccLength = avccData.count
        var blockBuffer: CMBlockBuffer?
        var status: OSStatus = avccData.withUnsafeBytes { rawBuffer in
            guard let srcBase = rawBuffer.baseAddress else {
                return OSStatus(-50) // paramErr
            }

            // Allocate a CMBlockBuffer with a copy of the data
            var buffer: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccLength,
                flags: 0,
                blockBufferOut: &buffer
            )
            guard createStatus == kCMBlockBufferNoErr, let buf = buffer else {
                return createStatus
            }

            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: srcBase,
                blockBuffer: buf,
                offsetIntoDestination: 0,
                dataLength: avccLength
            )
            guard replaceStatus == kCMBlockBufferNoErr else {
                return replaceStatus
            }

            blockBuffer = buf
            return noErr
        }

        guard status == noErr, let block = blockBuffer else {
            throw HEVCDecoderError.blockBufferCreationFailed(status)
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccLength
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            throw HEVCDecoderError.sampleBufferCreationFailed(status)
        }

        if let tileMetadata {
            for (key, value) in tileMetadata.sampleAttachments {
                CMSetAttachment(
                    sample,
                    key: key as CFString,
                    value: value,
                    attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
        }

        // Decode
        let decodeFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlagsOut = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: decodeFlags,
            frameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(frameTag)),
            infoFlagsOut: &infoFlagsOut
        )

        guard status == noErr else {
            throw HEVCDecoderError.decodeFailed(status)
        }
    }

    // MARK: - Flush / Reset

    /// Flush pending frames, waiting for all in-flight decodes to complete.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }

        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    /// Reset the decoder (e.g., on stream restart).
    /// Invalidates the current session; a new one will be created on next
    /// `updateFormatDescription` call.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        // Callback storage is intentionally retained for the decoder's lifetime
        // (freed only in deinit) so late async callbacks never hit freed memory.
        formatDescription = nil
    }
}

// MARK: - Array Helper

/// Helper extension for working with arrays of Data as contiguous unsafe buffer pointers.
private extension Array where Element == Data {
    /// Recursively nests `withUnsafeBytes` calls so all buffer pointers are
    /// simultaneously valid when `body` is invoked.
    func withContiguousUnsafeBuffers<R>(
        _ body: ([UnsafeBufferPointer<UInt8>]) -> R
    ) -> R {
        func recurse(index: Int, accumulated: [UnsafeBufferPointer<UInt8>]) -> R {
            if index == count {
                return body(accumulated)
            }
            return self[index].withUnsafeBytes { rawBuffer in
                let typed = rawBuffer.bindMemory(to: UInt8.self)
                var next = accumulated
                next.append(typed)
                return recurse(index: index + 1, accumulated: next)
            }
        }
        return recurse(index: 0, accumulated: [])
    }
}
