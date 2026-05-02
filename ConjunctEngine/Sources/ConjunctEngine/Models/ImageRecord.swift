import Foundation
import GRDB

public struct ImageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var path: String
    public var contentHash: String
    public var filename: String
    public var folderID: Int64
    public var captureDate: Date?
    public var cameraModel: String?
    public var lensModel: String?
    public var width: Int
    public var height: Int
    public var fileFormat: String
    public var thumbnailPath: String?
    public var isActive: Bool
    public var indexedAt: Date

    public static var databaseTableName = "images"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(
        path: String,
        contentHash: String,
        filename: String,
        folderID: Int64,
        captureDate: Date? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        width: Int = 0,
        height: Int = 0,
        fileFormat: String,
        thumbnailPath: String? = nil,
        isActive: Bool = true,
        indexedAt: Date = Date()
    ) {
        self.path = path
        self.contentHash = contentHash
        self.filename = filename
        self.folderID = folderID
        self.captureDate = captureDate
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.width = width
        self.height = height
        self.fileFormat = fileFormat
        self.thumbnailPath = thumbnailPath
        self.isActive = isActive
        self.indexedAt = indexedAt
    }
}
