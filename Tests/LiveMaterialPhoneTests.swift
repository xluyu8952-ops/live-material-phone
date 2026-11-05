import XCTest
import AVFoundation
import UIKit
import ImageIO
@testable import LiveMaterialPhone

final class LiveMaterialPhoneTests: XCTestCase {
    func testOnlyLocalComputerConnectionsAreAccepted() throws {
        let token = String(repeating: "x", count: 32)
        let connection = try Connection("http://192.168.1.4:8765/connect/" + token)
        XCTAssertEqual(connection.token, token)
        XCTAssertEqual(try connection.resource("/api/library").host, "192.168.1.4")
        XCTAssertThrowsError(try Connection("https://example.com/connect/" + token))
        XCTAssertThrowsError(try Connection("file:///etc/passwd"))
        XCTAssertThrowsError(try connection.resource("//example.com/video"))
        XCTAssertThrowsError(try Connection("http://192.168.1.4:8765/connect/short"))
    }

    func testNativeLivePhotoPairWithSyntheticMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMaterial-Test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("input.mp4"), cover = directory.appendingPathComponent("cover.jpg")
        try await makeVideo(movie)
        let asset = AVURLAsset(url: movie); let generator = AVAssetImageGenerator(asset: asset)
        let cgImage = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 30), actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: cover)
        let pair = try await LivePhotoMaker.makePair(video: movie, cover: cover, directory: directory)
        // makePair includes PHLivePhoto.request validation; a still or plain MP4 is not accepted.
        let result = AVURLAsset(url: pair.movie)
        let audio = try await result.loadTracks(withMediaType: .audio)
        let timed = try await result.loadTracks(withMediaType: .metadata)
        XCTAssertTrue(audio.isEmpty); XCTAssertFalse(timed.isEmpty)
        let metadata = try await result.load(.metadata)
        let item = try XCTUnwrap(metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier }))
        let stringValue = try await item.load(.stringValue)
        let identifier = try XCTUnwrap(stringValue)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(pair.image as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        XCTAssertEqual(maker["17"] as? String, identifier)
    }

    private func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 240, AVVideoHeightKey: 320])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 320
        ])
        writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "LiveMaterial.SyntheticVideo"); var index = 0; var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if index >= 60 {
                        finished = true; input.markAsFinished(); writer.finishWriting {
                            if writer.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: writer.error ?? ClientError.message("fixture failed")) }
                        }; return
                    }
                    var pixel: CVPixelBuffer?
                    CVPixelBufferCreate(kCFAllocatorDefault, 240, 320, kCVPixelFormatType_32ARGB, nil, &pixel)
                    guard let pixel else { finished = true; writer.cancelWriting(); continuation.resume(throwing: ClientError.message("no pixel buffer")); return }
                    CVPixelBufferLockBaseAddress(pixel, [])
                    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 240, height: 320, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
                    context.setFillColor(UIColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 240, height: 320))
                    context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: CGFloat(index * 2), y: 100, width: 48, height: 60))
                    CVPixelBufferUnlockBaseAddress(pixel, [])
                    if !adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) {
                        finished = true; writer.cancelWriting(); continuation.resume(throwing: writer.error ?? ClientError.message("fixture append failed")); return
                    }
                    index += 1
                }
            }
        }
    }
}
