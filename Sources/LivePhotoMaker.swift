import AVFoundation
import CoreMedia
import ImageIO
import Photos
import UniformTypeIdentifiers
import CoreGraphics
import Foundation

enum LivePhotoMaker {
    struct Pair { let image: URL; let movie: URL }

    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ClientError.message("请允许此 App 添加照片，才能把实况保存到相册。")
        }
    }

    static func makeAndSave(video: URL, cover: URL, directory: URL) async throws {
        let pair = try await makePair(video: video, cover: cover, directory: directory)
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(with: .photo, fileURL: pair.image, options: nil)
            creation.addResource(with: .pairedVideo, fileURL: pair.movie, options: nil)
        }
    }
    static func makePair(video: URL, cover: URL, directory: URL) async throws -> Pair {
        try Task.checkCancellation()
        let identifier = UUID().uuidString
        let still = directory.appendingPathComponent(identifier + ".jpg")
        let movie = directory.appendingPathComponent(identifier + ".mov")
        try writeStill(cover, to: still, identifier: identifier)
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0.05 else { throw ClientError.message("视频太短或无法读取。") }
        let anchor = try nearestFrame(to: cover, in: asset, duration: duration)
        try await writeMovie(asset, to: movie, identifier: identifier, anchor: anchor)
        let pair = Pair(image: still, movie: movie)
        try await validate(pair)
        return pair
    }

    private static func writeStill(_ source: URL, to destination: URL, identifier: String) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ClientError.message("原封面无法读取，未生成实况。")
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any]) ?? [:]
        var maker = (properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]) ?? [:]
        maker["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary as String] = maker
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ClientError.message("实况封面写入失败。") }
    }

    // The cover itself is preserved. This locates the closest remaining dynamic
    // frame, including the fixed horizontal mirror; it is not an exact-cover claim.
    private static func nearestFrame(to cover: URL, in asset: AVAsset, duration: CMTime) throws -> CMTime {
        guard let input = CGImageSourceCreateWithURL(cover as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
              let normal = vector(image, mirrored: false), let mirrored = vector(image, mirrored: true) else {
            throw ClientError.message("无法读取原封面。")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let upper = max(0, duration.seconds - 1.0 / 30)
        let samples = max(2, min(30, Int(duration.seconds * 30)))
        var bestTime: CMTime?; var bestScore = Float.greatestFiniteMagnitude
        for index in 0..<samples {
            let time = CMTime(seconds: upper * Double(index) / Double(samples - 1), preferredTimescale: 600)
            var actual = CMTime.zero
            guard let frame = try? generator.copyCGImage(at: time, actualTime: &actual), let values = vector(frame, mirrored: false) else { continue }
            let score = min(distance(values, normal), distance(values, mirrored))
            if score < bestScore { bestScore = score; bestTime = actual }
        }
        guard let result = bestTime else { throw ClientError.message("无法读取视频画面，未生成实况。") }
        return CMTime(seconds: min(upper, max(0, result.seconds)), preferredTimescale: 600)
    }
    private static func vector(_ image: CGImage, mirrored: Bool) -> [Float]? {
        let width = 24, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            if mirrored { context.translateBy(x: CGFloat(width), y: 0); context.scaleBy(x: -1, y: 1) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))); return true
        }
        guard ok else { return nil }
        let floats = pixels.map { Float($0) }; let mean = floats.reduce(0, +) / Float(floats.count)
        let deviation = max(5, sqrt(floats.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(floats.count)))
        return floats.map { ($0 - mean) / deviation }
    }
    private static func distance(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count) }

    private static func writeMovie(_ asset: AVAsset, to output: URL, identifier: String, anchor: CMTime) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ClientError.message("素材没有视频画面。") }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { throw ClientError.message("无法读取视频格式。") }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw ClientError.message("无法读取视频。") }; reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await track.load(.preferredTransform)
        guard writer.canAdd(videoInput) else { throw ClientError.message("视频格式不能封装为实况。") }; writer.add(videoInput)
        // No audio input is ever added: all resulting Live Photos remain silent.
        let content = AVMutableMetadataItem()
        content.identifier = .quickTimeMetadataContentIdentifier
        content.value = identifier as NSString
        content.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [content]
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"
        ]
        var description: CMFormatDescription?
        let code = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description)
        guard code == 0, let description else { throw ClientError.message("无法创建实况时间信息。") }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        metadataInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(metadataInput) else { throw ClientError.message("无法写入实况时间信息。") }; writer.add(metadataInput)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        let marker = AVMutableMetadataItem()
        marker.keySpace = .quickTimeMetadata; marker.key = "com.apple.quicktime.still-image-time" as NSString
        marker.value = NSNumber(value: Int8(0)); marker.dataType = "com.apple.metadata.datatype.int8"
        let group = AVTimedMetadataGroup(items: [marker], timeRange: CMTimeRange(start: anchor, duration: CMTime(value: 1, timescale: 30)))
        guard writer.startWriting() else { throw writer.error ?? ClientError.message("无法开始实况封装。") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? ClientError.message("无法开始读取视频。") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "LiveMaterial.MovieMuxer")
            var videoDone = false, metadataDone = false, resolved = false
            var timeout: DispatchWorkItem?
            func fail(_ error: Error) {
                guard !resolved else { return }; resolved = true; timeout?.cancel()
                reader.cancelReading(); writer.cancelWriting(); continuation.resume(throwing: error)
            }
            func finishIfReady() {
                guard videoDone && metadataDone && !resolved else { return }; resolved = true; timeout?.cancel()
                writer.finishWriting {
                    if writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: writer.error ?? ClientError.message("实况视频写入失败。")) }
                }
            }
            timeout = DispatchWorkItem { fail(ClientError.message("实况封装超时，请重试这一个素材。")) }
            if let timeout { queue.asyncAfter(deadline: .now() + 60, execute: timeout) }
            metadataInput.requestMediaDataWhenReady(on: queue) {
                guard !resolved && !metadataDone && metadataInput.isReadyForMoreMediaData else { return }
                guard adaptor.append(group) else { fail(writer.error ?? ClientError.message("实况时间标记写入失败。")); return }
                metadataInput.markAsFinished(); metadataDone = true; finishIfReady()
            }
            videoInput.requestMediaDataWhenReady(on: queue) {
                while !resolved && !videoDone && videoInput.isReadyForMoreMediaData {
                    guard let sample = readerOutput.copyNextSampleBuffer() else {
                        if reader.status == .failed { fail(reader.error ?? ClientError.message("读取视频失败。")); return }
                        videoInput.markAsFinished(); videoDone = true; finishIfReady(); return
                    }
                    guard videoInput.append(sample) else { fail(writer.error ?? ClientError.message("视频写入失败。")); return }
                }
            }
        }
    }

    private static func validate(_ pair: Pair) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock(); var completed = false; var timeout: DispatchWorkItem?
            func finish(_ error: Error?) {
                lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock()
                timeout?.cancel()
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            let request = PHLivePhoto.request(withResourceFileURLs: [pair.image, pair.movie], placeholderImage: nil,
                targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFit) { photo, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                if let photo { _ = photo; finish(nil) }
                else { finish((info[PHLivePhotoInfoErrorKey] as? Error) ?? ClientError.message("iPhone 未识别为实况，未保存普通照片或视频。")) }
            }
            timeout = DispatchWorkItem { PHLivePhoto.cancelRequest(withRequestID: request); finish(ClientError.message("实况配对校验超时。")) }
            if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout) }
        }
    }
}
