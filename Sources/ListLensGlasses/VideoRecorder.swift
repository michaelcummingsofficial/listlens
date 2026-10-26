#if os(iOS)
import AVFoundation
import Foundation

/// Writes the glasses' compressed stream to a movie file without re-encoding it.
final class VideoRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var writer: AVAssetWriter?
	private var input: AVAssetWriterInput?
	private var url: URL?
	private(set) var startedAt: Date?

	func start(to url: URL) {
		lock.withLock {
			self.url = url
			writer = nil
			input = nil
			startedAt = nil
		}
	}

	func append(_ sample: CMSampleBuffer) {
		lock.lock()
		defer { lock.unlock() }
		guard let url else {
			return
		}
		if writer == nil {
			guard let format = CMSampleBufferGetFormatDescription(sample), let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
				return
			}
			let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
			input.expectsMediaDataInRealTime = true
			guard writer.canAdd(input) else {
				return
			}
			writer.add(input)
			guard writer.startWriting() else {
				return
			}
			writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
			self.writer = writer
			self.input = input
			startedAt = .now
		}
		if let input, input.isReadyForMoreMediaData {
			input.append(sample)
		}
	}

	/// Returns when the movie file is complete.
	func stop() async {
		let (writer, input) = lock.withLock {
			let pair = (self.writer, self.input)
			self.writer = nil
			self.input = nil
			url = nil
			return pair
		}
		guard let writer, let input, writer.status == .writing else {
			return
		}
		input.markAsFinished()
		await writer.finishWriting()
	}
}
#endif
