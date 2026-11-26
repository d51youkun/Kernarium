// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Darwin
import Foundation
import Network

/// Built-in JIT debugger and JIT self-test utility.
@MainActor
final class InternalJitDebugger: ObservableObject {
    static let shared = InternalJitDebugger()

    @Published private(set) var isPreparing: Bool = false
    @Published private(set) var lastResult: String?
    @Published private(set) var isReady: Bool = false
    @Published private(set) var testStatus: JitTestResult = .notTested

    enum JitTestResult: Equatable {
        case notTested
        case running
        case passed(String)
        case interpreterOnly(String)
        case failed(String)
    }

    private init() {}

    /// Whether the built-in debugger is available (pairing file exists).
    var isAvailable: Bool {
        JitPairingManager.shared.activePairing?.isValid ?? false
    }

    /// Checks via sysctl if P_TRACED is currently set on this process.
    nonisolated static func isProcessTraced() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Runs a safe JIT diagnostic test and reports whether JIT execution is active.
    func runJitSelfTest(runtimeTest: (() async -> JitAnswer)? = nil) async {
        testStatus = .running
        let traced = Self.isProcessTraced()
        let hasPairing = isAvailable

        if let runtimeTest {
            let answer = await runtimeTest()
            switch answer {
            case .ready:
                isReady = true
                testStatus = .passed("JIT テスト成功: 実行可能メモリの書き込みとネイティブ ARM64 命令の実行を確認しました。")
            case .noDebugger:
                isReady = false
                if hasPairing {
                    testStatus = .interpreterOnly("ペアリングファイルは検出済みですが、現在デバッガがプロセスにアタッチされていません (P_TRACED=0)。LocalDevVPN / StikDebug 等でアタッチするか、インタープリタモードで動作します。")
                } else {
                    testStatus = .interpreterOnly("デバッガ未接続 (P_TRACED=0): 現在はインタープリタモードで動作します。")
                }
            case .failed:
                isReady = false
                testStatus = .failed("JIT テスト失敗: 実行可能ページの作成またはテスト実行に失敗しました。")
            case .unsupported:
                isReady = false
                testStatus = .interpreterOnly("この環境（シミュレータ等）ではハードウェア JIT はサポートされていません。")
            case .otherSettings:
                isReady = false
                testStatus = .interpreterOnly("別のCPUまたはメモリ設定でJITが準備されています。アプリを開き直してください。")
            case .disabled:
                isReady = false
                testStatus = .interpreterOnly("JIT は現在オフに設定されています。")
            }
            return
        }

        // Fallback check when invoked without runtimeTest closure
        if traced {
            testStatus = .interpreterOnly("デバッガの接続のみ確認しました。JITコードの実行は未確認です。")
        } else if hasPairing {
            testStatus = .interpreterOnly("ペアリングファイル検出済み (P_TRACED=0): JIT を使うにはデバッガアタッチが必要です。")
        } else {
            testStatus = .interpreterOnly("デバッガ未接続・ペアリングファイル未設定 (インタープリタ動作)。")
        }
    }

}
