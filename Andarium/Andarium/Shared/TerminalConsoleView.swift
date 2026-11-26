// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import SwiftUI
/// Built-in terminal command console exposing VM, ISO, Windows, JIT, and Pairing commands.
struct TerminalConsoleView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var manager = MultiOSManager.shared
    @ObservedObject private var pairingManager = JitPairingManager.shared
    @ObservedObject private var pairingService = DeveloperModePairingService.shared
    @ObservedObject private var internalDebugger = InternalJitDebugger.shared

    @State private var commandInput = ""
    @State private var outputLines: [String] = [
        "Andarium Multi-OS & JIT Terminal v1.1",
        "Type 'help' to list available commands."
    ]
    @State private var launchedProfile: MultiOSProfile?
    @State private var launchedJitActive = false
    @State private var launchedQemuCmd = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(outputLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("andarium>") ? .cyan : .green)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black)
                .onChange(of: outputLines.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }

            // Quick command chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["help", "vm list", "iso list", "jit status", "jit test", "pair status", "windows setup"], id: \.self) { cmd in
                        Button(cmd) {
                            runCommand(cmd)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(uiColor: .secondarySystemBackground))

            // Input bar
            HStack(spacing: 8) {
                Text("andarium>")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)

                TextField("コマンドを入力 (例: help, vm list, jit test)...", text: $commandInput)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        let cmd = commandInput
                        commandInput = ""
                        runCommand(cmd)
                    }

                Button("実行") {
                    let cmd = commandInput
                    commandInput = ""
                    runCommand(cmd)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(10)
            .background(Color(uiColor: .systemBackground))
        }
        .fullScreenCover(item: $launchedProfile) { profile in
            MultiOSSessionView(
                profile: profile,
                jitActive: launchedJitActive,
                qemuCommand: launchedQemuCmd
            )
        }
    }

    private func append(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            outputLines.append(String(line))
        }
    }

    private func runCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        outputLines.append("andarium> \(trimmed)")

        let parts = trimmed.split(separator: " ").map(String.init)
        let cmd = parts[0].lowercased()
        let args = Array(parts.dropFirst())

        switch cmd {
        case "help":
            append("""
            Available commands:
              help                     Show this help
              uname -a                 Show host runtime info
              vm list                  List Android, Windows 11, and ISO VMs
              vm create <name>         Create a new ARM64 ISO VM profile
              vm start <name|windows>  Start a VM profile
              iso list                 List imported .iso / .img / .vhdx files
              windows setup            Configure Windows 11 ARM64 (ja-JP)
              jit status               Show pairing & P_TRACED status
              jit test                 Run live JIT execution test
              pair status              Show Developer Mode pairing status
              pair start               Start Developer Mode Bonjour pairing
              qemu-system-aarch64 ...  Preview/launch QEMU command line
              clear                    Clear terminal output
            """)

        case "clear":
            outputLines.removeAll()

        case "uname":
            append("Kernarium/Andarium Darwin ARM64 Host (UML + Multi-OS QEMU Bridge)")

        case "vm":
            handleVMCommand(args)

        case "iso":
            manager.refreshISOs()
            if manager.importedISOs.isEmpty {
                append("No ISO/disk images found in Documents/MultiOS.")
            } else {
                for url in manager.importedISOs {
                    append("  - \(url.lastPathComponent)")
                }
            }

        case "windows":
            let prof = manager.windowsProfile
            append("Windows 11 ARM64 (ja-JP) ready:")
            append("  RAM: \(prof.memoryMiB) MiB, CPU: \(prof.cpuCores) cores")
            append("  Mouse: usb-tablet (\(prof.enableMouseTablet)), Keyboard: ja (\(prof.enableJapaneseKeyboard))")
            append("  ISO: \(prof.isoFileName ?? "(not set)")")
            append("  CMD: \(prof.qemuArguments(vmDirectory: manager.vmRootURL).joined(separator: " "))")

        case "jit":
            handleJitCommand(args)

        case "pair":
            handlePairCommand(args)

        case "qemu-system-aarch64":
            let custom = MultiOSProfile(
                name: "CLI Custom QEMU",
                kind: .otherOS,
                isoFileName: manager.importedISOs.first?.lastPathComponent
            )
            Task {
                let res = await manager.startVM(custom)
                launchedJitActive = res.jitActive
                launchedQemuCmd = trimmed
                launchedProfile = custom
            }

        default:
            append("Unknown command: \(cmd). Type 'help' for usage.")
        }
    }

    private func handleVMCommand(_ args: [String]) {
        guard let sub = args.first?.lowercased() else {
            append("Usage: vm <list|create|start>")
            return
        }
        switch sub {
        case "list":
            append("  [Android] LineageOS 24 (UML Native)")
            for p in manager.profiles {
                append("  [\(p.kind.title)] \(p.name) (RAM: \(p.memoryMiB)MB, JIT: \(p.enableJit))")
            }
        case "create":
            let name = args.dropFirst().joined(separator: " ")
            let finalName = name.isEmpty ? "CustomOS" : name
            let p = manager.createISOProfile(name: finalName, isoFileName: manager.importedISOs.first?.lastPathComponent)
            append("Created VM '\(p.name)' (id: \(p.id.uuidString.prefix(8)))")
        case "start":
            guard manager.qemuEngineAvailable else {
                append("VM start unavailable: this build has no virtual machine backend.")
                return
            }
            let target = args.dropFirst().joined(separator: " ").lowercased()
            if target.contains("win") {
                let prof = manager.windowsProfile
                Task {
                    let res = await manager.startVM(prof)
                    launchedJitActive = res.jitActive
                    launchedQemuCmd = res.commandPreview
                    launchedProfile = prof
                }
            } else if let found = manager.profiles.first(where: { $0.name.lowercased().contains(target) }) {
                Task {
                    let res = await manager.startVM(found)
                    launchedJitActive = res.jitActive
                    launchedQemuCmd = res.commandPreview
                    launchedProfile = found
                }
            } else {
                append("VM not found. Use 'vm list' to see available profiles.")
            }
        default:
            append("Unknown vm subcommand: \(sub)")
        }
    }

    private func handleJitCommand(_ args: [String]) {
        let sub = args.first?.lowercased() ?? "status"
        if sub == "test" {
            append("Running JIT self-test...")
            Task {
                let shape = model.guest.map { JitShape(memoryMiB: $0.memoryMiB, processorCount: $0.cores) }
                    ?? JitShape(memoryMiB: 2048, processorCount: 4)
                await internalDebugger.runJitSelfTest {
                    if let driver = model.driver {
                        return await driver.prepareJit(wanted: true, shape: shape)
                    }
                    return .unsupported
                }
                switch internalDebugger.testStatus {
                case .passed(let msg): append("[PASS] \(msg)")
                case .interpreterOnly(let msg): append("[INFO] \(msg)")
                case .failed(let msg): append("[FAIL] \(msg)")
                default: break
                }
            }
        } else {
            let traced = InternalJitDebugger.isProcessTraced()
            let pairing = pairingManager.activePairing
            append("P_TRACED: \(traced ? "1 (Debugger Attached)" : "0 (Not Traced)")")
            append("Pairing File: \(pairing?.isValid == true ? pairing!.fileName : "None")")
        }
    }

    private func handlePairCommand(_ args: [String]) {
        let sub = args.first?.lowercased() ?? "status"
        if sub == "start" {
            pairingService.startPairing()
            append("Started Developer Mode pairing service (_remotepairing-pairable-host._tcp.). Open Settings > Privacy & Security > Developer Mode.")
        } else {
            append("Pairing Status: \(pairingService.pairingStatus)")
            if !pairingService.pinCode.isEmpty {
                append("PIN: \(pairingService.pinCode)")
            }
        }
    }
}
