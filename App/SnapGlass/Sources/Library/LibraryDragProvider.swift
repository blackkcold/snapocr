import AppKit
import LibraryCore
import UniformTypeIdentifiers

@MainActor
enum LibraryDragProvider {
    static func provider(
        for item: LibraryCore.LibraryItem,
        viewModel: LibraryViewModel
    ) -> NSItemProvider {
        if let group = item.recordingGroup {
            let urls = group.segments
                .flatMap(\.mediaURLs)
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                }
            if let url = urls.first ?? group.mediaURL,
                let provider = NSItemProvider(contentsOf: url)
            {
                return provider
            }
        }

        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.image.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                let urls = await viewModel.quickLookURLs(for: item)
                completion(urls.first, false, nil)
            }
            return nil
        }
        return provider
    }
}
