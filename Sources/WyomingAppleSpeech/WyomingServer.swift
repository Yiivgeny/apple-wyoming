import AppleSpeech
import Darwin
import Foundation
import NIOCore
import NIOPosix
import OSLog
import WakeWord
import WyomingProtocol

public final class WyomingServer: @unchecked Sendable {
    private let configuration: ServerConfiguration
    private let voices = VoiceRegistry()
    private lazy var tts = AppleTTSEngine(
        voices: voices,
        poolSize: configuration.maxTTSSessions
    )
    private lazy var connectionSlots = SlotLimiter(limit: configuration.maxConnections)
    private lazy var ttsSlots = SlotLimiter(limit: configuration.maxTTSSessions)
    private lazy var sttSlots = SlotLimiter(limit: configuration.maxSTTSessions)
    private let wakeWord: WakeWordEngine
    private let logger = Logger(subsystem: "local.wyoming.apple-speech", category: "server")

    public init(configuration: ServerConfiguration) throws {
        self.configuration = configuration
        wakeWord = try WakeWordEngine()
    }

    public func run() async throws {
        try await prewarmSpeechEngines()

        let eventLoops = MultiThreadedEventLoopGroup(
            numberOfThreads: max(2, min(System.coreCount, 8))
        )
        let bootstrap = ServerBootstrap(group: eventLoops)
            .serverChannelOption(.backlog, value: 128)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)

        let server = try await bootstrap.bind(
            host: configuration.host,
            port: configuration.port
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    IdleStateHandler(allTimeout: .seconds(Int64(self.configuration.idleTimeoutSeconds)))
                )
                try channel.pipeline.syncOperations.addHandler(CloseOnIdleHandler())
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(WyomingDecoder()))
                try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(WyomingEncoder()))
                return try NIOAsyncChannel<WyomingEvent, WyomingEvent>(
                    wrappingChannelSynchronously: channel
                )
            }
        }

        let bonjour = configuration.publishBonjour ? BonjourPublisher(port: configuration.port) : nil
        bonjour?.start()
        let address = server.channel.localAddress.map(String.init(describing:)) ?? "unknown"
        let mdnsEnabled = configuration.publishBonjour
        logger.info("listening=\(address, privacy: .public) mdns=\(mdnsEnabled)")

        let acceptTask = Task<Void, Error> {
            try await server.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await child in inbound {
                        group.addTask { [self] in
                            await handle(child)
                        }
                    }
                }
            }
        }

        let trap = SignalTrap()
        let caughtSignal = await trap.wait()
        logger.info("shutdown signal=\(caughtSignal)")
        bonjour?.stop()
        try? await server.channel.close()
        acceptTask.cancel()
        _ = try? await acceptTask.value
        try await eventLoops.shutdownGracefully()
    }

    private func prewarmSpeechEngines() async throws {
        try await wakeWord.prewarm()
        let wakeModels = WakeWordEngine.modelNames.joined(separator: ",")
        logger.info("wake_prewarm=ready models=\(wakeModels, privacy: .public) provider=coreml")

        do {
            try await STTAssets.prewarm(language: configuration.language)
            logger.info("stt_prewarm=ready language=\(self.configuration.language, privacy: .public)")
        } catch {
            logger.error("stt_prewarm=failed error=\(error.localizedDescription, privacy: .public)")
        }

        do {
            try await tts.prewarm(
                voiceIdentifier: configuration.defaultVoice,
                settings: configuration.ttsSettings
            )
            logger.info("tts_prewarm=ready sessions=\(self.configuration.maxTTSSessions)")
        } catch {
            logger.error("tts_prewarm=failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ channel: NIOAsyncChannel<WyomingEvent, WyomingEvent>) async {
        guard await connectionSlots.acquire() else {
            try? await channel.executeThenClose { _, outbound in
                try await outbound.write(.error(.busy, message: "Connection limit reached"))
            }
            return
        }
        defer { Task { await connectionSlots.release() } }
        do {
            try await channel.executeThenClose { [self] inbound, outbound in
                let sink = EventSink(writer: outbound)
                let session = ConnectionSession(
                    configuration: configuration,
                    voices: voices,
                    tts: tts,
                    ttsSlots: ttsSlots,
                    sttSlots: sttSlots,
                    wakeWord: wakeWord,
                    sink: sink
                )
                await session.run(inbound)
            }
        } catch {
            logger.error("connection_error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class CloseOnIdleHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .all = event as? IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

private final class SignalTrap: @unchecked Sendable {
    private let continuation: AsyncStream<Int32>.Continuation
    private let stream: AsyncStream<Int32>
    private let sources: [DispatchSourceSignal]

    init() {
        let pair = AsyncStream<Int32>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        let signalContinuation = pair.continuation
        sources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { signalContinuation.yield(signalNumber) }
            source.resume()
            return source
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
        continuation.finish()
    }

    func wait() async -> Int32 {
        await stream.first(where: { _ in true }) ?? SIGTERM
    }
}
