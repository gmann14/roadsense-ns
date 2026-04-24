import Foundation
import ImageIO
import UIKit
import XCTest
@testable import RoadSense_NS

final class PotholePhotoProcessorTests: XCTestCase {
    func testPrepareCapturedPhotoStripsExifMetadata() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: directory)
        }

        let rawJPEG = try makeJPEGData()
        let prepared = try PotholePhotoProcessor.prepareCapturedPhoto(
            rawJPEGData: rawJPEG,
            reportID: UUID(),
            fileManager: TestFileManager(applicationSupportDirectory: directory)
        )

        let writtenData = try Data(contentsOf: prepared.fileURL)
        guard let source = CGImageSourceCreateWithData(writtenData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return XCTFail("Expected written image properties")
        }

        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
            XCTAssertNil(exif[kCGImagePropertyExifLensMake])
            XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        }
        XCTAssertLessThanOrEqual(prepared.byteSize, rawJPEG.count)
        XCTAssertEqual(prepared.sha256Hex.count, 64)
    }

    private func makeJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }

        guard let data = image.jpegData(compressionQuality: 0.95) else {
            throw NSError(domain: "PotholePhotoProcessorTests", code: 1)
        }
        return data
    }
}

private final class TestFileManager: FileManager {
    private let applicationSupportDirectory: URL

    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        if directory == .applicationSupportDirectory {
            return [applicationSupportDirectory]
        }
        return super.urls(for: directory, in: domainMask)
    }
}
