// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation

/// Manages pairing files (.mobiledevicepairing or .plist) used by the built-in JIT debugger.
@MainActor
final class JitPairingManager: ObservableObject {
    static let shared = JitPairingManager()

    /// The active pairing record discovered in Documents.
    @Published private(set) var activePairing: PairingRecordInfo?
    /// All discovered pairing files.
    @Published private(set) var discoveredPairings: [PairingRecordInfo] = []
    /// Status message for UI.
    @Published private(set) var statusMessage: String = ""

    struct PairingRecordInfo: Identifiable, Equatable, Sendable {
        var id: String { fileURL.path }
        let fileName: String
        let fileURL: URL
        let udid: String?
        let hostID: String?
        let hasHostPrivateKey: Bool
        let hasDeviceCertificate: Bool

        var isValid: Bool {
            hasHostPrivateKey && (hasDeviceCertificate || udid != nil)
        }

        var displayName: String {
            if let udid = udid, !udid.isEmpty {
                let shortUdid = udid.count > 8 ? String(udid.prefix(8)) + "..." : udid
                return "\(fileName) (\(shortUdid))"
            }
            return fileName
        }
    }

    private init() {
        refresh()
    }

    private var privateDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    /// Refresh and scan the Documents directory for pairing files.
    func refresh() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        var found: [PairingRecordInfo] = []

        // Check both Documents root and Documents/Pairing
        let searchDirectories = [privateDirectory,
            documentsURL,
            documentsURL.appendingPathComponent("Pairing", isDirectory: true)
        ].compactMap { $0 }

        for dir in searchDirectories {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
                for fileURL in items {
                    let ext = fileURL.pathExtension.lowercased()
                    if ext == "mobiledevicepairing" || ext == "plist" {
                        if let info = parsePairingFile(at: fileURL) {
                            found.append(info)
                        }
                    }
                }
            } catch {
                print("JitPairingManager: Error scanning directory \(dir.path): \(error)")
            }
        }

        discoveredPairings = found
        activePairing = found.first(where: { $0.isValid }) ?? found.first

        if let active = activePairing, active.isValid {
            statusMessage = "Pairing file active: \(active.fileName)"
        } else if !found.isEmpty {
            statusMessage = "Pairing file found but incomplete."
        } else {
            statusMessage = "No pairing file found."
        }
    }

    /// Parses a plist / mobiledevicepairing file and extracts metadata.
    private func parsePairingFile(at url: URL) -> PairingRecordInfo? {
        guard let data = readPairingFile(at: url) else { return nil }
        return parsePairingFile(data, at: url)
    }

    private func readPairingFile(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, size > 0, size <= 1024 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }

    private func parsePairingFile(_ data: Data, at url: URL) -> PairingRecordInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let udid = plist["UDID"] as? String
            ?? plist["DeviceIdentifier"] as? String
            ?? plist["identifier"] as? String
            ?? plist["udid"] as? String
        let hostID = plist["HostID"] as? String ?? plist["host_id"] as? String
        let hasRemoteKeys = (plist["private_key"] as? Data)?.count == 32
            && (plist["public_key"] as? Data)?.count == 32
        let hasHostKey = hasRemoteKeys || ((plist["HostPrivateKey"] as? Data)?.isEmpty == false)
        let hasCert = plist["DeviceCertificate"] != nil
            || plist["HostCertificate"] != nil
            || plist["host_cert"] != nil
            || plist["device_cert"] != nil
            || plist["remote_unlock_host_key"] != nil

        return PairingRecordInfo(
            fileName: url.lastPathComponent,
            fileURL: url,
            udid: udid,
            hostID: hostID,
            hasHostPrivateKey: hasHostKey,
            hasDeviceCertificate: hasCert
        )
    }

    /// Imports a copy picked by the user into private application storage.
    @discardableResult
    func importPairingFile(from sourceURL: URL) -> Bool {
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = readPairingFile(at: sourceURL) else { return false }
        return savePairingRecord(data: data, fileName: sourceURL.lastPathComponent) != nil
    }

    /// Saves a newly generated pairing record in private application storage.
    @discardableResult
    func savePairingRecord(data: Data, fileName: String = "pairing.mobiledevicepairing") -> URL? {
        guard let directory = privateDirectory, !fileName.isEmpty,
              fileName == (fileName as NSString).lastPathComponent,
              ["plist", "mobiledevicepairing"].contains((fileName as NSString).pathExtension.lowercased()) else {
            return nil
        }

        let destinationURL = directory.appendingPathComponent(fileName)
        guard parsePairingFile(data, at: destinationURL)?.isValid == true else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var storage = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try storage.setResourceValues(values)
            try data.write(to: destinationURL, options: [.atomic, .completeFileProtection])
            refresh()
            return destinationURL
        } catch {
            print("JitPairingManager: Failed to save pairing record: \(error)")
            return nil
        }
    }

    /// Deletes a pairing file.
    func deletePairingFile(_ info: PairingRecordInfo) {
        do {
            try FileManager.default.removeItem(at: info.fileURL)
            refresh()
        } catch {
            print("JitPairingManager: Failed to delete pairing file: \(error)")
        }
    }
}
