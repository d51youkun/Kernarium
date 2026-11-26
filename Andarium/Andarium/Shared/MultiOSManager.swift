// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation
import SwiftUI

/// OS target selectable from the Andarium Home switcher.
enum GuestOSKind: String, CaseIterable, Identifiable, Codable {
    case android
    case windows11
    case otherOS
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .android: "Android"
        case .windows11: "Windows 11"
        case .otherOS: "ISO / Other OS"
        case .terminal: "Terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .android: "LineageOS 24 (UML)"
        case .windows11: "ARM64 日本語"
        case .otherOS: "汎用 ISO ブート"
        case .terminal: "CLI コマンド"
        }
    }

    var symbolName: String {
        switch self {
        case .android: "candybarphone"
        case .windows11: "square.grid.2x2.fill"
        case .otherOS: "opticaldiscdrive.fill"
        case .terminal: "terminal.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .android: .green
        case .windows11: .blue
        case .otherOS: .purple
        case .terminal: .orange
        }
    }
}

/// Configuration for a QEMU-backed VM (Windows 11 ARM64 or generic ISO OS).
struct MultiOSProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: GuestOSKind
    var architecture: String = "aarch64"
    var language: String = "ja-JP"
    var memoryMiB: Int = 4096
    var cpuCores: Int = 4
    var isoFileName: String?
    var diskFileName: String?
    var diskSizeGiB: Int = 64
    var enableJit: Bool = true
    var enableMouseTablet: Bool = true
    var enableJapaneseKeyboard: Bool = true

    /// Builds the `qemu-system-aarch64` arguments for this VM profile.
    func qemuArguments(vmDirectory: URL) -> [String] {
        var args: [String] = [
            "qemu-system-aarch64",
            "-M", "virt,highmem=on",
            "-cpu", enableJit ? "max" : "cortex-a72",
            "-smp", "\(cpuCores)",
            "-m", "\(memoryMiB)",
            "-accel", enableJit ? "tcg,thread=multi" : "tcg,thread=single",
            "-device", "virtio-gpu-pci",
            "-device", "qemu-xhci,id=xhci"
        ]

        if enableMouseTablet {
            // USB Tablet provides absolute pointer coordinates for touch/mouse
            args += ["-device", "usb-tablet,bus=xhci.0"]
        } else {
            args += ["-device", "usb-mouse,bus=xhci.0"]
        }

        // Keyboard with Japanese locale metadata
        args += ["-device", "usb-kbd,bus=xhci.0"]
        if enableJapaneseKeyboard {
            args += ["-k", "ja"]
        }

        // Audio & Network
        args += [
            "-device", "intel-hda",
            "-device", "hda-duplex",
            "-nic", "user,model=virtio-net-pci"
        ]

        if let diskFileName {
            let diskPath = vmDirectory.appendingPathComponent(diskFileName).path
            args += ["-drive", "if=none,id=hd0,file=\(diskPath),format=qcow2",
                     "-device", "nvme,drive=hd0,serial=andarium-nvme"]
        }

        if let isoFileName {
            let isoPath = vmDirectory.appendingPathComponent(isoFileName).path
            args += ["-drive", "if=none,id=cd0,media=cdrom,file=\(isoPath)",
                     "-device", "usb-storage,drive=cd0,bus=xhci.0"]
        }

        return args
    }
}

/// Manages Windows 11 ARM64, generic ISO VMs, and disk/ISO assets under Documents/MultiOS.
@MainActor
final class MultiOSManager: ObservableObject {
    static let shared = MultiOSManager()

    @Published var selectedOS: GuestOSKind = .android
    @Published var profiles: [MultiOSProfile] = []
    @Published var importedISOs: [URL] = []
    @Published var statusLog: String = ""
    @Published var isRunningVM: Bool = false
    @Published var activeVMProfile: MultiOSProfile?

    let vmRootURL: URL
    private let profilesFileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.vmRootURL = docs.appendingPathComponent("MultiOS", isDirectory: true)
        self.profilesFileURL = vmRootURL.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: vmRootURL, withIntermediateDirectories: true)
        loadProfiles()
        ensureDefaultWindowsProfile()
        refreshISOs()
    }

    var windowsProfile: MultiOSProfile {
        profiles.first(where: { $0.kind == .windows11 }) ?? defaultWindowsProfile()
    }

    private func defaultWindowsProfile() -> MultiOSProfile {
        MultiOSProfile(
            name: "Windows 11 (ARM64 日本語)",
            kind: .windows11,
            architecture: "aarch64",
            language: "ja-JP",
            memoryMiB: 4096,
            cpuCores: 4,
            isoFileName: nil,
            diskFileName: "win11_arm64.raw",
            diskSizeGiB: 64,
            enableJit: true,
            enableMouseTablet: true,
            enableJapaneseKeyboard: true
        )
    }

    private func ensureDefaultWindowsProfile() {
        if !profiles.contains(where: { $0.kind == .windows11 }) {
            profiles.append(defaultWindowsProfile())
            saveProfiles()
        }
    }

    func updateProfile(_ profile: MultiOSProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    func createISOProfile(name: String, isoFileName: String?, ramMiB: Int = 2048, cores: Int = 2) -> MultiOSProfile {
        let safeDisk = name.replacingOccurrences(of: " ", with: "_") + ".raw"
        let profile = MultiOSProfile(
            name: name,
            kind: .otherOS,
            architecture: "aarch64",
            language: "ja-JP",
            memoryMiB: ramMiB,
            cpuCores: cores,
            isoFileName: isoFileName,
            diskFileName: safeDisk,
            diskSizeGiB: 32,
            enableJit: true,
            enableMouseTablet: true,
            enableJapaneseKeyboard: true
        )
        profiles.append(profile)
        saveProfiles()
        return profile
    }

    func deleteProfile(_ profile: MultiOSProfile) {
        guard profile.kind != .windows11 else { return }
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    func refreshISOs() {
        var isos: [URL] = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dirs = [vmRootURL, docs].compactMap { $0 }

        for dir in dirs {
            if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for url in contents {
                    let ext = url.pathExtension.lowercased()
                    if ext == "iso" || ext == "img" || ext == "vhdx" || ext == "qcow2" {
                        isos.append(url)
                    }
                }
            }
        }
        importedISOs = isos
    }

    @discardableResult
    func importDiskOrISO(from sourceURL: URL, assignTo profileID: UUID? = nil) -> URL? {
        let shouldStop = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStop { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let dest = vmRootURL.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            refreshISOs()

            if let profileID, var prof = profiles.first(where: { $0.id == profileID }) {
                let ext = dest.pathExtension.lowercased()
                if ext == "iso" || ext == "img" {
                    prof.isoFileName = dest.lastPathComponent
                } else {
                    prof.diskFileName = dest.lastPathComponent
                }
                updateProfile(prof)
            }
            statusLog = "インポート完了: \(dest.lastPathComponent)"
            return dest
        } catch {
            statusLog = "インポート失敗: \(error.localizedDescription)"
            return nil
        }
    }

    /// Whether `qemu-aarch64-softmmu.framework` is bundled and loadable.
    var qemuEngineAvailable: Bool {
        QemuRuntimeEngine.shared.isEngineAvailable
    }

    /// Launches the QEMU ARM64 backend for `profile` and returns whether it started.
    func startVM(_ profile: MultiOSProfile) async -> (jitActive: Bool, commandPreview: String) {
        let started = QemuRuntimeEngine.shared.start(profile: profile, vmDirectory: vmRootURL)
        if started {
            activeVMProfile = profile
            isRunningVM = true
            statusLog = "起動中: \(profile.name)"
        } else {
            statusLog = QemuRuntimeEngine.shared.lastError ?? "仮想マシンの起動に失敗しました。"
        }
        let args = (try? QemuRuntimeEngine.shared.buildArguments(for: profile, vmDirectory: vmRootURL))
            ?? profile.qemuArguments(vmDirectory: vmRootURL)
        let jitActive = started && profile.enableJit && InternalJitDebugger.isProcessTraced()
        return (jitActive, args.joined(separator: " "))
    }

    func stopVM() {
        QemuRuntimeEngine.shared.markStopped()
        isRunningVM = false
        activeVMProfile = nil
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesFileURL),
              let decoded = try? JSONDecoder().decode([MultiOSProfile].self, from: data) else {
            return
        }
        profiles = decoded
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesFileURL, options: .atomic)
        }
    }
}
