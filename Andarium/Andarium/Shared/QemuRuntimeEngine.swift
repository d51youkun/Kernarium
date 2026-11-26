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
    private(set) var displaySocket: URL?

    private var qemuHandle: UnsafeMutableRawPointer?
    private var workerThread: pthread_t?
    private var hasLaunched = false

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

    /// Present only in a locally packaged build that includes installation media.
    nonisolated static var bundledWindowsISO: URL? {
        Bundle.main.url(forResource: "Windows11-arm64-ja-JP", withExtension: "iso", subdirectory: "qemu")
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
    func buildArguments(for profile: MultiOSProfile, vmDirectory: URL, display: URL) throws -> [String] {
        func drivePath(_ url: URL) -> String { url.path.replacingOccurrences(of: ",", with: ",,") }
        func mediaURL(_ name: String) throws -> URL {
            guard !name.isEmpty, !name.hasPrefix("."), name == (name as NSString).lastPathComponent else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let url = vmDirectory.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return url
        }
        var args: [String] = ["qemu-system-aarch64"]

        if let resDir = Self.qemuResourceURL() {
            args += ["-L", resDir.path]
            let codeURL = resDir.appendingPathComponent("edk2-aarch64-code.fd")
            if FileManager.default.fileExists(atPath: codeURL.path) {
                args += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(drivePath(codeURL))"]
            }
            if let varsURL = ensureUefiVars(for: profile.id, in: vmDirectory) {
                args += ["-drive", "if=pflash,format=raw,unit=1,file=\(drivePath(varsURL))"]
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
            "-vnc", "unix:\(display.path.replacingOccurrences(of: ",", with: ",,"))",
            "-monitor", "none",
            "-serial", "none",
        ]

        if profile.enableJapaneseKeyboard {
            args += ["-k", "ja"]
        }

        if let diskFileName = profile.diskFileName {
            let diskURL = try mediaURL(diskFileName)
            let ext = diskURL.pathExtension.lowercased()
            let format = (ext == "qcow2") ? "qcow2" : (ext == "vhdx" ? "vhdx" : "raw")
            if format == "raw" {
                try ensureSparseDisk(at: diskURL, sizeGiB: profile.diskSizeGiB)
            }
            if FileManager.default.fileExists(atPath: diskURL.path) {
                args += [
                    "-drive", "if=none,id=hd0,file=\(drivePath(diskURL)),format=\(format)",
                    "-device", "nvme,drive=hd0,serial=andarium-nvme",
                ]
            }
        }

        let installer = try profile.isoFileName.map { try mediaURL($0) }
            ?? (profile.kind == .windows11 ? Self.bundledWindowsISO : nil)
        if let isoURL = installer {
            if FileManager.default.fileExists(atPath: isoURL.path) {
                args += [
                    "-drive", "if=none,id=cd0,media=cdrom,readonly=on,format=raw,file=\(drivePath(isoURL))",
                    "-device", "usb-storage,drive=cd0,bus=xhci.0",
                ]
            }
        }

        return args
    }

    /// Launches QEMU in-process on a dedicated 8 MiB stack thread.
    func start(profile: MultiOSProfile, vmDirectory: URL) -> Bool {
        guard !isRunning, !hasLaunched else {
            lastError = "別のセッションを開始するにはAndariumを開き直してください。"
            return false
        }
        #if os(iOS)
        guard InternalJitDebugger.isProcessTraced() else {
            lastError = "このQEMUビルドの起動には対応デバッガが必要です。ペアリングだけではJITは有効になりません。"
            return false
        }
        #endif
        guard let binaryURL = Self.qemuBinaryURL() else {
            lastError = "qemu-aarch64-softmmu.framework がバンドルに含まれていません。"
            statusMessage = lastError ?? ""
            return false
        }

        let socketDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        let socket = socketDirectory.appendingPathComponent("a-\(UUID().uuidString.prefix(8)).vnc")
        guard socket.path.utf8.count < 104 else {
            lastError = "画面接続用のソケットパスが長すぎます。"
            return false
        }
        let args: [String]
        do {
            args = try buildArguments(for: profile, vmDirectory: vmDirectory, display: socket)
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
        displaySocket = socket
        statusMessage = "QEMU ARM64 を起動中..."

        let box = QemuLaunchBox(
            args: args,
            qemuInit: unsafeBitCast(initSym, to: QemuInitFn.self),
            qemuMainLoop: unsafeBitCast(loopSym, to: QemuVoidFn.self),
            qemuCleanup: unsafeBitCast(cleanupSym, to: QemuVoidFn.self)
        ) { [weak self] result in
            try? FileManager.default.removeItem(at: socket)
            Task { @MainActor in
                self?.isRunning = false
                self?.displaySocket = nil
                if result == 0 {
                    self?.statusMessage = "仮想マシンが終了しました。"
                } else {
                    self?.lastError = "QEMUの初期化に失敗しました（\(result)）。"
                }
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
            displaySocket = nil
            lastError = "QEMU スレッドの作成に失敗しました (errno \(rc))。"
            statusMessage = lastError ?? ""
            return false
        }

        workerThread = thread
        hasLaunched = true
        return true
    }

    func markStopped() {
        if isRunning { statusMessage = "仮想マシンは実行中です。ゲスト側からシャットダウンしてください。" }
    }
}

private typealias QemuInitFn = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32
private typealias QemuVoidFn = @convention(c) () -> Void

private nonisolated final class QemuLaunchBox {
    let args: [String]
    let qemuInit: QemuInitFn
    let qemuMainLoop: QemuVoidFn
    let qemuCleanup: QemuVoidFn
    let onExit: @Sendable (Int32) -> Void

    init(
        args: [String],
        qemuInit: @escaping QemuInitFn,
        qemuMainLoop: @escaping QemuVoidFn,
        qemuCleanup: @escaping QemuVoidFn,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.args = args
        self.qemuInit = qemuInit
        self.qemuMainLoop = qemuMainLoop
        self.qemuCleanup = qemuCleanup
        self.onExit = onExit
    }
}

private nonisolated func qemuThreadEntry(_ raw: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let box = Unmanaged<QemuLaunchBox>.fromOpaque(raw).takeRetainedValue()
    var cStrings: [UnsafeMutablePointer<CChar>?] = box.args.map { strdup($0) }
    cStrings.append(nil)
    var result: Int32 = -1
    defer {
        for ptr in cStrings {
            if let ptr { free(ptr) }
        }
        box.onExit(result)
    }
    let argc = Int32(box.args.count)
    let argv = cStrings.map { $0.map { UnsafePointer($0) } }
    let envp: [UnsafePointer<CChar>?] = [nil]
    result = argv.withUnsafeBufferPointer { args in
        envp.withUnsafeBufferPointer { environment in box.qemuInit(argc, args.baseAddress, environment.baseAddress) }
    }
    guard result == 0 else { return nil }
    box.qemuMainLoop()
    box.qemuCleanup()
    return nil
}
