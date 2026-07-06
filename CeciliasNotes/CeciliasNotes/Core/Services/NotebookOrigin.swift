import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where a notebook was created or last edited — device name + platform.
enum NotebookOriginPlatform: String, Codable, CaseIterable {
    case iphone
    case ipad
    case mac
    /// Agent / MCP writer — not a physical device, but shown for transparency.
    case mcp

    var displayName: String {
        switch self {
        case .iphone: return "iPhone"
        case .ipad:   return "iPad"
        case .mac:    return "Mac"
        case .mcp:    return "Agent (MCP)"
        }
    }

    var systemImage: String {
        switch self {
        case .iphone: return "iphone"
        case .ipad:   return "ipad"
        case .mac:    return "laptopcomputer"
        case .mcp:    return "sparkles"
        }
    }

    static func from(raw: String?) -> NotebookOriginPlatform? {
        guard let raw, let value = NotebookOriginPlatform(rawValue: raw) else { return nil }
        return value
    }
}

@MainActor
enum NotebookOriginRecorder {

    static func currentDeviceName() -> String {
#if canImport(UIKit)
        String(UIDevice.current.name.prefix(80))
#elseif canImport(AppKit)
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return String(name.prefix(80))
#else
        return "This device"
#endif
    }

    static func currentPlatform() -> NotebookOriginPlatform {
#if os(macOS)
        return .mac
#elseif canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:  return .iphone
        case .pad:    return .ipad
        default:      return .ipad
        }
#else
        return .mac
#endif
    }

    static func stampCreation(on notebook: Notebook) {
        let device = currentDeviceName()
        let platform = currentPlatform()
        notebook.createdOnDevice = device
        notebook.createdOnPlatform = platform.rawValue
        notebook.lastModifiedOnDevice = device
        notebook.lastModifiedOnPlatform = platform.rawValue
    }

    static func stampModification(on notebook: Notebook) {
        notebook.lastModifiedOnDevice = currentDeviceName()
        notebook.lastModifiedOnPlatform = currentPlatform().rawValue
    }

    /// Bumps origin on the parent notebook when content is edited
    /// outside `StorageService` helpers (e.g. SwiftData-bound text).
    static func markNotebookModified(notebookId: UUID, context: ModelContext) {
        let id = notebookId
        let descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == id }
        )
        guard let notebook = try? context.fetch(descriptor).first else { return }
        notebook.markModified()
    }

    /// Apply provenance from an incoming `.inkbook` file. Preserves
    /// MCP / remote writer attribution instead of stamping the device
    /// that happens to receive the import.
    static func applyImport(from file: CeciliasNotesFile, to notebook: Notebook, isNew: Bool) {
        if let origin = file.origin {
            applyStructuredOrigin(origin, to: notebook, isNew: isNew)
            return
        }
        if file.agent != nil {
            applyAgentOrigin(from: file, to: notebook, isNew: isNew)
            return
        }
        if isNew {
            stampCreation(on: notebook)
        } else {
            stampModification(on: notebook)
        }
    }

    static func parseISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }

    private static func applyStructuredOrigin(
        _ origin: CeciliasNotesFile.Origin,
        to notebook: Notebook,
        isNew: Bool
    ) {
        if isNew {
            if let device = trimmed(origin.created_on_device) {
                notebook.createdOnDevice = device
            }
            if let platform = trimmed(origin.created_on_platform) {
                notebook.createdOnPlatform = platform
            }
        } else {
            if notebook.createdOnDevice == nil,
               let device = trimmed(origin.created_on_device) {
                notebook.createdOnDevice = device
            }
            if notebook.createdOnPlatform == nil,
               let platform = trimmed(origin.created_on_platform) {
                notebook.createdOnPlatform = platform
            }
        }
        if let device = trimmed(origin.last_modified_on_device) {
            notebook.lastModifiedOnDevice = device
        }
        if let platform = trimmed(origin.last_modified_on_platform) {
            notebook.lastModifiedOnPlatform = platform
        }
    }

    private static func applyAgentOrigin(
        from file: CeciliasNotesFile,
        to notebook: Notebook,
        isNew: Bool
    ) {
        guard let agent = file.agent else { return }
        let line = agentOriginLine(agent)
        if isNew {
            notebook.createdOnDevice = line
            notebook.createdOnPlatform = NotebookOriginPlatform.mcp.rawValue
        }
        notebook.lastModifiedOnDevice = line
        notebook.lastModifiedOnPlatform = NotebookOriginPlatform.mcp.rawValue
    }

    static func agentOriginLine(_ agent: CeciliasNotesFile.Agent) -> String {
        var parts = [agent.tool]
        let author = agent.written_by.trimmingCharacters(in: .whitespacesAndNewlines)
        if !author.isEmpty, author != "agent" {
            parts.append(author)
        }
        if let model = agent.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            parts.append(model)
        }
        return parts.joined(separator: " · ")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Notebook {

    /// Bumps `updatedAt` and records this device as the last modifier.
    @MainActor
    func markModified() {
        updatedAt = Date()
        NotebookOriginRecorder.stampModification(on: self)
    }
}

enum NotebookOriginDisplay {

    static func formattedDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "today at \(f.string(from: date).lowercased())"
        }
        if cal.isDateInYesterday(date) {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "yesterday at \(f.string(from: date).lowercased())"
        }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        let day = f.string(from: date).lowercased()
        let tf = DateFormatter()
        tf.dateStyle = .none
        tf.timeStyle = .short
        return "\(day) at \(tf.string(from: date).lowercased())"
    }

    static func locationLine(device: String?, platformRaw: String?) -> String? {
        let platform = NotebookOriginPlatform.from(raw: platformRaw)
        let trimmed = device?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceLabel = trimmed.flatMap { $0.isEmpty ? nil : $0 }

        if let platform, let deviceLabel {
            return "\(platform.displayName) · \(deviceLabel)"
        }
        if let platform {
            return platform.displayName
        }
        if let deviceLabel {
            return deviceLabel
        }
        return nil
    }
}
