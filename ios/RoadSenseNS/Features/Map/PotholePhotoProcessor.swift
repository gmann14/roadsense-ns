import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedPotholePhoto {
    let reportID: UUID
    let fileURL: URL
    let byteSize: Int
    let sha256Hex: String
}

enum PotholePhotoProcessorError: Error {
    case invalidImageData
    case destinationCreationFailed
    case finalizeFailed
    case missingApplicationSupportDirectory
}

enum PotholePhotoProcessor {
    static func prepareCapturedPhoto(
        rawJPEGData: Data,
        reportID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> PreparedPotholePhoto {
        let normalizedJPEG = try strippedJPEGData(from: rawJPEGData)
        let directory = try photosDirectory(fileManager: fileManager)
        let fileURL = directory.appendingPathComponent("\(reportID.uuidString.lowercased()).jpg", isDirectory: false)
        try normalizedJPEG.write(to: fileURL, options: .atomic)

        let digest = SHA256.hash(data: normalizedJPEG)
        let sha256Hex = digest.compactMap { String(format: "%02x", $0) }.joined()

        return PreparedPotholePhoto(
            reportID: reportID,
            fileURL: fileURL,
            byteSize: normalizedJPEG.count,
            sha256Hex: sha256Hex
        )
    }

    static func strippedJPEGData(
        from rawJPEGData: Data,
        maxPixelSize: Int = 1_600,
        compressionQuality: Double = 0.8
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(rawJPEGData as CFData, nil) else {
            throw PotholePhotoProcessorError.invalidImageData
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw PotholePhotoProcessorError.invalidImageData
        }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PotholePhotoProcessorError.destinationCreationFailed
        }

        let imageOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ]
        CGImageDestinationAddImage(destination, image, imageOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw PotholePhotoProcessorError.finalizeFailed
        }

        return destinationData as Data
    }

    static func photosDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PotholePhotoProcessorError.missingApplicationSupportDirectory
        }

        let directory = applicationSupport.appendingPathComponent("pothole-photos", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
