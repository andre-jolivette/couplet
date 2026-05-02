import Foundation
import AppKit

enum SampleData {

    // MARK: - Stub colour palette for placeholder thumbnails
    // Each image ID maps to a distinct colour so tiles look varied.

    static func stubColor(for imageID: Int) -> NSColor {
        let palette: [NSColor] = [
            NSColor(red: 0.62, green: 0.53, blue: 0.44, alpha: 1), // warm sand
            NSColor(red: 0.25, green: 0.35, blue: 0.45, alpha: 1), // slate blue
            NSColor(red: 0.70, green: 0.38, blue: 0.22, alpha: 1), // terracotta
            NSColor(red: 0.30, green: 0.48, blue: 0.38, alpha: 1), // forest
            NSColor(red: 0.55, green: 0.50, blue: 0.62, alpha: 1), // lavender grey
            NSColor(red: 0.72, green: 0.60, blue: 0.35, alpha: 1), // golden hour
            NSColor(red: 0.28, green: 0.40, blue: 0.52, alpha: 1), // overcast
            NSColor(red: 0.58, green: 0.32, blue: 0.32, alpha: 1), // muted red
            NSColor(red: 0.38, green: 0.52, blue: 0.48, alpha: 1), // teal
            NSColor(red: 0.48, green: 0.44, blue: 0.36, alpha: 1), // olive
            NSColor(red: 0.20, green: 0.28, blue: 0.38, alpha: 1), // deep navy
            NSColor(red: 0.65, green: 0.55, blue: 0.48, alpha: 1), // dusty rose
        ]
        return palette[abs(imageID) % palette.count]
    }

    // MARK: - Folders

    static let folders: [FolderItem] = [
        FolderItem(id: 1, displayName: "Photography", path: "/Pictures/Photography",
                   driveType: .internal, imageCount: 979, pairCount: 0),
        FolderItem(id: 2, displayName: "Archive 2023", path: "/Volumes/Archive/2023",
                   driveType: .external, imageCount: 1840, pairCount: 0),
        FolderItem(id: 3, displayName: "NAS Backup", path: "/Volumes/NAS/Photos",
                   driveType: .nas, imageCount: 3210, pairCount: 0),
    ]

    // MARK: - Collections

    static let collections: [CollectionItem] = [
        CollectionItem(id: 1, name: "Tokyo Series", pairCount: 12),
        CollectionItem(id: 2, name: "Portraits — 2024", pairCount: 8),
        CollectionItem(id: 3, name: "Book Draft", pairCount: 24),
    ]

    // MARK: - Pairs

    static let pairs: [DisplayPair] = [
        DisplayPair(
            id: 1, imageAID: 0, imageBID: 1,
            filenameA: "20250515-_DSF2488.jpg", filenameB: "20240707-DSCF7624.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2025, 5, 15), captureDateB: date(2024, 7, 7),
            modality: .thematic, aestheticSubmode: "harmony",
            compositeScore: 0.871, aestheticScore: 0.780, geometricScore: 0.650,
            thematicScore: 0.910,
            rationale: "Thematic connection — images share a conceptual or contextual relationship."
        ),
        DisplayPair(
            id: 2, imageAID: 2, imageBID: 3,
            filenameA: "20240909-_DSF9168.jpg", filenameB: "20250329-_R013838.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2024, 9, 9), captureDateB: date(2025, 3, 29),
            modality: .aesthetic, aestheticSubmode: "harmony",
            compositeScore: 0.869, aestheticScore: 0.920, geometricScore: 0.710,
            thematicScore: 0.780,
            rationale: "Tonal harmony — images share a similar colour register and mood."
        ),
        DisplayPair(
            id: 3, imageAID: 4, imageBID: 5,
            filenameA: "20250517-_DSF2710.jpg", filenameB: "20240622-R0007049.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2025, 5, 17), captureDateB: date(2024, 6, 22),
            modality: .geometric, aestheticSubmode: "contrast",
            compositeScore: 0.854, aestheticScore: 0.620, geometricScore: 0.890,
            thematicScore: 0.740,
            rationale: "Compositional echo — images share similar structural lines or visual weight."
        ),
        DisplayPair(
            id: 4, imageAID: 6, imageBID: 7,
            filenameA: "20241114-_DSF1202.jpg", filenameB: "20241114-_DSF1198.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2024, 11, 14), captureDateB: date(2024, 11, 14),
            modality: .thematic, aestheticSubmode: "harmony",
            compositeScore: 0.848, aestheticScore: 0.810, geometricScore: 0.720,
            thematicScore: 0.885,
            rationale: "Strong semantic similarity — images share closely related subject matter."
        ),
        DisplayPair(
            id: 5, imageAID: 8, imageBID: 9,
            filenameA: "20250426-_DSF5011.jpg", filenameB: "20230815-_DSF0234.jpg",
            folderA: "Photography", folderB: "Archive 2023",
            captureDateA: date(2025, 4, 26), captureDateB: date(2023, 8, 15),
            modality: .aesthetic, aestheticSubmode: "contrast",
            compositeScore: 0.841, aestheticScore: 0.870, geometricScore: 0.580,
            thematicScore: 0.760,
            rationale: "Colour contrast — images form a complementary colour relationship."
        ),
        DisplayPair(
            id: 6, imageAID: 10, imageBID: 11,
            filenameA: "20240312-R0005541.jpg", filenameB: "20241203-_DSF1521.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2024, 3, 12), captureDateB: date(2024, 12, 3),
            modality: .geometric, aestheticSubmode: "harmony",
            compositeScore: 0.833, aestheticScore: 0.640, geometricScore: 0.920,
            thematicScore: 0.700,
            rationale: "Compositional echo — images share similar structural lines or visual weight."
        ),
        DisplayPair(
            id: 7, imageAID: 0, imageBID: 4,
            filenameA: "20250515-_DSF2454.jpg", filenameB: "20250517-_DSF2710.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2025, 5, 15), captureDateB: date(2025, 5, 17),
            modality: .thematic, aestheticSubmode: "harmony",
            compositeScore: 0.826, aestheticScore: 0.750, geometricScore: 0.680,
            thematicScore: 0.860,
            rationale: "Thematic connection — images share a conceptual or contextual relationship."
        ),
        DisplayPair(
            id: 8, imageAID: 2, imageBID: 8,
            filenameA: "20240909-_DSF9168.jpg", filenameB: "20250426-_DSF5011.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2024, 9, 9), captureDateB: date(2025, 4, 26),
            modality: .aesthetic, aestheticSubmode: "harmony",
            compositeScore: 0.818, aestheticScore: 0.840, geometricScore: 0.590,
            thematicScore: 0.780,
            rationale: "Tonal harmony — images share a similar colour register and mood."
        ),
        DisplayPair(
            id: 9, imageAID: 6, imageBID: 10,
            filenameA: "20241114-_DSF1202.jpg", filenameB: "20240312-R0005541.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2024, 11, 14), captureDateB: date(2024, 3, 12),
            modality: .geometric, aestheticSubmode: "contrast",
            compositeScore: 0.809, aestheticScore: 0.550, geometricScore: 0.870,
            thematicScore: 0.720,
            rationale: "Compositional echo — images share similar structural lines or visual weight."
        ),
        DisplayPair(
            id: 10, imageAID: 3, imageBID: 11,
            filenameA: "20250329-_R013838.jpg", filenameB: "20241203-_DSF1521.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2025, 3, 29), captureDateB: date(2024, 12, 3),
            modality: .thematic, aestheticSubmode: "harmony",
            compositeScore: 0.797, aestheticScore: 0.700, geometricScore: 0.610,
            thematicScore: 0.845,
            rationale: "Thematic connection — images share a conceptual or contextual relationship."
        ),
        DisplayPair(
            id: 11, imageAID: 5, imageBID: 7,
            filenameA: "20240622-R0007049.jpg", filenameB: "20241114-_DSF1198.jpg",
            folderA: "Photography", folderB: "Photography",
            captureDateA: date(2024, 6, 22), captureDateB: date(2024, 11, 14),
            modality: .aesthetic, aestheticSubmode: "contrast",
            compositeScore: 0.785, aestheticScore: 0.820, geometricScore: 0.640,
            thematicScore: 0.730,
            rationale: "Colour contrast — images form a complementary colour relationship."
        ),
        DisplayPair(
            id: 12, imageAID: 1, imageBID: 9,
            filenameA: "20240707-DSCF7624.jpg", filenameB: "20230815-_DSF0234.jpg",
            folderA: "Photography", folderB: "Archive 2023",
            captureDateA: date(2024, 7, 7), captureDateB: date(2023, 8, 15),
            modality: .geometric, aestheticSubmode: "harmony",
            compositeScore: 0.774, aestheticScore: 0.590, geometricScore: 0.850,
            thematicScore: 0.690,
            rationale: "Compositional echo — images share similar structural lines or visual weight."
        ),
    ]

    // MARK: - Helpers

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        return Calendar.current.date(from: c) ?? Date()
    }
}
