import Foundation
import Network

/// Pointer coordinates retained without allocating packets for superseded motion.
private struct VNCPointerPosition: Sendable {
    let x: UInt16
    let y: UInt16
}

/// Thread-safe one-shot gate for NWConnection callbacks that may arrive
/// concurrently while an async continuation is waiting.
private final class VNCPointerSendBatch: @unchecked Sendable {
    var latestPosition: VNCPointerPosition?
    var scheduled = false
}

private final class QEMUOneShotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// Minimal RFB 3.8 client for the loopback-only QEMU VNC server.
/// This provides real guest pixels without requiring UTM's full SPICE renderer.
/// It deliberately supports raw framebuffer rectangles only.
final class QEMUVNCClient {
    enum ClientError: LocalizedError {
        case connection(String)
        case protocolError(String)
        var errorDescription: String? {
            switch self {
            case .connection(let message), .protocolError(let message): return message
            }
        }
    }

    private let queue = DispatchQueue(label: "com.xthrx.isteam.qemu-vnc")
    private let sendQueue = DispatchQueue(label: "com.xthrx.isteam.qemu-vnc.send")
    private var pendingSendGroup = DispatchGroup()
    private let lock = NSLock()
    private var connection: NWConnection?

    /// Keep NSLock operations in a synchronous helper. Calling lock()/unlock()
    /// directly from async contexts is rejected by Swift 6 concurrency checking.
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    private var readerTask: Task<Void, Never>?
    private static let maxFramebufferBytes = 64 * 1024 * 1024
    private var framebuffer = Data()
    private var framebufferWidth = 0
    private var framebufferHeight = 0
    private var pointerX: Int = 0
    private var pointerY: Int = 0
    private var keyState = VNCKeyState()
    /// A separate batch per connection prevents stale queued pointer work from
    /// leaking into a restarted VNC session.
    private var pointerSendBatch: VNCPointerSendBatch?
    private var connected = false
    var isConnected: Bool { withStateLock { connected } }
    var onFrame: ((Data, Int, Int, [GPUFrameRegion]?) -> Void)?
    var onStatus: ((String) -> Void)?

    func start(port: UInt16 = 5900) {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            onStatus?("Invalid local VNC port.")
            return
        }
        readerTask = Task { [weak self] in
            guard let self else { return }
            var lastError: Error = ClientError.connection("QEMU VNC server did not start.")
            for attempt in 0..<120 {
                if Task.isCancelled { return }
                let candidate = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
                let installed = self.withStateLock {
                    guard !Task.isCancelled else { return false }
                    self.connection = candidate
                    self.connected = false
                    self.pointerSendBatch = nil
                    return true
                }
                guard installed else {
                    candidate.cancel()
                    return
                }
                do {
                    try await self.waitUntilReady(candidate)
                    try await self.performHandshake(candidate)
                    let activated = self.withStateLock {
                        guard !Task.isCancelled, self.connection === candidate else { return false }
                        self.connected = true
                        self.pointerSendBatch = VNCPointerSendBatch()
                        return true
                    }
                    guard activated else {
                        candidate.cancel()
                        return
                    }
                    self.onStatus?("Guest display connected • local VNC")
                    try await self.readServerMessages(candidate)
                    break
                } catch {
                    lastError = error
                    if Task.isCancelled { return }
                    let wasCurrent = self.withStateLock {
                        guard self.connection === candidate else { return false }
                        self.connection = nil
                        self.connected = false
                        self.pointerSendBatch = nil
                        self.pendingSendGroup = DispatchGroup()
                        _ = self.keyState.releaseAll()
                        return true
                    }
                    if wasCurrent {
                        candidate.cancel()
                    }
                    if attempt < 119 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
            if Task.isCancelled { return }
            self.withStateLock {
                self.connected = false
            }
            self.onStatus?("Guest display unavailable: \(lastError.localizedDescription)")
        }
    }

    func stop() {
        readerTask?.cancel()
        readerTask = nil
        let (previousConnection, previousGroup) = withStateLock { () -> (NWConnection?, DispatchGroup) in
            let previous = connection
            let group = pendingSendGroup
            connection = nil
            connected = false
            pointerSendBatch = nil

            // No later input can enter the old group after connection becomes nil.
            // Queue releases after all earlier key-down packets, then cancel only
            // after Network.framework confirms the final release was processed.
            let releaseEvents = keyState.releaseAll()
            if let previous, !releaseEvents.isEmpty {
                enqueueSend(Self.keyEvents(releaseEvents), to: previous, in: group)
            }
            pendingSendGroup = DispatchGroup()
            return (previous, group)
        }
        if let previousConnection {
            previousGroup.notify(queue: queue) {
                previousConnection.cancel()
            }
        }
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = QEMUOneShotCompletion()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard completion.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard completion.claim() else { return }
                    continuation.resume(throwing: ClientError.connection(error.localizedDescription))
                case .cancelled:
                    guard completion.claim() else { return }
                    continuation.resume(throwing: ClientError.connection("The local QEMU display connection was cancelled."))
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        guard count >= 0, count <= 64 * 1024 * 1024 else {
            throw ClientError.protocolError("QEMU sent an invalid framebuffer length.")
        }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            if Task.isCancelled { throw CancellationError() }
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: ClientError.connection(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if complete {
                        continuation.resume(throwing: ClientError.connection("QEMU closed the guest display connection."))
                    } else {
                        continuation.resume(throwing: ClientError.connection("The guest display returned no data."))
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    /// All client writes enter one serial queue. Key-down/key-up and pointer
    /// packets can originate from different UI/controller threads; sending them
    /// from independent Tasks could reorder a release ahead of its press.
    private func enqueueSend(_ data: Data, to connection: NWConnection,
                             in group: DispatchGroup) {
        // A queued pointer drain must finish before this key event. Rotating
        // the batch makes later pointer movement queue behind the key event.
        if pointerSendBatch != nil {
            pointerSendBatch = VNCPointerSendBatch()
        }
        group.enter()
        sendQueue.async {
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    EmulationLog.shared.write("QEMU VNC send failed: \(error.localizedDescription)")
                }
                group.leave()
            })
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let enqueued = withStateLock { () -> Bool in
                guard self.connection === connection else { return false }
                let group = pendingSendGroup
                group.enter()
                sendQueue.async {
                    connection.send(content: data, completion: .contentProcessed { error in
                        group.leave()
                        if let error {
                            continuation.resume(throwing: ClientError.connection(error.localizedDescription))
                        } else {
                            continuation.resume(returning: ())
                        }
                    })
                }
                return true
            }
            if !enqueued {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private static func keyEvent(_ keysym: UInt32, down: Bool) -> Data {
        Data([4, down ? 1 : 0, 0, 0,
              UInt8((keysym >> 24) & 0xff), UInt8((keysym >> 16) & 0xff),
              UInt8((keysym >> 8) & 0xff), UInt8(keysym & 0xff)])
    }

    private static func keyTapEvents(_ keysym: UInt32) -> Data {
        var data = Data(count: 16)
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let b0 = UInt8((keysym >> 24) & 0xff)
            let b1 = UInt8((keysym >> 16) & 0xff)
            let b2 = UInt8((keysym >> 8) & 0xff)
            let b3 = UInt8(keysym & 0xff)
            base[0] = 4
            base[1] = 1
            base[2] = 0
            base[3] = 0
            base[4] = b0
            base[5] = b1
            base[6] = b2
            base[7] = b3
            base[8] = 4
            base[9] = 0
            base[10] = 0
            base[11] = 0
            base[12] = b0
            base[13] = b1
            base[14] = b2
            base[15] = b3
        }
        return data
    }

    private static func keyEvents(_ events: [VNCKeyState.Event]) -> Data {
        var data = Data()
        data.reserveCapacity(events.count * 8)
        for event in events {
            let keysym = event.keysym
            data.append(4)
            data.append(event.isDown ? 1 : 0)
            data.append(0)
            data.append(0)
            data.append(UInt8((keysym >> 24) & 0xff))
            data.append(UInt8((keysym >> 16) & 0xff))
            data.append(UInt8((keysym >> 8) & 0xff))
            data.append(UInt8(keysym & 0xff))
        }
        return data
    }

    private func performHandshake(_ connection: NWConnection) async throws {
        let serverVersion = try await receiveExactly(12, from: connection)
        guard let version = String(data: serverVersion, encoding: .ascii),
              version.hasPrefix("RFB 003.") else {
            throw ClientError.protocolError("QEMU did not offer a supported RFB/VNC protocol.")
        }
        try await send(Data("RFB 003.008\n".utf8), to: connection)

        let countData = try await receiveExactly(1, from: connection)
        let count = Int(countData[0])
        guard count > 0 else {
            throw ClientError.protocolError("QEMU VNC offered no authentication methods.")
        }
        let methods = try await receiveExactly(count, from: connection)
        guard methods.contains(1) else {
            throw ClientError.protocolError("QEMU VNC must be configured for no-authentication on loopback only.")
        }
        try await send(Data([1]), to: connection)
        let securityResult = try await receiveExactly(4, from: connection)
        guard securityResult.allSatisfy({ $0 == 0 }) else {
            throw ClientError.protocolError("QEMU rejected the local VNC handshake.")
        }
        try await send(Data([1]), to: connection) // ClientInit: shared session.

        let serverInit = try await receiveExactly(24, from: connection)
        let width = Int(Self.u16(serverInit, 0))
        let height = Int(Self.u16(serverInit, 2))
        let nameLength = Int(Self.u32(serverInit, 20))
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width <= Self.maxFramebufferBytes / height / 4,
              nameLength <= 1_048_576 else {
            throw ClientError.protocolError("QEMU announced an unsupported guest display size.")
        }
        _ = try await receiveExactly(nameLength, from: connection)
        withStateLock {
            framebufferWidth = width
            framebufferHeight = height
            framebuffer = Data(repeating: 0, count: width * height * 4)
            pointerX = width / 2
            pointerY = height / 2
        }

        // 32bpp, 24-bit depth, little endian, true colour; memory order B,G,R,X.
        try await send(Data([0, 0, 0, 0, 32, 24, 0, 1,
                             0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]), to: connection)
        // Raw rectangles and DesktopSize updates only.
        try await send(Data([2, 0, 0, 2,
                             0, 0, 0, 0,
                             0xff, 0xff, 0xff, 0x21]), to: connection)
        try await requestFramebufferUpdate(incremental: false, connection: connection)
    }

    private func readServerMessages(_ connection: NWConnection) async throws {
        while !Task.isCancelled {
            let type = try await receiveExactly(1, from: connection)[0]
            switch type {
            case 0: // FramebufferUpdate
                let updateHeader = try await receiveExactly(3, from: connection)
                let count = Int(Self.u16(updateHeader, 1))
                guard count <= 4096 else {
                    throw ClientError.protocolError("QEMU sent too many framebuffer rectangles in one update.")
                }
                var updateBytes = 0
                var framebufferChanged = false
                var dirtyRegions = GPUFrameRegionAccumulator()
                for _ in 0..<count {
                    let header = try await receiveExactly(12, from: connection)
                    let x = Int(Self.u16(header, 0))
                    let y = Int(Self.u16(header, 2))
                    let width = Int(Self.u16(header, 4))
                    let height = Int(Self.u16(header, 6))
                    let encoding = Int32(bitPattern: Self.u32(header, 8))
                    if encoding == -223 { // DesktopSize
                        guard width > 0, height > 0, width <= 8192, height <= 8192,
                              width <= Self.maxFramebufferBytes / height / 4 else {
                            throw ClientError.protocolError("QEMU requested an invalid guest display size.")
                        }
                        withStateLock {
                            framebufferWidth = width
                            framebufferHeight = height
                            framebuffer = Data(repeating: 0, count: width * height * 4)
                            pointerX = min(pointerX, width - 1)
                            pointerY = min(pointerY, height - 1)
                        }
                        dirtyRegions.add(GPUFrameRegion(x: 0, y: 0, width: width, height: height))
                        framebufferChanged = true
                        continue
                    }
                    guard encoding == 0 else {
                        throw ClientError.protocolError("Unsupported QEMU VNC rectangle encoding \(encoding).")
                    }
                    let currentSize = withStateLock { (framebufferWidth, framebufferHeight) }
                    guard width > 0, height > 0, x + width <= currentSize.0,
                          y + height <= currentSize.1, width <= Int.max / height / 4 else {
                        throw ClientError.protocolError("QEMU sent a framebuffer rectangle outside the guest display.")
                    }
                    let rectangleBytes = width * height * 4
                    guard rectangleBytes <= Self.maxFramebufferBytes - updateBytes else {
                        throw ClientError.protocolError("QEMU framebuffer update exceeded the 64 MiB transfer limit.")
                    }
                    updateBytes += rectangleBytes
                    let region = GPUFrameRegion(x: x, y: y, width: width, height: height)
                    dirtyRegions.add(region)
                    let pixels = try await receiveExactly(rectangleBytes, from: connection)
                    withStateLock {
                        // The reader task owns framebuffer updates; the lock also
                        // protects snapshots consumed by the UI/render thread.
                        let rowBytes = width * 4
                        let framebufferRowBytes = framebufferWidth * 4
                        pixels.withUnsafeBytes { source in
                            framebuffer.withUnsafeMutableBytes { destination in
                                guard let sourceBase = source.baseAddress,
                                      let destinationBase = destination.baseAddress else { return }
                                if x == 0 && width == framebufferWidth {
                                    let destinationStart = y * framebufferRowBytes
                                    destinationBase.advanced(by: destinationStart)
                                        .copyMemory(from: sourceBase, byteCount: rectangleBytes)
                                } else {
                                    for row in 0..<height {
                                        let sourceStart = row * rowBytes
                                        let destinationStart = (y + row) * framebufferRowBytes + x * 4
                                        destinationBase.advanced(by: destinationStart)
                                            .copyMemory(from: sourceBase.advanced(by: sourceStart),
                                                        byteCount: rowBytes)
                                    }
                                }
                            }
                        }
                    }
                    framebufferChanged = true
                }
                if framebufferChanged {
                    let frame = withStateLock { (framebuffer, framebufferWidth, framebufferHeight) }
                    onFrame?(frame.0, frame.1, frame.2, dirtyRegions.regions.isEmpty ? nil : dirtyRegions.regions)
                }
                try await requestFramebufferUpdate(incremental: true, connection: connection)
            case 1: // SetColourMapEntries: padding + first-colour + colour-count.
                let header = try await receiveExactly(5, from: connection)
                let numberOfColours = Int(Self.u16(header, 3))
                _ = try await receiveExactly(numberOfColours * 6, from: connection)
            case 2: // Bell
                break
            case 3: // ServerCutText
                _ = try await receiveExactly(3, from: connection)
                let length = Int(Self.u32(try await receiveExactly(4, from: connection), 0))
                guard length <= 1_048_576 else { throw ClientError.protocolError("Clipboard payload too large.") }
                _ = try await receiveExactly(length, from: connection)
            default:
                throw ClientError.protocolError("Unknown QEMU VNC server message type \(type).")
            }
        }
    }

    private func requestFramebufferUpdate(incremental: Bool, connection: NWConnection) async throws {
        // RFB FramebufferUpdateRequest is exactly 10 bytes:
        // type, incremental, x(2), y(2), width(2), height(2).
        let size = withStateLock { (framebufferWidth, framebufferHeight) }
        try await send(Data([3, incremental ? 1 : 0,
                             0, 0, 0, 0,
                             UInt8((size.0 >> 8) & 0xff), UInt8(size.0 & 0xff),
                             UInt8((size.1 >> 8) & 0xff), UInt8(size.1 & 0xff)]),
                       to: connection)
    }

    func sendKey(_ key: String, down: Bool, source: String) {
        guard let keysym = Self.keysym(for: key) else { return }
        withStateLock {
            guard connected, let connection else { return }
            if let event = keyState.setKey(keysym, source: source, isDown: down) {
                enqueueSend(Self.keyEvent(event.keysym, down: event.isDown), to: connection, in: pendingSendGroup)
            }
        }
    }

    func tapKey(_ key: String) {
        guard let keysym = Self.keysym(for: key) else { return }
        withStateLock {
            guard connected, let connection, !keyState.isPressed(keysym) else { return }
            enqueueSend(Self.keyTapEvents(keysym), to: connection, in: pendingSendGroup)
        }
    }

    func setMovement(x: Float, y: Float, source: String) {
        let desiredMask = VNCKeyState.movementMask(for: x, y: y)
        withStateLock {
            guard connected, let connection else { return }
            let events = keyState.setMovement(desiredMask, source: source)
            if !events.isEmpty {
                enqueueSend(Self.keyEvents(events), to: connection, in: pendingSendGroup)
            }
        }
    }

    func movePointer(dx: Float, dy: Float) {
        guard dx.isFinite, dy.isFinite else { return }
        withStateLock {
            guard connected, let connection, framebufferWidth > 0, framebufferHeight > 0 else { return }
            let boundedX = max(-Float(framebufferWidth), min(Float(framebufferWidth), dx * 12))
            let boundedY = max(-Float(framebufferHeight), min(Float(framebufferHeight), dy * 12))
            let deltaX = Int(boundedX)
            let deltaY = Int(boundedY)
            guard deltaX != 0 || deltaY != 0 else { return }
            let nextX = min(max(pointerX + deltaX, 0), framebufferWidth - 1)
            let nextY = min(max(pointerY - deltaY, 0), framebufferHeight - 1)
            guard nextX != pointerX || nextY != pointerY else { return }
            pointerX = nextX
            pointerY = nextY
            guard let batch = pointerSendBatch else { return }
            batch.latestPosition = VNCPointerPosition(x: UInt16(pointerX), y: UInt16(pointerY))
            guard !batch.scheduled else { return }
            batch.scheduled = true
            let group = pendingSendGroup
            group.enter()
            sendQueue.async { [self] in
                let latestPosition = withStateLock { () -> VNCPointerPosition? in
                    let latest = batch.latestPosition
                    batch.latestPosition = nil
                    batch.scheduled = false
                    return latest
                }
                guard let latestPosition else {
                    group.leave()
                    return
                }
                let message = Data([
                    5, 0,
                    UInt8(latestPosition.x >> 8), UInt8(latestPosition.x & 0xff),
                    UInt8(latestPosition.y >> 8), UInt8(latestPosition.y & 0xff)
                ])
                connection.send(content: message, completion: .contentProcessed { error in
                    if let error {
                        EmulationLog.shared.write("QEMU VNC pointer send failed: \(error.localizedDescription)")
                    }
                    group.leave()
                })
            }
        }
    }

    func sendButton(_ name: String, down: Bool, source: String) {
        let key: String
        switch name {
        case "A": key = "SPACE"
        case "B": key = "ESC"
        case "X": key = "E"
        case "Y": key = "Q"
        case "Start", "Menu", "menu": key = "ENTER"
        case "LB", "L1", "previous": key = "TAB"
        case "RB", "R1", "next": key = "R"
        case "confirm": key = "SPACE"
        case "cancel": key = "ESC"
        case "west": key = "E"
        case "north": key = "Q"
        case "LT", "L2", "lt": key = "SHIFT"
        case "RT", "R2", "rt": key = "CTRL"
        case "L3", "l3": key = "C"
        case "R3", "r3": key = "V"
        case "DPadUp", "dpadup": key = "UP"
        case "DPadDown", "dpaddown": key = "DOWN"
        case "DPadLeft", "dpadleft": key = "LEFT"
        case "DPadRight", "dpadright": key = "RIGHT"
        default: return
        }
        sendKey(key, down: down, source: source + ":" + name)
    }


    private static func keysym(for key: String) -> UInt32? {
        let value = key.uppercased()
        switch value {
        case "ESC", "ESCAPE": return 0xff1b
        case "ENTER", "RETURN": return 0xff0d
        case "TAB": return 0xff09
        case "BACKSPACE", "⌫": return 0xff08
        case "SPACE": return 0x20
        case "SHIFT": return 0xffe1
        case "CTRL": return 0xffe3
        case "ALT": return 0xffe9
        case "UP", "↑": return 0xff52
        case "DOWN", "↓": return 0xff54
        case "LEFT", "←": return 0xff51
        case "RIGHT", "→": return 0xff53
        case "F1": return 0xffbe
        case "F2": return 0xffbf
        case "F3": return 0xffc0
        case "F4": return 0xffc1
        case "F5": return 0xffc2
        case "F6": return 0xffc3
        case "F7": return 0xffc4
        case "F8": return 0xffc5
        case "F9": return 0xffc6
        case "F10": return 0xffc7
        case "F11": return 0xffc8
        case "F12": return 0xffc9
        default:
            guard value.count == 1, let scalar = value.unicodeScalars.first,
                  scalar.value < 128 else { return nil }
            return scalar.value
        }
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}
