import Foundation
import Observation
import SwiftUI

/// The group you share a library with, as the `group-membership` function
/// describes it: name, members, pending invites, capacity. Cached in the
/// App Group so Settings opens on the last known card while the fresh one
/// loads, and so the widget/extension side could read it later.
struct GroupCard: Codable, Equatable {
    struct Member: Codable, Equatable, Identifiable {
        var userId: UUID
        var displayName: String?
        var avatarColour: String?
        var isPlus: Bool
        var joinedAt: Date
        var id: UUID { userId }

        /// What the card shows when someone hasn't picked a name yet.
        var name: String { displayName?.isEmpty == false ? displayName! : "Someone" }
        var initial: String { String(name.prefix(1)).uppercased() }
    }

    struct Invite: Codable, Equatable, Identifiable {
        var code: String
        var expiresAt: Date
        var id: String { code }
        /// "KV7-P2M" — the form people read out and type.
        var formatted: String { GroupStore.formatCode(code) }
    }

    var groupId: UUID
    var name: String
    var namePinned: Bool
    var homeLocality: String?
    var homeCountry: String?
    var isPlus: Bool
    var capacity: Int
    var members: [Member]
    var invites: [Invite]

    var isFull: Bool { members.count >= capacity }
    /// A full free group can still grow — with Plus.
    var needsPlusToGrow: Bool { isFull && !isPlus && members.count < 4 }
    func member(_ id: UUID?) -> Member? { members.first { $0.userId == id } }
}

/// A membership call that failed for a reason the person can act on.
struct MembershipError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Everything Settings needs to show and change the group. Each mutation
/// returns the server's fresh card and replaces the cached one, so the UI
/// never guesses at the outcome.
@Observable
@MainActor
final class GroupStore {
    static let shared = GroupStore()

    private static let cacheKey = "groupCard"
    private static var defaults: UserDefaults { UserDefaults(suiteName: SharedInbox.groupID) ?? .standard }

    private static let libraryKey = "libraryGroupId"
    private static let libraryUserKey = "libraryUserId"

    private(set) var card: GroupCard?
    /// True once the server has answered at least once this session.
    private(set) var loaded = false

    /// Whose saves fill the local store — the group, and the account that
    /// pulled them. Set only by the sync engine after a successful pull, and
    /// kept across sign-out on purpose: the store survives sign-out too, and
    /// the next account to sign in must not inherit it.
    private(set) var libraryGroupId: UUID? {
        didSet { Self.defaults.set(libraryGroupId?.uuidString, forKey: Self.libraryKey) }
    }
    private(set) var libraryUserId: UUID? {
        didSet { Self.defaults.set(libraryUserId?.uuidString, forKey: Self.libraryUserKey) }
    }

    /// The local library belongs to someone else: a different account than
    /// the one signed in (decidable offline), or — once the card is in — a
    /// group this account is no longer part of. The sync engine replaces the
    /// store when this is true; nothing else touches it.
    var libraryIsForeign: Bool {
        if let owner = libraryUserId, let me = SupabaseAuth.shared.userId, owner != me { return true }
        if let lib = libraryGroupId, let card, lib != card.groupId { return true }
        return false
    }

    private init() {
        if let data = Self.defaults.data(forKey: Self.cacheKey) {
            card = try? Self.decoder.decode(GroupCard.self, from: data)
        }
        libraryGroupId = Self.defaults.string(forKey: Self.libraryKey).flatMap(UUID.init)
        libraryUserId = Self.defaults.string(forKey: Self.libraryUserKey).flatMap(UUID.init)
    }

    /// The local store now holds `card`'s group, pulled by this account.
    func libraryReplaced() {
        libraryGroupId = card?.groupId
        libraryUserId = SupabaseAuth.shared.userId
    }

    nonisolated static func formatCode(_ code: String) -> String {
        let c = code.uppercased()
        return c.count == 6 ? "\(c.prefix(3))-\(c.suffix(3))" : c
    }

    // MARK: - Actions

    func refresh() async {
        guard SupabaseAuth.shared.signedIn else { return }
        if let fresh = try? await call(["action": "card"], as: GroupCard.self) {
            store(fresh)
        }
        loaded = true
    }

    struct InviteResult: Decodable, Identifiable {
        let code: String
        let expiresAt: Date
        /// Ready-to-share sentence with the code and the store link — from
        /// the server on a fresh invite; nil when reopening a pending one.
        let message: String?
        var id: String { code }

        init(code: String, expiresAt: Date, message: String?) {
            self.code = code
            self.expiresAt = expiresAt
            self.message = message
        }
    }

    /// A fresh code, or why the group can't grow ("plus_required", "full").
    func invite() async throws -> InviteResult {
        let result = try await call(["action": "invite"], as: InviteResult.self)
        await refresh()
        return result
    }

    func revoke(_ code: String) async throws {
        struct R: Decodable { let revoked: Bool }
        let r = try await call(["action": "revoke", "code": code], as: R.self)
        await refresh()
        if !r.revoked { throw MembershipError(message: "That invite had already ended.") }
    }

    struct LeaveResult: Decodable {
        let left: Bool
        let copied: Int
        let formerGroupName: String?
    }

    /// Leaves for a fresh personal group; the card becomes that group's.
    /// The caller swaps the local library afterwards.
    func leave(keepCopy: Bool) async throws -> LeaveResult {
        let data: Data
        do {
            data = try await raw(["action": "leave", "keep_copy": keepCopy])
        } catch {
            // "already_solo" and friends come with the current card; show it
            // rather than a stale two-person one with a Leave button.
            await refresh()
            throw error
        }
        let result = try Self.decoder.decode(LeaveResult.self, from: data)
        if let fresh = try? Self.decoder.decode(GroupCard.self, from: data) { store(fresh) }
        return result
    }

    func signedOut() {
        card = nil
        loaded = false
        Self.defaults.removeObject(forKey: Self.cacheKey)
    }

    // MARK: - Plumbing

    private func store(_ fresh: GroupCard) {
        card = fresh
        if let data = try? Self.encoder.encode(fresh) { Self.defaults.set(data, forKey: Self.cacheKey) }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractional.string(from: date))
        }
        return e
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    private func call<T: Decodable>(_ body: [String: Any], as: T.Type) async throws -> T {
        let data = try await raw(body)
        return try Self.decoder.decode(T.self, from: data)
    }

    /// One POST to the function. Business outcomes arrive as 200s with an
    /// `error` field; those become `MembershipError`s with plain wording.
    private func raw(_ body: [String: Any]) async throws -> Data {
        let jwt = try await SupabaseAuth.shared.validToken()
        var request = URLRequest(url: SupabaseAuth.baseURL.appending(path: "functions/v1/group-membership"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 401: the token was refused. 4xx/5xx otherwise: ours or theirs,
            // never something the person can fix by reading a code.
            throw MembershipError(message: status == 401
                ? "Your session needs a refresh — sign out and back in."
                : "Couldn't reach the group service. Please try again.")
        }
        let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let code = fields?["error"] as? String {
            throw MembershipError(message: Self.wording(code))
        }
        return data
    }

    /// The function's outcome codes, in sentences.
    private static func wording(_ code: String) -> String {
        switch code {
        case "plus_required": return "Free groups have two seats. Plus, coming soon, opens two more."
        case "full": return "This group already has four people, the most a group can hold."
        case "already_solo": return "You\u{2019}re the only one left in this group — it\u{2019}s already yours, so there\u{2019}s nothing to leave."
        case "no_group": return "Couldn\u{2019}t find your group. Try again in a moment."
        case "unknown": return "That code doesn\u{2019}t match any invite."
        case "expired": return "This invite has expired — ask for a new one."
        case "revoked": return "This invite was cancelled — ask for a new one."
        case "own": return "That\u{2019}s your own group\u{2019}s code."
        default: return "Something went wrong. Please try again."
        }
    }
}

/// The fixed avatar palette the server hands out (`assign_avatar_colour`).
enum AvatarColour {
    static func color(_ name: String?) -> Color {
        switch name {
        case "coral": return Color(red: 0.98, green: 0.45, blue: 0.40)
        case "mint": return Color(red: 0.42, green: 0.85, blue: 0.68)
        case "sky": return Color(red: 0.40, green: 0.70, blue: 0.98)
        case "lilac": return Color(red: 0.72, green: 0.62, blue: 0.96)
        case "amber": return Color(red: 0.98, green: 0.72, blue: 0.30)
        case "rose": return Color(red: 0.96, green: 0.55, blue: 0.72)
        case "teal": return Color(red: 0.30, green: 0.75, blue: 0.75)
        case "plum": return Color(red: 0.70, green: 0.42, blue: 0.75)
        default: return Color.white.opacity(0.35)
        }
    }
}
