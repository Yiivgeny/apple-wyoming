import Foundation
import OSLog

public final class BonjourPublisher: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "local.wyoming.apple-speech", category: "bonjour")
    private let service: NetService

    public init(port: Int) {
        service = NetService(
            domain: "local.",
            type: "_wyoming._tcp.",
            name: "Apple Wyoming Voice",
            port: Int32(port)
        )
        super.init()
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "version": Data("1.0".utf8),
            "tts": Data("true".utf8),
            "stt": Data("true".utf8),
        ]))
    }

    public func start() {
        service.publish()
    }

    public func stop() {
        service.stop()
    }

    public func netServiceDidPublish(_ sender: NetService) {
        logger.info("published name=\(sender.name, privacy: .public) type=\(sender.type, privacy: .public)")
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        logger.error("publish_failed=\(String(describing: errorDict), privacy: .public)")
    }
}
