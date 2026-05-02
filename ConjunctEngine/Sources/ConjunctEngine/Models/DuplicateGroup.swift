import Foundation
import GRDB

/// A group of images identified as near-duplicates by perceptual hash comparison.
/// One image in the group is designated as the "hero" — the representative shown
/// when the group is paired with non-duplicate images.
public struct DuplicateGroup: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var createdAt: Date
    /// Number of images in this group (denormalised for display convenience)
    public var memberCount: Int

    public static var databaseTableName = "duplicateGroups"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(memberCount: Int = 0, createdAt: Date = Date()) {
        self.memberCount = memberCount
        self.createdAt = createdAt
    }
}

/// Summary of a duplicate group for user review.
public struct DuplicateGroupSummary: Sendable {
    public let groupID: Int64
    public let members: [DuplicateMember]
    public var heroID: Int64 { members.first(where: { $0.isHero })?.imageID ?? members[0].imageID }
}

public struct DuplicateMember: Sendable {
    public let imageID: Int64
    public let filename: String
    public let dHash: String
    public let isHero: Bool
}
