// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Darwin
import Foundation

/// Runs the embedded `qemu-aarch64-softmmu.framework` in-process on a dedicated
/// thread with a large stack, matching UTM's iOS execution model.
@MainActor
final class QemuRuntimeEngine: ObservableObject {
    static let shared = QemuRuntimeEngine()

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastError: String?
    @Published private(set) var vncPort: UInt16 = 5900

    private var qemuHandle: UnsafeMutableRawPointer?
    private var workerThread: pthread_t?

    private init() {}

    /// Returns the path to `qemu-aarch64-softmmu` inside the app's Frameworks directory.
    nonisolated static func qemuBinaryURL() -> URL? {
        guard let frameworksURL = Bundle.main.privateFrameworksURL else { return nil }
        let candidate = frameworksURL
            .appendingPathComponent("qemu-aarch64-softmmu.framework", isDirectory: true)
            .appendingPathComponent("qemu-aarch64-softmmu")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Returns the bundled `qemu/` resource directory containing EDK2 UEFI firmware.
    nonisolated static func qemuResourceURL() -> URL? {
        guard let resURL = Bundle.main.resourceURL?.appendingPathComponent("qemu", isDirectory: true) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: resURL.path) ? resURL : nil
    }

    var isEngineAvailable: Bool {
        Self.qemuBinaryURL() != nil
    }

    /// Ensures a sparse virtual disk file exists at `diskURL`.
    func ensureSparseDisk(at diskURL: URL, sizeGiB: Int) throws {
        if FileManager.default.fileExists(atPath: diskURL.path) { return }
        let parent = diskURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let fd = open(diskURL.path, O_CREAT | O_RDWR | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        let bytes = off_t(max(sizeGiB, 4)) * 1024 * 1024 * 1024
        guard ftruncate(fd, bytes) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Ensures a per-VM writable UEFI NVRAM file exists.
    func ensureUefiVars(for profileID: UUID, in vmDirectory: URL) -> URL? {
        let varsURL = vmDirectory.appendingPathComponent("\(profileID.uuidString)-edk2-vars.fd")
        if FileManager.default.fileExists(atPath: varsURL.path) {
            return varsURL
        }
        guard let resDir = Self.qemuResourceURL() else { return nil }
        let template = resDir.appendingPathComponent("edk2-arm-vars.fd")
        guard FileManager.default.fileExists(atPath: template.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: template, to: varsURL)
            return varsURL
        } catch {
            return nil
        }
    }

    /// Builds the full QEMU argument list for booting Windows 11 ARM64 or a generic ARM64 ISO.
    func buildArguments(for profile: MultiOSProfile, vmDirectory: URL, displayIndex: Int = 0) throws -> [String] {
        var args: [String] = ["qemu-system-aarch64"]

        if let resDir = Self.qemuResourceURL() {
            args += ["-L", resDir.path]
            let codeURL = resDir.appendingPathComponent("edk2-aarch64-code.fd")
            if FileManager.default.fileExists(atPath: codeURL.path) {
                args += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(codeURL.path)"]
            }
            if let varsURL = ensureUefiVars(for: profile.id, in: vmDirectory) {
                args += ["-drive", "if=pflash,format=raw,unit=1,file=\(varsURL.path)"]
            }
        }

        let accel = profile.enableJit ? "tcg,thread=multi" : "tcg,thread=single"
        args += [
            "-M", "virt,highmem=on",
            "-accel", accel,
            "-cpu", "max",
            "-smp", "\(max(profile.cpuCores, 1))",
            "-m", "\(max(profile.memoryMiB, 512))",
            "-device", "ramfb",
            "-device", "qemu-xhci,id=xhci",
            "-device", profile.enableMouseTablet ? "usb-tablet,bus=xhci.0" : "usb-mouse,bus=xhci.0",
            "-device", "usb-kbd,bus=xhci.0",
            "-nic", "user,model=virtio-net-pci",
            "-vnc", "127.0.0.1:\(displayIndex)",
            "-monitor", "none",
            "-serial", "none",
        ]

        if profile.enableJapaneseKeyboard {
            args += ["-k", "ja"]
        }

        if let diskFileName = profile.diskFileName {
            let diskURL = vmDirectory.appendingPathComponent(diskFileName)
            let ext = diskURL.pathExtension.lowercased()
            let format = (ext == "qcow2") ? "qcow2" : (ext == "vhdx" ? "vhdx" : "raw")
            if format == "raw" {
                try ensureSparseDisk(at: diskURL, sizeGiB: profile.diskSizeGiB)
            }
            if FileManager.default.fileExists(atPath: diskURL.path) {
                args += [
                    "-drive", "if=none,id=hd0,file=\(diskURL.path),format=\(format)",
                    "-device", "nvme,drive=hd0,serial=andarium-nvme",
                ]
            }
        }

        if let isoFileName = profile.isoFileName {
            let isoURL = vmDirectory.appendingPathComponent(isoFileName)
            if FileManager.default.fileExists(atPath: isoURL.path) {
                args += [
                    "-drive", "if=none,id=cd0,media=cdrom,readonly=on,file=\(isoURL.path)",
                    "-device", "usb-storage,drive=cd0,bus=xhci.0",
                ]
            }
        }

        return args
    }

    /// Launches QEMU in-process on a dedicated 8 MiB stack thread.
    func start(profile: MultiOSProfile, vmDirectory: URL) -> Bool {
        guard !isRunning else { return true }
        guard let binaryURL = Self.qemuBinaryURL() else {
            lastError = "qemu-aarch64-softmmu.framework がバンドルに含まれていません。"
            statusMessage = lastError ?? ""
            return false
        }

        let args: [String]
        do {
            args = try buildArguments(for: profile, vmDirectory: vmDirectory, displayIndex: 0)
        } catch {
            lastError = "仮想ディスクの準備に失敗しました: \(error.localizedDescription)"
            statusMessage = lastError ?? ""
            return false
        }

        let handle: UnsafeMutableRawPointer
        if let existing = qemuHandle {
            handle = existing
        } else {
            guard let opened = dlopen(binaryURL.path, RTLD_LOCAL | RTLD_LAZY) else {
                let err = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
                lastError = "QEMU の読み込みに失敗しました: \(err)"
                statusMessage = lastError ?? ""
                return false
            }
            qemuHandle = opened
            handle = opened
        }

        guard let initSym = dlsym(handle, "qemu_init"),
              let loopSym = dlsym(handle, "qemu_main_loop"),
              let cleanupSym = dlsym(handle, "qemu_cleanup") else {
            lastError = "QEMU エントリポイント (qemu_init/qemu_main_loop/qemu_cleanup) が見つかりません。"
            statusMessage = lastError ?? ""
            return false
        }

        isRunning = true
        lastError = nil
        vncPort = 5900
        statusMessage = "QEMU ARM64 を起動中..."

        let box = QemuLaunchBox(
            args: args,
            qemuInit: unsafeBitCast(initSym, to: QemuInitFn.self),
            qemuMainLoop: unsafeBitCast(loopSym, to: QemuVoidFn.self),
            qemuCleanup: unsafeBitCast(cleanupSym, to: QemuVoidFn.self)
        ) { [weak self] in
            Task { @MainActor in
                self?.isRunning = false
                self?.statusMessage = "仮想マシンが終了しました。"
            }
        }

        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_setstacksize(&attr, 8 * 1024 * 1024)
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED)

        var thread: pthread_t?
        let rawBox = Unmanaged.passRetained(box).toOpaque()
        let rc = pthread_create(&thread, &attr, qemuThreadEntry, rawBox)
        pthread_attr_destroy(&attr)

        if rc != 0 {
            Unmanaged<QemuLaunchBox>.fromOpaque(rawBox).release()
            isRunning = false
            lastError = "QEMU スレッドの作成に失敗しました (errno \(rc))。"
            statusMessage = lastError ?? ""
            return false
        }

        workerThread = thread
        return true
    }

    func markStopped() {
        isRunning = false
        statusMessage = "停止しました。"
    }
}

private typealias QemuInitFn = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
private typealias QemuVoidFn = @convention(c) () -> Void

private nonisolated final class QemuLaunchBox {
    let args: [String]
    let qemuInit: QemuInitFn
    let qemuMainLoop: QemuVoidFn
    let qemuCleanup: QemuVoidFn
    let onExit: @Sendable () -> Void

    init(
        args: [String],
        qemuInit: @escaping QemuInitFn,
        qemuMainLoop: @escaping QemuVoidFn,
        qemuCleanup: @escaping QemuVoidFn,
        onExit: @escaping @Sendable () -> Void
    ) {
        self.args = args
        self.qemuInit = qemuInit
        self.qemuMainLoop = qemuMainLoop
        self.qemuCleanup = qemuCleanup
        self.onExit = onExit
    }
}

private nonisolated func qemuThreadEntry(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let raw else { return nil }
    let box = Unmanaged<QemuLaunchBox>.fromOpaque(raw).takeRetainedValue()
    var cStrings: [UnsafeMutablePointer<CChar>?] = box.args.map { strdup($0) }
    cStrings.append(nil)
    defer {
        for ptr in cStrings {
            if let ptr { free(ptr) }
        }
        box.onExit()
    }
    let argc = Int32(box.args.count)
    cStrings.withUnsafeMutableBufferPointer { buf in
        box.qemuInit(argc, buf.baseAddress)
    }
    box.qemuMainLoop()
    box.qemuCleanup()
    return nil
}
