import Foundation
import NIO
#if canImport(Network)
import Network
#endif
#if canImport(NIOSSL)
import NIOSSL
#endif
import NIOHTTP1
import NIOWebSocket
import NIOTransportServices
import Logging

protocol MQTTConnectionDelegate: AnyObject {
    func mqttConnection(_ connection: MQTTConnection, didConnectWith response: MQTTConnectResponse)
    func mqttConnectionWillReconnect(_ connection: MQTTConnection)
    func mqttConnection(_ connection: MQTTConnection, didDisconnectWith reason: MQTTDisconnectReason)
    func mqttConnection(_ connection: MQTTConnection, didFailToConnectWith error: Error)
}

final class MQTTConnection: MQTTErrorHandlerDelegate, MQTTFallbackPacketHandlerDelegate {
    
    // MARK: - Types
    
    private enum ConnectError: Error {
        case userDidInitiateClose
        case invalidWebSocketTarget
    }
    
    private struct ConnectionFlags: OptionSet {
        let rawValue: Int
        
        static let notifiedDelegate = ConnectionFlags(rawValue: 1 << 1)
        static let acceptedByBroker = ConnectionFlags(rawValue: 1 << 2)
        static let triggeredDidConnect = ConnectionFlags(rawValue: 1 << 3)
        
        init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }
    
    // MARK: - Vars
    
    let eventLoop: EventLoop
    let useNIOTS: Bool
    let configuration: MQTTConfiguration
    let logger: Logger
    
    var connectFuture: EventLoopFuture<MQTTConnectResponse> {
        eventLoop.assertInEventLoop()
        
        return _connectFuture.map { $1 }
    }
    
    private let requestHandler: MQTTRequestHandler
    private let subscriptionsHandler: MQTTSubscriptionsHandler
    private let keepAliveHandler: MQTTKeepAliveHandler
    
    private weak var delegate: MQTTConnectionDelegate?
    
    private var _connectFuture: EventLoopFuture<(Channel, MQTTConnectResponse)>!
    
    private var reconnectTask: Scheduled<EventLoopFuture<(Channel, MQTTConnectResponse)>>?
    
    private var connectionFlags: ConnectionFlags = []
    private var disconnectReason: MQTTDisconnectReason = .connectionClosed()
    
    private var didUserInitiateClose: Bool = false
    
    // MARK: - Init
    
    init(
        eventLoop: EventLoop,
        useNIOTS: Bool,
        configuration: MQTTConfiguration,
        requestHandler: MQTTRequestHandler,
        subscriptionsHandler: MQTTSubscriptionsHandler,
        delegate: MQTTConnectionDelegate?,
        logger: Logger
    ) {
        self.eventLoop = eventLoop
        self.useNIOTS = useNIOTS
        self.configuration = configuration
        self.delegate = delegate
        self.logger = logger
        
        self.requestHandler = requestHandler
        self.subscriptionsHandler = subscriptionsHandler
        keepAliveHandler = MQTTKeepAliveHandler(
            interval: configuration.keepAliveInterval,
            reschedulePings: configuration.reschedulePings,
            logger: logger
        )
        
        _connectFuture = connect()
    }
    
    // MARK: - Close
    
    func close(with request: MQTTDisconnectReason.UserRequest) -> EventLoopFuture<Void> {
        return eventLoop.flatSubmit { () -> EventLoopFuture<(Channel, MQTTConnectResponse)> in
            self.didUserInitiateClose = true
            
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            
            return self._connectFuture
        }.flatMap { channel, _ in
            self.close(channel, reason: .userInitiated(request))
        }
    }
    
    @discardableResult
    private func close(_ channel: Channel, reason: MQTTDisconnectReason) -> EventLoopFuture<Void> {
        eventLoop.assertInEventLoop()
        
        self.disconnectReason = reason
        return shutdown(channel)
    }
    
    // MARK: - Connect
    
    private func connect() -> EventLoopFuture<(Channel, MQTTConnectResponse)> {
        return connect(reconnectMode: configuration.reconnectMode)
    }
    
    private func connect(reconnectMode: MQTTConfiguration.ReconnectMode) -> EventLoopFuture<(Channel, MQTTConnectResponse)> {
        guard !didUserInitiateClose else {
            logger.debug("Ignoring connect, user initiated close")
            return eventLoop.makeFailedFuture(ConnectError.userDidInitiateClose)
        }
        
        // First connect to broker
        return connectToBroker()
            .map { channel -> Channel in
                self.logger.notice("Connected to broker", metadata: [
                    "target": "\(self.configuration.target)"
                ])
                return channel
            }
            .flatMap { channel -> EventLoopFuture<(Channel, MQTTConnectResponse)> in
                // Send Connect packet to broker
                self.requestConnectionWithBroker(for: channel).flatMapError { error in
                    self.logger.error("Failed Connect request, shutting down channel", metadata: [
                        "error": "\(error)"
                    ])
                    
                    // In case of error, properly shutdown and still throw the same error
                    return self.shutdown(channel).flatMapThrowing {
                        throw error
                    }
                }
            }.map { (channel, response) -> (Channel, MQTTConnectResponse) in
                // Setup handler for when channel is closed (for any reason)
                channel.closeFuture.flatMap {
                    // Property shutdown first
                    self.shutdown(channel)
                }.whenSuccess { result in
                    self.logger.notice("Disconnected from broker", metadata: [
                        "target": "\(self.configuration.target)"
                    ])
                    
                    // Schedule reconnect if needed
                    if let connectFuture = self.scheduleReconnect(reconnectMode: reconnectMode) {
                        self._connectFuture = connectFuture
                    }
                }
                
                return (channel, response)
            }.flatMapError { error in
                self.logger.error("Failed to connect to broker", metadata: [
                    "error": "\(error)"
                ])
                
                self.delegate?.mqttConnection(self, didFailToConnectWith: error)
                
                // Schedule reconnect if needed
                if let connectFuture = self.scheduleReconnect(reconnectMode: reconnectMode) {
                    self._connectFuture = connectFuture
                }
                
                return self.eventLoop.makeFailedFuture(error)
            }
    }
    
    private func createBootstrap() throws -> NIOClientTCPBootstrap {
        switch configuration.tls {
        case .none:
            #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), useNIOTS {
                let bootstrap = NIOTSConnectionBootstrap(group: eventLoop)
                return NIOClientTCPBootstrap(bootstrap, tls: NIOTSClientTLSProvider())
            }
            #endif
            let bootstrap = ClientBootstrap(group: eventLoop)
            return NIOClientTCPBootstrap(bootstrap, tls: NIOInsecureNoTLS())
            
        // This should use canImport(NIOSSL), will change when it works with SwiftUI previews.
        #if os(macOS) || os(Linux)
        case .nioSSL(let tlsConfiguration):
            guard let bootstrap = ClientBootstrap(validatingGroup: eventLoop) else {
                throw MQTTConnectionError.invalidTLSConfiguration
            }
            
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(
                context: sslContext,
                serverHostname: configuration.target.hostname?.sniServerHostname
            )
            return NIOClientTCPBootstrap(bootstrap, tls: tlsProvider).enableTLS()
        #endif
            
        #if canImport(Network)
        case .transportServices(let tlsConfiguration):
            guard
                #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *),
                let bootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop)
            else {
                throw MQTTConnectionError.invalidTLSConfiguration
            }
            
            let options = tlsConfiguration.createNWProtocolTLSOptions(
                tlsServerName: configuration.target.hostname?.sniServerHostname,
                logger: logger
            )
            
            let tlsProvider = NIOTSClientTLSProvider(tlsOptions: options)
            return NIOClientTCPBootstrap(bootstrap, tls: tlsProvider).enableTLS()
        #endif
        }
    }
    
    private func connectToBroker() -> EventLoopFuture<Channel> {
        logger.notice("Connecting to broker", metadata: [
            "target": "\(configuration.target)"
        ])
        
        let bootstrap: NIOClientTCPBootstrap
        do {
            bootstrap = try createBootstrap()
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        
        return bootstrap
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .connectTimeout(configuration.connectionTimeoutInterval)
            .connect(to: configuration.target)
            .flatMap {
                if let webSocketsConfiguration = self.configuration.webSockets {
                    return self.upgradeWebSocket(for: $0, config: webSocketsConfiguration) {
                        self.addHandlers(to: $0)
                    }
                } else {
                    return self.addHandlers(to: $0)
                }
            }
    }
    
    private func upgradeWebSocket(
        for channel: Channel,
        config: MQTTConfiguration.WebSocketsConfiguration,
        completionHandler: @escaping @Sendable (Channel) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        
        guard case .host(let host, _) = configuration.target else {
            return channel.eventLoop.makeFailedFuture(ConnectError.invalidWebSocketTarget)
        }
        
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        
        let initialRequestHandler = WebSocketInitialRequestHandler(
            logger: logger,
            host: host,
            path: config.path,
            headers: config.headers
        ) { context, error in
            context.fireErrorCaught(error)
            promise.fail(error)
        }
        
        let requestKey = Data(
            (0..<16).map { _ in UInt8.random(in: .min ..< .max) }
        ).base64EncodedString()
        
        let upgrader = NIOWebSocketClientUpgrader(
            requestKey: requestKey, maxFrameSize: 2 * 1024 * 1024
        ) { channel, _ in
            let future = channel.pipeline.addHandler(WebSocketHandler()).flatMap {
                completionHandler(channel)
            }
            future.cascade(to: promise)
            return future.map { _ in }
        }
        
        let config: NIOHTTPClientUpgradeConfiguration = (
            upgraders: [ upgrader ],
            completionHandler: { context in
                channel.pipeline.removeHandler(initialRequestHandler, promise: nil)
            }
        )
        
        return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
            channel.pipeline.addHandler(initialRequestHandler)
        }.flatMap {
            promise.futureResult
        }
    }
    
    private func addHandlers(to channel: Channel) -> EventLoopFuture<Channel> {
        eventLoop.assertInEventLoop()
        
        let fallbackHandler = MQTTFallbackPacketHandler(
            version: configuration.protocolVersion,
            logger: logger
        )
        fallbackHandler.delegate = self
        
        let errorHandler = MQTTErrorHandler(logger: logger)
        errorHandler.delegate = self
        
        return channel.pipeline.addHandlers([
            // Decoding
            ByteToMessageHandler(MQTTPacketDecoder(logger: logger)),
            MQTTPacketTypeParser(
                version: configuration.protocolVersion,
                logger: logger
            ),
            
            // Encoding
            MessageToByteHandler(MQTTPacketEncoder(logger: logger)),
            MQTTPacketTypeSerializer(
                version: configuration.protocolVersion,
                logger: logger
            ),
            
            // Continuous handlers
            keepAliveHandler,
            subscriptionsHandler,
            
            // Outgoing request handlers
            requestHandler,
            
            // Fallback handler
            fallbackHandler,
            
            // Error handler
            errorHandler
        ]).map { channel }
    }
    
    private func requestConnectionWithBroker(for channel: Channel) -> EventLoopFuture<(Channel, MQTTConnectResponse)> {
        eventLoop.assertInEventLoop()
        
        let request = MQTTConnectRequest(configuration: configuration)
        return requestHandler.perform(request).flatMap { connAck in
            // Reset the disconnect reason
            self.disconnectReason = .connectionClosed()
            
            // We established connection
            self.connectionFlags.insert(.acceptedByBroker)
            
            // Process connAck
            let response = self.process(connAck)
            
            self.connectionFlags.insert(.notifiedDelegate)
            self.delegate?.mqttConnection(self, didConnectWith: response)
            
            // Fail if the user initiated a close.
            guard !self.didUserInitiateClose else {
                return self.eventLoop.makeFailedFuture(MQTTConnectionError.connectionClosed)
            }
            
            self.connectionFlags.insert(.triggeredDidConnect)
            
            let didConnectEvent = MQTTConnectionEvent.didConnect(isSessionPresent: response.isSessionPresent)
            return channel
                .triggerUserOutboundEvent(didConnectEvent)
                .map { response }
        }.map {
            (channel, $0)
        }
    }
    
    private func process(_ connAck: MQTTPacket.ConnAck) -> MQTTConnectResponse {
        if let receiveMaximum = connAck.properties.receiveMaximum {
            requestHandler.maxInflightEntries = min(MQTTRequestHandler.defaultMaxInflightEntries, receiveMaximum)
        } else {
            requestHandler.maxInflightEntries = MQTTRequestHandler.defaultMaxInflightEntries
        }
        
        keepAliveHandler.interval = connAck.properties.serverKeepAlive ?? configuration.keepAliveInterval
        
        let brokerConfiguration = MQTTBrokerConfiguration(
            maximumQoS: connAck.properties.maximumQoS,
            isRetainAvailable: connAck.properties.retainAvailable,
            maximumPacketSize: connAck.properties.maximumPacketSize,
            isWildcardSubscriptionAvailable: connAck.properties.wildcardSubscriptionAvailable,
            isSubscriptionIdentifierAvailable: connAck.properties.subscriptionIdentifierAvailable,
            isSharedSubscriptionAvailable: connAck.properties.sharedSubscriptionAvailable
        )
        requestHandler.brokerConfiguration = brokerConfiguration
        
        return MQTTConnectResponse(
            isSessionPresent: connAck.isSessionPresent,
            sessionExpiry: connAck.properties.sessionExpiry ?? configuration.sessionExpiry,
            keepAliveInterval: connAck.properties.serverKeepAlive ?? configuration.keepAliveInterval,
            assignedClientIdentifier: connAck.properties.assignedClientIdentifier ?? configuration.clientId,
            userProperties: connAck.properties.userProperties,
            responseInformation: connAck.properties.responseInformation,
            brokerConfiguration: brokerConfiguration
        )
    }
    
    // MARK: - Disconnect
    
    // This future never fails
    private func shutdown(_ channel: Channel) -> EventLoopFuture<Void> {
        eventLoop.assertInEventLoop()
        
        return sendDisconnect(for: channel).flatMap {
            // Now we can close the channel
            channel.close().recover { _ in
                // We don't really care if the close fails, just continue
            }
        }.map {
            self.notifyClosed()
        }
    }
    
    private func notifyClosed() {
        eventLoop.assertInEventLoop()
        
        logger.notice("Channel closed")
        
        if connectionFlags.contains(.notifiedDelegate) {
            connectionFlags.remove(.notifiedDelegate)
            
            delegate?.mqttConnection(self, didDisconnectWith: self.disconnectReason)
        }
    }
    
    private func sendDisconnect(for channel: Channel) -> EventLoopFuture<Void> {
        eventLoop.assertInEventLoop()
        
        // Only trigger the `willDisconnect` event if we send a `didConnect` event before.
        let eventFuture: EventLoopFuture<Void>
        if connectionFlags.contains(.triggeredDidConnect) {
            connectionFlags.remove(.triggeredDidConnect)
            eventFuture = channel.triggerUserOutboundEvent(MQTTConnectionEvent.willDisconnect).recover { _ in
                // We don't care if this fails
            }
        } else {
            eventFuture = eventLoop.makeSucceededFuture(())
        }
        
        // Only send disconnect if broker has accepted before
        guard connectionFlags.contains(.acceptedByBroker) else {
            return eventFuture
        }
        
        connectionFlags.remove(.acceptedByBroker)
        return eventFuture.flatMap {
            guard let request = MQTTDisconnectRequest(reason: self.disconnectReason) else {
                return self.eventLoop.makeSucceededVoidFuture()
            }
            
            return self.requestHandler.perform(request).recover { _ in
                // We don't care if this fails
            }
        }
    }
    
    // MARK: - Reconnect
    
    private func scheduleReconnect(reconnectMode: MQTTConfiguration.ReconnectMode) -> EventLoopFuture<(Channel, MQTTConnectResponse)>? {
        eventLoop.assertInEventLoop()
        
        guard
            !didUserInitiateClose,
            case .retry(let delay, _) = reconnectMode
        else {
            return nil
        }
        
        logger.notice("Scheduling to reconnect to broker", metadata: [
            "delay": "\(delay.nanoseconds / 1_000_000_000)"
        ])
        
        // Reconnect after delay
        let reconnectTask = eventLoop.scheduleTask(in: delay) { () -> EventLoopFuture<(Channel, MQTTConnectResponse)> in
            self.delegate?.mqttConnectionWillReconnect(self)
            
            return self.connect(reconnectMode: reconnectMode.next)
        }
        
        self.reconnectTask?.cancel()
        self.reconnectTask = reconnectTask
        
        return reconnectTask.futureResult.flatMap { $0 }
    }
    
    // MARK: - MQTTErrorHandlerDelegate
    
    func mttErrorHandler(_ handler: MQTTErrorHandler, caughtError error: Error, channel: Channel) {
        if let protocolError = error as? MQTTProtocolError {
            close(channel, reason: .client(protocolError))
        } else {
            // In case of an unknown error, simply close the channel,
            // no need to send a disconnect packet.
            connectionFlags.remove(.acceptedByBroker)
            
            close(channel, reason: .connectionClosed(error))
        }
    }
    
    // MARK: - MQTTFallbackPacketHandlerDelegate
    
    func fallbackPacketHandler(_ handler: MQTTFallbackPacketHandler, didReceiveDisconnectWith reason: MQTTDisconnectReason.ServerReason?, channel: Channel) {
        
        close(channel,reason: .server(reason))
    }
}

#if swift(>=5.5) && canImport(_Concurrency)
extension MQTTConnection: @unchecked MQTTSendable {}
#endif

extension NIOClientTCPBootstrap {
    fileprivate func connect(to target: MQTTConfiguration.Target) -> EventLoopFuture<Channel> {
        switch target {
        case .host(let host, port: let port):
            return connect(host: host, port: port)
            
        case .socketAddress(let socketAddress):
            return connect(to: socketAddress)
            
        case .unixDomainSocket(let unixDomainSocketPath):
            return connect(unixDomainSocketPath: unixDomainSocketPath)
        }
    }
}

extension String {
    private var isIPAddress: Bool {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            return inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                   inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }

    private var isValidSNIServerName: Bool {
        guard !isIPAddress else {
            return false
        }

        guard !self.utf8.contains(0) else {
            return false
        }

        guard (1 ... 255).contains(self.utf8.count) else {
            return false
        }
        
        return true
    }
    
    fileprivate var sniServerHostname: String? {
        guard isValidSNIServerName else {
            return nil
        }
        return self
    }
}
