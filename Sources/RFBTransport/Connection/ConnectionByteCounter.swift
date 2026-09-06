import Foundation
import NIOCore

/// Socket payload bytes, including TLS records but excluding IP/TCP headers.
public struct ConnectionByteCounts: Sendable, Equatable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public init() {}
}

/// Crosses only between one NIO event loop and the snapshot caller; all state is locked.
final class ConnectionByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = ConnectionByteCounts()

    func receive(_ count: Int) { lock.withLock { counts.received &+= UInt64(max(0, count)) } }
    func send(_ count: Int) { lock.withLock { counts.sent &+= UInt64(max(0, count)) } }
    func snapshot() -> ConnectionByteCounts { lock.withLock { counts } }
}

final class SocketByteCountingHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    private let counter: ConnectionByteCounter

    init(counter: ConnectionByteCounter) { self.counter = counter }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        counter.receive(unwrapInboundIn(data).readableBytes)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let count = unwrapOutboundIn(data).readableBytes
        let completion = promise ?? context.eventLoop.makePromise(of: Void.self)
        completion.futureResult.whenSuccess { [counter] in counter.send(count) }
        context.write(data, promise: completion)
    }
}
