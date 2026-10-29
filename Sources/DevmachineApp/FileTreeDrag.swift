import AppKit
import UniformTypeIdentifiers
import DevmachineCore

/// The drag side of the Files tab. A remote row is a file promise: Finder
/// gets a name at once and the bytes only when the drop lands, so a drag
/// that is let go elsewhere downloads nothing.
enum FileTreeDrag {
    /// Marks a drag that started in a tree, so dropping it back on the tree
    /// is not read as files arriving from Finder.
    static let marker = "cc.devmachine.file-tree-row"

    static func localProvider(for path: String) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
        mark(provider, path: path)
        return provider
    }

    static func remoteProvider(
        for row: FileTreeRow, export: @escaping @Sendable (String) async throws -> URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        let name = FileTransfer.promisedName(of: row.path, isDirectory: row.isDirectory)
        provider.suggestedName = name
        mark(provider, path: row.path)
        let path = row.path
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType(forName: name).identifier, fileOptions: [], visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task {
                do {
                    completion(try await export(path), false, nil)
                } catch {
                    completion(nil, false, error)
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }

    static func contentType(forName name: String) -> UTType {
        if name.hasSuffix(FileTransfer.folderExtension) { return .gzip }
        return UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }

    static func acceptsDrop(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty
            && !providers.contains { $0.hasItemConformingToTypeIdentifier(marker) }
            && providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    @MainActor static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await fileURL(from: provider) { urls.append(url) }
        }
        return urls
    }

    @MainActor private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func mark(_ provider: NSItemProvider, path: String) {
        provider.registerDataRepresentation(forTypeIdentifier: marker, visibility: .ownProcess) { completion in
            completion(Data(path.utf8), nil)
            return nil
        }
    }
}
