// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Sheet that provides pairing file management, on-device Developer Mode pairing,
/// and a JIT self-test to verify whether JIT is actively working.
struct JitSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @ObservedObject private var pairingManager = JitPairingManager.shared
    @ObservedObject private var pairingService = DeveloperModePairingService.shared
    @ObservedObject private var internalDebugger = InternalJitDebugger.shared

    @State private var showingFilePicker = false
    @State private var showingDeleteAlert = false
    @State private var pairingToDelete: JitPairingManager.PairingRecordInfo?
    @State private var importFailed = false

    private var pairingTypes: [UTType] {
        var types: [UTType] = [.propertyList, .data]
        if let custom = UTType(filenameExtension: "mobiledevicepairing") {
            types.insert(custom, at: 0)
        }
        return types
    }

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Built-in Debugger Status & JIT Self-Test
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.badge.checkmark.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(pairingManager.activePairing?.isValid == true ? .green : .orange)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("JIT とデバイスのペアリング")
                                .font(.headline)
                            if let active = pairingManager.activePairing, active.isValid {
                                Text("登録済み: \(active.fileName)（JITの有効化とは別です）")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("ペアリングファイルは未登録です。JITの使用には対応するデバッガの接続が必要です。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            Task {
                                await internalDebugger.runJitSelfTest { await model.testJit() }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("JIT テストを実行 (動作確認)")
                                Spacer()
                                if internalDebugger.testStatus == .running {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(internalDebugger.testStatus == .running || model.driver == nil || model.guest == nil)

                        switch internalDebugger.testStatus {
                        case .notTested:
                            EmptyView()
                        case .running:
                            Text("JIT 実行可能メモリの割り当てと実行をテスト中...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        case .passed(let msg):
                            Label(msg, systemImage: "checkmark.seal.fill")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        case .interpreterOnly(let msg):
                            Label(msg, systemImage: "info.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        case .failed(let msg):
                            Label(msg, systemImage: "xmark.octagon.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("デバッガ状態 & JIT テスト")
                }

                // Section 2: Developer Mode Wireless Pairing (StikDebug-style)
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PC を使わずに、iOS の「設定 > デベロッパモード」から直接ペアリングします。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if pairingService.isRunning {
                            VStack(spacing: 10) {
                                switch pairingService.pairingStatus {
                                case .showPin(let pin):
                                    Text("ペアリング PIN コード")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(pin)
                                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                                        .tracking(6)
                                        .foregroundStyle(.tint)
                                        .padding(.vertical, 4)
                                default:
                                    ProgressView()
                                    Text("デベロッパモードからの接続を待機中...")
                                        .font(.subheadline.bold())
                                }

                                Text("手順:")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("1. 「設定」アプリを開く\n2. 「プライバシーとセキュリティ」>「デベロッパモード」を開く\n3. 画面下の「Andarium」をタップ\n4. 画面に表示された PIN コードを入力")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding()
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(12)

                            Button(role: .destructive) {
                                pairingService.stopPairing()
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("ペアリングをキャンセル")
                                    Spacer()
                                }
                            }
                        } else {
                            switch pairingService.pairingStatus {
                            case .success(let fileName, _):
                                Label("ペアリング完了: \(fileName)", systemImage: "checkmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            case .failed(let message):
                                Label("エラー: \(message)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            default:
                                EmptyView()
                            }

                            Button {
                                pairingService.startPairing()
                            } label: {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("デベロッパモードとペアリングを開始")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("デベロッパモード ペアリング (StikDebug 方式)")
                }

                // Section 3: Pairing Files Management
                Section {
                    if pairingManager.discoveredPairings.isEmpty {
                        Text("ペアリングファイルが見つかりません。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pairingManager.discoveredPairings) { info in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.fileName)
                                        .font(.body)
                                }
                                Spacer()
                                if info == pairingManager.activePairing {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pairingToDelete = info
                                    showingDeleteAlert = true
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        showingFilePicker = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            Text("ペアリングファイルを読み込む...")
                        }
                    }
                } header: {
                    Text("ペアリングファイル管理")
                } footer: {
                    Text("「ファイル」アプリの「この iPhone 内 > Andarium」に .mobiledevicepairing または .plist ファイルを直接配置することもできます。")
                }
            }
            .navigationTitle("JIT デバッガ & ペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
            .documentCopyPicker(
                isPresented: $showingFilePicker,
                types: pairingTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let copies):
                    importFailed = copies.urls.first.map { !pairingManager.importPairingFile(from: $0) } ?? true
                case .failure:
                    importFailed = true
                }
            }
            .alert("ペアリングファイルを削除", isPresented: $showingDeleteAlert, presenting: pairingToDelete) { info in
                Button("削除", role: .destructive) {
                    pairingManager.deletePairingFile(info)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { info in
                Text("'\(info.fileName)' を削除しますか？")
            }
            .onAppear {
                pairingManager.refresh()
            }
            .onDisappear {
                if pairingService.isRunning { pairingService.stopPairing() }
            }
            .alert("ペアリングファイルを読み込めませんでした", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("有効な .mobiledevicepairing または RemotePairing の .plist を選択してください。")
            }
        }
    }
}
