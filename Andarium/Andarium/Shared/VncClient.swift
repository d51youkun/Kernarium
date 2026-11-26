// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import CoreGraphics
import Foundation
import Network

/// Minimal RFB 3.8 (VNC) client over a private Unix-domain socket for QEMU's
/// display, supporting Raw rectangles, DesktopSize resize, pointer events
/// (absolute mouse/touch via USB Tablet), and keyboard events.
@MainActor
final class VncClient: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var statusText = "VNC 接続待機中..."
    @Published private(set) var framebufferWidth = 0
    @Published private(set) var framebufferHeight = 0
    @Published private(set) var frameImage: CGImage?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.imxieyi.andarium.vnc", qos: .userInteractive)
    private var framebuffer: [UInt8] = []
    private var readBuffer = Data()
    private var phase: HandshakePhase = .version
    private var shouldRun = false
    private var retryCount = 0
    private static let maxBufferedBytes = 4096 * 4096 * 4 + 1024 * 1024

    private enum HandshakePhase {
        case version
        case securityTypesCount
        case securityTypes(Int)
        case securityResult
        case serverInitHeader
        case serverInitName(Int)
        case running
    }

    func connect(socket: URL) {
        disconnect()
        shouldRun = true
        retryCount = 0
        statusText = "仮想マシン画面に接続中..."
        openConnection(socket: socket)
    }

    func disconnect() {
        shouldRun = false
        connection?.cancel()
        connection = nil
        isConnected = false
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func openConnection(socket: URL) {
        guard shouldRun, connection == nil else { return }
        let conn = NWConnection(to: .unix(path: socket.path), using: .tcp)
        connection = conn
        phase = .version
        readBuffer.removeAll(keepingCapacity: true)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.statusText = "RFB ハンドシェイク中..."
                    self.receiveLoop(on: conn)
                case .failed, .waiting:
                    if self.shouldRun && self.retryCount < 30 {
                        self.retryCount += 1
                        conn.cancel()
                        self.connection = nil
                        try? await Task.sleep(for: .milliseconds(350))
                        self.openConnection(socket: socket)
                    } else if self.shouldRun {
                        self.statusText = "VNC 画面への接続がタイムアウトしました。"
                    }
                case .cancelled:
                    self.isConnected = false
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty {
                    guard self.readBuffer.count + data.count <= Self.maxBufferedBytes else {
                        self.disconnect()
                        return
                    }
                    self.readBuffer.append(data)
                    self.processBuffer(on: conn)
                }
                guard self.connection === conn else { return }
                if isComplete || error != nil {
                    self.isConnected = false
                    return
                }
                self.receiveLoop(on: conn)
            }
        }
    }

    private func processBuffer(on conn: NWConnection) {
        while true {
            switch phase {
            case .version:
                guard readBuffer.count >= 12 else { return }
                guard readBuffer.prefix(12).elementsEqual("RFB 003.008\n".utf8) else { disconnect(); return }
                readBuffer.removeFirst(12)
                send(Data("RFB 003.008\n".utf8), on: conn)
                phase = .securityTypesCount

            case .securityTypesCount:
                guard readBuffer.count >= 1 else { return }
                let count = Int(readBuffer.removeFirst())
                if count == 0 {
                    statusText = "VNC セキュリティネゴシエーション失敗"
                    disconnect()
                    return
                }
                phase = .securityTypes(count)

            case .securityTypes(let count):
                guard readBuffer.count >= count else { return }
                let types = readBuffer.prefix(count)
                readBuffer.removeFirst(count)
                // Choose SecurityType 1 (None) for loopback QEMU VNC
                guard types.contains(1) else { disconnect(); return }
                send(Data([1]), on: conn)
                phase = .securityResult

            case .securityResult:
                guard readBuffer.count >= 4 else { return }
                let result = readUInt32(from: readBuffer, at: 0)
                readBuffer.removeFirst(4)
                guard result == 0 else {
                    statusText = "VNC 認証エラー (\(result))"
                    disconnect()
                    return
                }
                // ClientInit: shared-flag = 1
                send(Data([1]), on: conn)
                phase = .serverInitHeader

            case .serverInitHeader:
                guard readBuffer.count >= 24 else { return }
                let w = Int(readUInt16(from: readBuffer, at: 0))
                let h = Int(readUInt16(from: readBuffer, at: 2))
                let nameLen = Int(readUInt32(from: readBuffer, at: 20))
                readBuffer.removeFirst(24)
                guard (1...4096).contains(w), (1...4096).contains(h), nameLen <= 4096 else {
                    disconnect()
                    return
                }
                resizeFramebuffer(width: w, height: h)
                phase = .serverInitName(nameLen)

            case .serverInitName(let nameLen):
                guard readBuffer.count >= nameLen else { return }
                readBuffer.removeFirst(nameLen)
                phase = .running
                isConnected = true
                statusText = "接続済み (\(framebufferWidth)x\(framebufferHeight))"
                sendPixelFormatAndEncodings(on: conn)
                requestFramebufferUpdate(incremental: false, on: conn)

            case .running:
                guard parseRunningMessage(on: conn) else { return }
            }
        }
    }

    private func sendPixelFormatAndEncodings(on conn: NWConnection) {
        // SetPixelFormat (msg 0): 32bpp, depth 24, little-endian, true-colour, RGB888 (BGRA in memory)
        var pf = Data(count: 20)
        pf[0] = 0
        pf[4] = 32 // bits-per-pixel
        pf[5] = 24 // depth
        pf[6] = 0  // big-endian-flag = 0 (little endian)
        pf[7] = 1  // true-colour-flag = 1
        writeUInt16(255, to: &pf, at: 8)   // red-max
        writeUInt16(255, to: &pf, at: 10)  // green-max
        writeUInt16(255, to: &pf, at: 12)  // blue-max
        pf[14] = 16 // red-shift
        pf[15] = 8  // green-shift
        pf[16] = 0  // blue-shift
        send(pf, on: conn)

        // SetEncodings (msg 2): Raw (0) + DesktopSize (-223)
        var enc = Data(count: 12)
        enc[0] = 2
        writeUInt16(2, to: &enc, at: 2)
        writeInt32(0, to: &enc, at: 4)
        writeInt32(-223, to: &enc, at: 8)
        send(enc, on: conn)
    }

    private func requestFramebufferUpdate(incremental: Bool, on conn: NWConnection) {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return }
        var req = Data(count: 10)
        req[0] = 3
        req[1] = incremental ? 1 : 0
        writeUInt16(0, to: &req, at: 2)
        writeUInt16(0, to: &req, at: 4)
        writeUInt16(UInt16(min(framebufferWidth, 65535)), to: &req, at: 6)
        writeUInt16(UInt16(min(framebufferHeight, 65535)), to: &req, at: 8)
        send(req, on: conn)
    }

    private func parseRunningMessage(on conn: NWConnection) -> Bool {
        guard let msgType = readBuffer.first else { return false }
        switch msgType {
        case 0: // FramebufferUpdate
            guard readBuffer.count >= 4 else { return false }
            let rectCount = Int(readUInt16(from: readBuffer, at: 2))
            var cursor = 4
            var rectangles: [(x: Int, y: Int, w: Int, h: Int, offset: Int?)] = []
            var width = framebufferWidth
            var height = framebufferHeight
            for _ in 0..<rectCount {
                guard readBuffer.count >= cursor + 12 else { return false }
                let x = Int(readUInt16(from: readBuffer, at: cursor))
                let y = Int(readUInt16(from: readBuffer, at: cursor + 2))
                let w = Int(readUInt16(from: readBuffer, at: cursor + 4))
                let h = Int(readUInt16(from: readBuffer, at: cursor + 6))
                let encoding = readInt32(from: readBuffer, at: cursor + 8)
                cursor += 12
                if encoding == -223 {
                    guard (1...4096).contains(w), (1...4096).contains(h) else { disconnect(); return false }
                    width = w
                    height = h
                    rectangles.append((x, y, w, h, nil))
                } else if encoding == 0 {
                    guard x + w <= width, y + h <= height else { disconnect(); return false }
                    let byteCount = w * h * 4
                    guard readBuffer.count >= cursor + byteCount else { return false }
                    rectangles.append((x, y, w, h, cursor))
                    cursor += byteCount
                } else {
                    disconnect()
                    return false
                }
            }
            for rect in rectangles {
                if let offset = rect.offset {
                    blitRawRect(x: rect.x, y: rect.y, w: rect.w, h: rect.h, offset: offset)
                } else {
                    resizeFramebuffer(width: rect.w, height: rect.h)
                    statusText = "接続済み (\(rect.w)x\(rect.h))"
                }
            }
            readBuffer.removeFirst(cursor)
            if !rectangles.isEmpty {
                publishImage()
            }
            requestFramebufferUpdate(incremental: true, on: conn)
            return true

        case 1: // SetColourMapEntries
            guard readBuffer.count >= 6 else { return false }
            let count = Int(readUInt16(from: readBuffer, at: 4))
            let total = 6 + count * 6
            guard readBuffer.count >= total else { return false }
            readBuffer.removeFirst(total)
            return true

        case 2: // Bell
            readBuffer.removeFirst(1)
            return true

        case 3: // ServerCutText
            guard readBuffer.count >= 8 else { return false }
            let len = Int(readUInt32(from: readBuffer, at: 4))
            let total = 8 + len
            guard readBuffer.count >= total else { return false }
            readBuffer.removeFirst(total)
            return true

        default:
            disconnect()
            return false
        }
    }

    private func resizeFramebuffer(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        framebufferWidth = width
        framebufferHeight = height
        framebuffer = [UInt8](repeating: 0, count: width * height * 4)
    }

    private func blitRawRect(x: Int, y: Int, w: Int, h: Int, offset: Int) {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return }
        let rowBytes = w * 4
        let fbRowBytes = framebufferWidth * 4
        readBuffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            framebuffer.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                for row in 0..<h {
                    let dy = y + row
                    guard dy >= 0 && dy < framebufferHeight else { continue }
                    let clampedW = min(w, framebufferWidth - x)
                    guard clampedW > 0, x >= 0 else { continue }
                    let srcPtr = base.advanced(by: offset + row * rowBytes)
                    let dstPtr = dstBase.advanced(by: dy * fbRowBytes + x * 4)
                    memcpy(dstPtr, srcPtr, clampedW * 4)
                }
            }
        }
    }

    private func publishImage() {
        guard framebufferWidth > 0, framebufferHeight > 0 else { return }
        let data = Data(framebuffer)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        frameImage = CGImage(
            width: framebufferWidth,
            height: framebufferHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: framebufferWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Sends an RFB PointerEvent (buttonMask: bit0=left, bit1=middle, bit2=right).
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard isConnected, let conn = connection, framebufferWidth > 0, framebufferHeight > 0 else { return }
        let clampedX = UInt16(max(0, min(x, framebufferWidth - 1)))
        let clampedY = UInt16(max(0, min(y, framebufferHeight - 1)))
        var msg = Data(count: 6)
        msg[0] = 5
        msg[1] = buttons
        writeUInt16(clampedX, to: &msg, at: 2)
        writeUInt16(clampedY, to: &msg, at: 4)
        send(msg, on: conn)
    }

    /// Sends an RFB KeyEvent (X11 keysym).
    func sendKey(keysym: UInt32, down: Bool) {
        guard isConnected, let conn = connection else { return }
        var msg = Data(count: 8)
        msg[0] = 4
        msg[1] = down ? 1 : 0
        writeUInt32(keysym, to: &msg, at: 4)
        send(msg, on: conn)
    }

    func sendText(_ text: String) {
        for scalar in text.unicodeScalars {
            let sym: UInt32
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                sym = scalar.value
            } else if scalar == "\n" || scalar == "\r" {
                sym = 0xff0d
            } else {
                sym = 0x0100_0000 | scalar.value
            }
            sendKey(keysym: sym, down: true)
            sendKey(keysym: sym, down: false)
        }
    }

    private func send(_ data: Data, on conn: NWConnection) {
        conn.send(content: data, completion: .idempotent)
    }

    private func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return (UInt16(data[i]) << 8) | UInt16(data[i + 1])
    }

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
    }

    private func readInt32(from data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(from: data, at: offset))
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xff)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xff)
        data[offset + 1] = UInt8((value >> 16) & 0xff)
        data[offset + 2] = UInt8((value >> 8) & 0xff)
        data[offset + 3] = UInt8(value & 0xff)
    }

    private func writeInt32(_ value: Int32, to data: inout Data, at offset: Int) {
        writeUInt32(UInt32(bitPattern: value), to: &data, at: offset)
    }
}
