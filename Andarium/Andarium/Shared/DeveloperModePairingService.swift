// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import UIKit
import UserNotifications
#if canImport(JitBridgeFFI)
import JitBridgeFFI
#endif

/// Service that advertises as a pairable developer host (`_remotepairing-pairable-host._tcp.`),
/// using `idevice`'s real RemotePairing protocol so iOS Developer Mode can pair directly on-device.
@MainActor
final class DeveloperModePairingService: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = DeveloperModePairingService()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var pinCode: String = ""
    @Published private(set) var pairingStatus: PairingStatus = .idle
    @Published private(set) var lastErrorMessage: String?

    enum PairingStatus: Equatable {
        case idle
        case advertising
        case showPin(String)
        case success(fileName: String, udid: String)
        case failed(String)
    }

    private var netService: NetService?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    #if canImport(JitBridgeFFI)
    private var attempt: PairingAttempt?
    #endif

    private override init() { super.init() }

    /// Starts advertising the Developer Mode pairing service via `JitBridgeFFI` and `NetService`.
    func startPairing() {
        guard !isRunning else { return }
        guard #available(iOS 27, *) else {
            finishWithError("デベロッパモードからのペアリングには iOS / iPadOS 27 以降が必要です。")
            return
        }
        #if canImport(JitBridgeFFI)
        guard attempt == nil else { return }
        #endif
        stopPairing()

        isRunning = true
        pinCode = ""
        pairingStatus = .advertising
        lastErrorMessage = nil

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        beginBackgroundExtension()

        #if canImport(JitBridgeFFI)
        let attempt = PairingAttempt()
        self.attempt = attempt
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
        let outPath = outURL.path

        DispatchQueue.global(qos: .userInitiated).async {
            // Rust invokes callbacks only before this synchronous call returns.
            // The completion block retains the attempt for that entire interval.
            let ctx = Unmanaged.passUnretained(attempt).toOpaque()
            var result = JitBridgePairResult()
            let rc = "0.0.0.0".withCString { bindC in
                "Andarium".withCString { nameC in
                    "Mac17,7".withCString { modelC in
                        outPath.withCString { outC in
                            jit_bridge_pair_host(
                                bindC,
                                0,
                                nameC,
                                modelC,
                                outC,
                                jitBridgeReadyCallback,
                                jitBridgePinCallback,
                                jitBridgeCancelledCallback,
                                ctx,
                                &result
                            )
                        }
                    }
                }
            }

            let errStr = result.error.map { String(cString: $0) } ?? ""
            let udidStr = result.device_udid.map { String(cString: $0) } ?? ""
            jit_bridge_pair_result_free(&result)
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: outURL) }
                self.attempt = nil
                guard !attempt.isCancelled else { return }
                self.stopAdvertising()
                self.endBackgroundExtension()
                self.isRunning = false

                if rc == 0 {
                    guard let data = try? Data(contentsOf: outURL),
                          let saved = JitPairingManager.shared.savePairingRecord(data: data, fileName: "rp_pairing_file.plist") else {
                        self.finishWithError("ペアリングファイルを安全に保存できませんでした。")
                        return
                    }
                    self.pairingStatus = .success(fileName: saved.lastPathComponent, udid: udidStr)
                    self.notify(
                        id: "andarium.pairing.done",
                        title: "Pairing Complete",
                        body: "The pairing record was saved. This does not enable JIT by itself."
                    )
                } else {
                    let message = errStr == "Pairing timed out."
                        ? "ペアリングがタイムアウトしました。設定で Andarium が表示されるか確認してください。"
                        : (errStr.isEmpty ? "ペアリングに失敗しました（\(rc)）。" : errStr)
                    self.lastErrorMessage = message
                    self.pairingStatus = .failed(message)
                }
            }
        }
        #else
        finishWithError("このビルドではデバイスのペアリングは利用できません。")
        #endif
    }

    func stopPairing() {
        #if canImport(JitBridgeFFI)
        attempt?.cancel()
        #endif
        stopAdvertising()
        endBackgroundExtension()
        isRunning = false
        if case .advertising = pairingStatus {
            pairingStatus = .idle
        } else if case .showPin = pairingStatus {
            pairingStatus = .idle
        }
    }

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let service = ObjectIdentifier(sender)
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        Task { @MainActor in
            guard let current = netService, ObjectIdentifier(current) == service else { return }
            finishWithError("Bonjour に登録できませんでした（\(code)）。Andarium のローカルネットワーク権限と Wi-Fi を確認してください。")
        }
    }

    fileprivate func presentPin(_ pin: String) {
        pinCode = pin
        pairingStatus = .showPin(pin)
        notify(
            id: "andarium.pairing.pin",
            title: "Andarium Pairing PIN",
            body: "Enter \(pin) in Settings > Privacy & Security > Developer Mode."
        )
    }

    private func stopAdvertising() {
        netService?.delegate = nil
        netService?.stop()
        netService = nil
    }

    private func beginBackgroundExtension() {
        endBackgroundExtension()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DeveloperModePairing") { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishWithError("ペアリングのバックグラウンド待機時間が終了しました。Andarium に戻って再試行してください。")
            }
        }
    }

    private func endBackgroundExtension() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func finishWithError(_ message: String) {
        #if canImport(JitBridgeFFI)
        attempt?.cancel()
        #endif
        stopAdvertising()
        endBackgroundExtension()
        isRunning = false
        lastErrorMessage = message
        pairingStatus = .failed(message)
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

#if canImport(JitBridgeFFI)
private nonisolated final class PairingAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    nonisolated var isCancelled: Bool { lock.withLock { cancelled } }
    nonisolated func cancel() { lock.withLock { cancelled = true } }
}

private let jitBridgeCancelledCallback: JitBridgeCancelledCb = { ctx in
    guard let ctx else { return 1 }
    return Unmanaged<PairingAttempt>.fromOpaque(ctx).takeUnretainedValue().isCancelled ? 1 : 0
}

private let jitBridgeReadyCallback: JitBridgeReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx, let serviceID else { return }
    let attempt = Unmanaged<PairingAttempt>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys, let vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }

    DispatchQueue.main.async {
        guard !attempt.isCancelled else { return }
        DeveloperModePairingService.shared.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let jitBridgePinCallback: JitBridgePinCb = { pin, ctx in
    guard let ctx, let pin else { return }
    let attempt = Unmanaged<PairingAttempt>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        guard !attempt.isCancelled else { return }
        DeveloperModePairingService.shared.presentPin(pinString)
    }
}
#endif
