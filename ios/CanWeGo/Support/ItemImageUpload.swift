import Foundation

/// Puts a user-picked cover in the `item-images` bucket and hands back the
/// public URL that `ImageStore` already knows how to cache. The folder is
/// the group id — that's what Storage RLS checks — and the file name is a
/// fresh uuid so a replace doesn't keep serving a CDN-cached old JPEG.
enum ItemImageUpload {
    private static let bucket = "item-images"
    private static let marker = "/storage/v1/object/public/item-images/"

    static func isOurs(_ urlString: String) -> Bool {
        urlString.contains(marker)
    }

    /// JPEG in, public https URL out. The bytes are also written into
    /// `ImageStore` so the form and the card show the new picture at once.
    @MainActor
    static func publish(_ jpeg: Data, replacing previous: String?) async throws -> String {
        guard let groupId = GroupStore.shared.card?.groupId
            ?? GroupStore.shared.libraryGroupId
        else {
            throw ItemImageError("Sign in to add a photo.")
        }
        let token = try await SupabaseAuth.shared.validToken()
        let name = "\(UUID().uuidString.lowercased()).jpg"
        let path = "\(groupId.uuidString.lowercased())/\(name)"
        var request = URLRequest(
            url: SupabaseAuth.baseURL.appending(path: "storage/v1/object/\(bucket)/\(path)")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.httpBody = jpeg

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ItemImageError(
                status == 401 || status == 403
                    ? "You're signed out. Sign in again from Settings."
                    : "Couldn't upload that photo. Try again in a moment."
            )
        }

        let url = SupabaseAuth.baseURL
            .appending(path: "storage/v1/object/public/\(bucket)/\(path)")
            .absoluteString
        if let fileURL = URL(string: url) {
            ImageStore.put(jpeg, for: fileURL)
        }
        if let previous {
            await remove(previous)
        }
        return url
    }

    /// Best-effort delete. A leftover file in the bucket is harmless; a
    /// failed delete must not block clearing the field.
    static func remove(_ urlString: String) async {
        guard isOurs(urlString),
              let path = urlString.components(separatedBy: marker).last
        else { return }
        guard let token = try? await SupabaseAuth.shared.validToken() else { return }
        var request = URLRequest(
            url: SupabaseAuth.baseURL
                .appending(path: "storage/v1/object/\(bucket)")
                .appending(path: path)
        )
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        _ = try? await URLSession.shared.data(for: request)
        if let fileURL = URL(string: urlString) {
            ImageStore.evict(fileURL)
        }
    }
}

struct ItemImageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
