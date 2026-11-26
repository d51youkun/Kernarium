// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Dedicated Windows 11 ARM64 (Japanese) management & launch screen in Andarium.
struct WindowsHomeView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var manager = MultiOSManager.shared
    @ObservedObject private var pairingManager = JitPairingManager.shared

    @State private var showingISOPicker = false
    @State private var showingISOGuide = false
    @State private var showingJitSettings = false
    @State private var showingSession = false
    @State private var lastCommandPreview = ""
    @State private var lastJitActive = false
    @State private var launchError: String?

    private var winProfile: MultiOSProfile {
        manager.windowsProfile
    }

    private var diskAndISOTypes: [UTType] {
        var types: [UTType] = [.data]
        for ext in ["iso", "img", "vhdx", "qcow2"] {
            if let t = UTType(filenameExtension: ext) {
                types.insert(t, at: 0)
            }
        }
        return types
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.blue.gradient)
                                .frame(width: 56, height: 56)
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Windows 11 (ARM64)")
                                .font(.title3.bold())
                            Text("日本語版インストールメディアの案内")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Divider()

                    HStack {
                        Label("アーキテクチャ: ARM64 (aarch64)", systemImage: "cpu")
                        Spacer()
                        Label("言語: 日本語 (ja-JP)", systemImage: "globe")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(16)

                // Hardware & Input Settings Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("仮想マシン設定")
                        .font(.headline)

                    HStack {
                        Text("メモリ (RAM)")
                        Spacer()
                        Picker("RAM", selection: Binding(
                            get: { winProfile.memoryMiB },
                            set: { newVal in
                                var p = winProfile
                                p.memoryMiB = newVal
                                manager.updateProfile(p)
                            }
                        )) {
                            Text("2 GB").tag(2048)
                            Text("4 GB").tag(4096)
                            Text("6 GB").tag(6144)
                            Text("8 GB").tag(8192)
                        }
                        .pickerStyle(.menu)
                    }

                    Divider()

                    HStack {
                        Text("CPU コア数")
                        Spacer()
                        Picker("Cores", selection: Binding(
                            get: { winProfile.cpuCores },
                            set: { newVal in
                                var p = winProfile
                                p.cpuCores = newVal
                                manager.updateProfile(p)
                            }
                        )) {
                            Text("2 コア").tag(2)
                            Text("4 コア").tag(4)
                            Text("6 コア").tag(6)
                        }
                        .pickerStyle(.menu)
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { winProfile.enableMouseTablet },
                        set: { val in
                            var p = winProfile
                            p.enableMouseTablet = val
                            manager.updateProfile(p)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("マウス / タッチポインタ (USB Tablet)")
                            Text("仮想マシンの構成項目。現在のビルドでは使用できません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { winProfile.enableJapaneseKeyboard },
                        set: { val in
                            var p = winProfile
                            p.enableJapaneseKeyboard = val
                            manager.updateProfile(p)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日本語キーボード (JIS 106/109)")
                            Text("仮想マシンの構成項目。現在のビルドでは使用できません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(16)

                // Built-in JIT Card
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { winProfile.enableJit },
                        set: { val in
                            var p = winProfile
                            p.enableJit = val
                            manager.updateProfile(p)
                        }
                    )) {
                        Label("Windows の JIT 構成", systemImage: "bolt.fill")
                            .font(.headline)
                    }

                    HStack {
                        if pairingManager.activePairing?.isValid == true {
                            Label("ペアリングファイルあり（Windows の JIT は未対応）", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("ペアリングファイル未設定 (低速モード)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("JIT 設定・テスト") {
                            showingJitSettings = true
                        }
                        .font(.caption.bold())
                    }
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(16)

                // ISO / Image Selection Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("インストール ISO / 仮想ディスク")
                        .font(.headline)

                    if let iso = winProfile.isoFileName {
                        Label("ISO: \(iso)", systemImage: "opticaldisc.fill")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    } else if QemuRuntimeEngine.bundledWindowsISO != nil {
                        Label("内蔵の Windows 11 ARM64 日本語 ISO", systemImage: "opticaldisc.fill")
                            .font(.subheadline)
                    } else {
                        Text("Windows 11 ARM64 ISO が未選択です。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            showingISOPicker = true
                        } label: {
                            Label("ISO / VHDX を選択", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            showingISOGuide = true
                        } label: {
                            Label("ISO の入手方法 (UTM 方式)", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(16)

                // Launch Button
                Button {
                    Task {
                        let res = await manager.startVM(winProfile)
                        guard QemuRuntimeEngine.shared.isRunning else {
                            launchError = manager.statusLog
                            return
                        }
                        lastJitActive = res.jitActive
                        lastCommandPreview = res.commandPreview
                        showingSession = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Windows 11 (ARM64 日本語) を起動")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!manager.qemuEngineAvailable)
            }
            .padding()
        }
        .documentCopyPicker(
            isPresented: $showingISOPicker,
            types: diskAndISOTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let copies) = result, let first = copies.urls.first {
                manager.importDiskOrISO(from: first, assignTo: winProfile.id)
            }
        }
        .sheet(isPresented: $showingISOGuide) {
            WindowsISOGuideSheet()
        }
        .alert("Windowsを起動できませんでした", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
        .sheet(isPresented: $showingJitSettings) {
            JitSettingsSheet()
                .environment(model)
        }
        .fullScreenCover(isPresented: $showingSession) {
            MultiOSSessionView(
                profile: winProfile,
                jitActive: lastJitActive,
                qemuCommand: lastCommandPreview
            )
        }
    }
}

/// Guide sheet explaining how to obtain Windows 11 ARM64 Japanese ISO (UTM / Microsoft / CrystalFetch).
struct WindowsISOGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("このビルドでは Windows や ISO を起動できません。Android は従来どおり動作します。", systemImage: "info.circle")
                }
                Section("方法 1: Microsoft 公式から直接ダウンロード (推奨)") {
                    Text("Microsoft は Windows 11 ARM64 版の公式 ISO イメージを無償公開しています。言語で「日本語 (Japanese)」を選択してダウンロードできます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        if let url = URL(string: "https://www.microsoft.com/ja-jp/software-download/windows11arm64") {
                            openURL(url)
                        }
                    } label: {
                        Label("Microsoft 公式ダウンロードページを開く", systemImage: "safari.fill")
                    }
                }

                Section("方法 2: UTM / CrystalFetch (UUP dump) を使う") {
                    Text("Windows 11 ARM64 のインストールイメージや仮想マシンの設定については、UTM のガイドを参照してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        if let url = URL(string: "https://docs.getutm.app/guides/windows/") {
                            openURL(url)
                        }
                    } label: {
                        Label("UTM Windows 11 ガイドを見る", systemImage: "book.fill")
                    }
                }

            }
            .navigationTitle("Windows 11 ARM64 ISO 入手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

/// Interactive VM display backed by `QemuRuntimeEngine` and `VncClient` with
/// absolute mouse/touch pointer, right-click, and Japanese keyboard toolbar.
struct MultiOSSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MultiOSManager.shared
    @ObservedObject private var engine = QemuRuntimeEngine.shared
    @StateObject private var vnc = VncClient()

    let profile: MultiOSProfile
    let jitActive: Bool
    let qemuCommand: String

    @State private var lastPoint: (x: Int, y: Int) = (0, 0)
    @State private var showKeyboardBar: Bool = true
    @State private var typedText: String = ""

    private func mapToFramebuffer(_ location: CGPoint, in size: CGSize) -> (x: Int, y: Int) {
        let fbW = max(vnc.framebufferWidth, 1)
        let fbH = max(vnc.framebufferHeight, 1)
        let scale = min(size.width / CGFloat(fbW), size.height / CGFloat(fbH))
        let drawW = CGFloat(fbW) * scale
        let drawH = CGFloat(fbH) * scale
        let originX = (size.width - drawW) / 2
        let originY = (size.height - drawH) / 2
        let nx = (location.x - originX) / max(drawW, 1)
        let ny = (location.y - originY) / max(drawH, 1)
        let x = Int(max(0, min(1, nx)) * CGFloat(fbW - 1))
        let y = Int(max(0, min(1, ny)) * CGFloat(fbH - 1))
        return (x, y)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(role: .destructive) {
                    vnc.disconnect()
                    manager.stopVM()
                    dismiss()
                } label: {
                    Label("終了", systemImage: "power")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.bordered)

                Spacer()

                VStack(spacing: 2) {
                    Text(profile.name)
                        .font(.caption.bold())
                    Text(vnc.isConnected ? vnc.statusText : engine.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(vnc.isConnected ? .green : .orange)
                }

                Spacer()

                Button {
                    showKeyboardBar.toggle()
                } label: {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

            GeometryReader { geo in
                ZStack {
                    Color.black

                    if let image = vnc.frameImage {
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(.white)
                            Text(engine.lastError ?? vnc.statusText)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pt = mapToFramebuffer(value.location, in: geo.size)
                            lastPoint = pt
                            vnc.sendPointer(x: pt.x, y: pt.y, buttons: 1)
                        }
                        .onEnded { value in
                            let pt = mapToFramebuffer(value.location, in: geo.size)
                            lastPoint = pt
                            vnc.sendPointer(x: pt.x, y: pt.y, buttons: 0)
                        }
                )
            }

            if showKeyboardBar {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Esc") {
                            vnc.sendKey(keysym: 0xff1b, down: true)
                            vnc.sendKey(keysym: 0xff1b, down: false)
                        }
                        Button("Win") {
                            vnc.sendKey(keysym: 0xffeb, down: true)
                            vnc.sendKey(keysym: 0xffeb, down: false)
                        }
                        Button("Ctrl+Alt+Del") {
                            vnc.sendKey(keysym: 0xffe3, down: true)
                            vnc.sendKey(keysym: 0xffe9, down: true)
                            vnc.sendKey(keysym: 0xffff, down: true)
                            vnc.sendKey(keysym: 0xffff, down: false)
                            vnc.sendKey(keysym: 0xffe9, down: false)
                            vnc.sendKey(keysym: 0xffe3, down: false)
                        }
                        Button("右クリック") {
                            vnc.sendPointer(x: lastPoint.x, y: lastPoint.y, buttons: 4)
                            vnc.sendPointer(x: lastPoint.x, y: lastPoint.y, buttons: 0)
                        }
                        Button("全角/半角") {
                            vnc.sendKey(keysym: 0xff2a, down: true)
                            vnc.sendKey(keysym: 0xff2a, down: false)
                        }
                        TextField("テキスト入力...", text: $typedText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 160)
                            .onSubmit {
                                if !typedText.isEmpty {
                                    vnc.sendText(typedText)
                                    typedText = ""
                                }
                            }
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .padding(8)
                }
                .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .onAppear {
            if let socket = engine.displaySocket { vnc.connect(socket: socket) }
        }
        .onDisappear {
            vnc.disconnect()
        }
    }
}
