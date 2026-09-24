import AppIntents
import CoreImage
import UIKit
import Vision
#if canImport(VisualIntelligence)
import VisualIntelligence

/// What Visual Intelligence shows for a camera view or a screenshot: the
/// saves it's about, then a way to save it.
@UnionValue
enum VisualSearchResult {
    case save(SaveEntity)
    case capture(CaptureEntity)
}

struct VisualSaveQuery: IntentValueQuery {
    @MainActor
    func values(for input: SemanticContentDescriptor) async throws -> [VisualSearchResult] {
        guard SupabaseAuth.shared.signedIn, let seen = await VisualCapture.read(input) else { return [] }
        var results: [VisualSearchResult] = SaveLibrary.matching(seen: seen.lines).map { item in
            var entity = SaveEntity(item)
            entity.thumbnail = WidgetStore.photo(for: item.id)
            return .save(entity)
        }
        results.append(.capture(CaptureEntity(id: seen.id)))
        return results
    }
}

/// "More results": the library's own search on the best match, or the
/// composer when nothing saved matches.
@AppIntent(schema: .visualIntelligence.semanticContentSearch)
struct ShowVisualResultsIntent {
    static let openAppWhenRun = true

    var semanticContent: SemanticContentDescriptor

    @MainActor
    func perform() async throws -> some IntentResult {
        if let seen = await VisualCapture.read(semanticContent) { VisualCapture.hand(seen) }
        return .result()
    }
}

extension VisualCapture {
    static func read(_ input: SemanticContentDescriptor) async -> Seen? {
        guard let buffer = input.pixelBuffer else { return nil }
        let ci = buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return await read(cg)
    }
}
#endif

/// A picture held for "Save to Can We Go". Only the id travels; the image
/// waits in Caches for a day in case it's tapped.
struct CaptureEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "New Save"
    static let defaultQuery = CaptureQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Save to Can We Go",
            subtitle: "Look it up and add it to your saves",
            image: VisualCapture.thumbnail(id).map { .init(data: $0) } ?? .init(systemName: "plus.circle")
        )
    }
}

struct CaptureQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CaptureEntity] {
        identifiers.filter(VisualCapture.exists).map(CaptureEntity.init)
    }
}

/// Opens the composer with the picture, reading it straight away, the way
/// the share sheet does with a screenshot.
struct OpenCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Save a Picture"
    static let isDiscoverable = false

    @Parameter(title: "Picture")
    var target: CaptureEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let image = VisualCapture.image(target.id) else { return .result() }
        CaptureGate.pendingImage = image
        NotificationCenter.default.post(name: .cwgCaptureImage, object: nil)
        return .result()
    }
}

/// Reads a Visual Intelligence frame: its text, on the device, and a copy
/// of the picture sized for the parser.
enum VisualCapture {
    struct Seen {
        let id: String
        let lines: [String]
    }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "VisualCaptures", directoryHint: .isDirectory)
    }

    static func read(_ cg: CGImage) async -> Seen {
        let lines = (try? await RecognizeTextRequest().perform(on: cg))?
            .compactMap { $0.topCandidates(1).first?.string } ?? []
        let id = UUID().uuidString
        store(UIImage(cgImage: cg), id: id)
        return Seen(id: id, lines: lines)
    }

    /// Into the app: the list's search on the best match, or the composer
    /// on the picture when nothing saved matches.
    @MainActor
    static func hand(_ seen: Seen) {
        if let top = SaveLibrary.matching(seen: seen.lines).first {
            SearchGate.pending = (top.kind, top.title)
            NotificationCenter.default.post(name: .cwgSearchSaves, object: nil)
        } else if let picture = image(seen.id) {
            CaptureGate.pendingImage = picture
            NotificationCenter.default.post(name: .cwgCaptureImage, object: nil)
        }
    }

    static func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: file(id).path)
    }

    static func image(_ id: String) -> Data? {
        try? Data(contentsOf: file(id))
    }

    static func thumbnail(_ id: String) -> Data? {
        try? Data(contentsOf: file(id, thumb: true))
    }

    private static func file(_ id: String, thumb: Bool = false) -> URL {
        directory.appending(path: thumb ? "\(id)-thumb.jpg" : "\(id).jpg")
    }

    private static func store(_ image: UIImage, id: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dayAgo = Date.now.addingTimeInterval(-86_400)
        for old in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < dayAgo { try? fm.removeItem(at: old) }
        }
        try? image.compressedForUpload()?.write(to: file(id), options: .atomic)
        try? image.compressedForUpload(maxEdge: 300)?.write(to: file(id, thumb: true), options: .atomic)
    }
}
