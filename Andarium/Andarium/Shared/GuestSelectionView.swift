// SPDX-License-Identifier: GPL-2.0-or-later

import Observation
import SwiftUI

@Observable
final class GuestSelection {
    enum Guest {
        case android
        case windows
        case otherOS
        case terminal
    }
    var selected: Guest?
}

/// Launch screen letting the user choose between the original Android guest,
/// Windows 11 ARM64 (Japanese), generic ARM64 ISO VMs, or the CLI terminal.
struct GuestSelectionView: View {
    @Environment(AppModel.self) private var model
    @State private var showsJit = false
    let selection: GuestSelection

    var body: some View {
        NavigationStack {
            List {
                Section("Choose an operating system") {
                    Button { selection.selected = .android } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "candybarphone")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Android")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("LineageOS 24 (Original Andarium)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("guest-selection-android")

                    Button { selection.selected = .windows } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Windows 11 ARM64")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("日本語 / マウス・キーボード / QEMU ARM64")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("guest-selection-windows")

                    Button { selection.selected = .otherOS } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "opticaldiscdrive.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ISO / Other OS")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("汎用 ARM64 ISO ブート")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("guest-selection-otheros")

                    Button { selection.selected = .terminal } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "terminal.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Terminal")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("CLI コマンド / VM 管理")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("guest-selection-terminal")
                }

                Section {
                    Button { showsJit = true } label: {
                        Label(String(localized: "Debugger & Pairing", table: "JIT"), systemImage: "bolt.fill")
                    }
                } header: {
                    Text("共通 JIT & ペアリング設定")
                }
            }
            .navigationTitle("Andarium")
            .sheet(isPresented: $showsJit) {
                JitSettingsSheet().environment(model)
            }
        }
    }
}
