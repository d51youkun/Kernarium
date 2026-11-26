// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Screen for importing arbitrary OS ISO images and running them as ARM64 VMs.
struct OtherOSHomeView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var manager = MultiOSManager.shared

    @State private var showingISOPicker = false
    @State private var showingNewVMAlert = false
    @State private var newVMName = "Linux (ARM64 ISO)"
    @State private var activeSessionProfile: MultiOSProfile?
    @State private var lastCommandPreview = ""
    @State private var lastJitActive = false

    private var isoTypes: [UTType] {
        var types: [UTType] = [.data]
        for ext in ["iso", "img", "qcow2"] {
            if let t = UTType(filenameExtension: ext) {
                types.insert(t, at: 0)
            }
        }
        return types
    }

    private var customProfiles: [MultiOSProfile] {
        manager.profiles.filter { $0.kind == .otherOS }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showingISOPicker = true
                } label: {
                    Label("ISO / ディスクイメージを読み込む...", systemImage: "opticaldiscdrive.fill")
                }

                Button {
                    newVMName = "Custom OS \(customProfiles.count + 1)"
                    showingNewVMAlert = true
                } label: {
                    Label("新しい汎用 OS (ISO) を作成", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("ISO & 汎用 OS 作成")
            }

            Section {
                if customProfiles.isEmpty {
                    Text("汎用 OS プロファイルはまだありません。\nISO を読み込むか、新規作成してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.headline)
                                Text("RAM: \(profile.memoryMiB) MB / CPU: \(profile.cpuCores) コア / \(profile.isoFileName ?? "ISO 未設定")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("起動") {
                                Task {
                                    let res = await manager.startVM(profile)
                                    lastJitActive = res.jitActive
                                    lastCommandPreview = res.commandPreview
                                    activeSessionProfile = profile
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(!manager.qemuEngineAvailable)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                manager.deleteProfile(profile)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("登録済み OS プロファイル")
            }

            Section {
                if manager.importedISOs.isEmpty {
                    Text("インポートされた ISO / イメージはありません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.importedISOs, id: \.path) { url in
                        HStack {
                            Image(systemName: "opticaldisc")
                                .foregroundStyle(.purple)
                            Text(url.lastPathComponent)
                                .font(.subheadline)
                            Spacer()
                            Button("VM 作成") {
                                let name = url.deletingPathExtension().lastPathComponent
                                _ = manager.createISOProfile(name: name, isoFileName: url.lastPathComponent)
                            }
                            .font(.caption.bold())
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("インポート済み ISO / イメージ")
            } footer: {
                Text("「ファイル」アプリの Documents/MultiOS/ フォルダに置いた .iso / .img ファイルも自動認識されます。")
            }
        }
        .documentCopyPicker(
            isPresented: $showingISOPicker,
            types: isoTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let copies) = result, let first = copies.urls.first {
                manager.importDiskOrISO(from: first)
            }
        }
        .alert("新規汎用 OS 作成", isPresented: $showingNewVMAlert) {
            TextField("OS 名", text: $newVMName)
            Button("作成") {
                let isoName = manager.importedISOs.first?.lastPathComponent
                _ = manager.createISOProfile(name: newVMName, isoFileName: isoName)
            }
            Button("キャンセル", role: .cancel) {}
        }
        .fullScreenCover(item: $activeSessionProfile) { profile in
            MultiOSSessionView(
                profile: profile,
                jitActive: lastJitActive,
                qemuCommand: lastCommandPreview
            )
        }
    }
}
