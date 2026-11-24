import SwiftData

/// The library's model as shipped, so a later change to `Item` can say how
/// to get from this one to the next (a `MigrationStage`) instead of
/// relying on SwiftData to work it out.
enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self] }
}

enum LibraryMigrations: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Set when this launch couldn't read the library and runs on an empty
/// stand-in. Nothing derived from the library (sync, widget, Spotlight,
/// the share extension's inbox) may be written from it.
@MainActor
enum StandInStore {
    static var active = false
}
