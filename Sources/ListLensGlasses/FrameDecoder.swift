#if os(iOS)
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes the glasses' HEVC stream and keeps only the newest picture.
///
/// Every frame has to be decoded, because each one builds on the frames before it,
/// but nothing is converted to an image until someone asks for the latest one.
final class FrameDecoder: @unchecked Sendable {
	private let lock = NSLock()
	private var session: VTDecompressionSession?
	private var format: CMFormatDescription?
	private var latest: CVPixelBuffer?
	private(set) var frameCount = 0

	func decode(_ sample: CMSampleBuffer) {
		if let pixels = CMSampleBufferGetImageBuffer(sample) {
			store(pixels)
			return
		}
		guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else {
			return
		}
		lock.lock()
		if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: sampleFormat) }) ?? true {
			makeSession(for: sampleFormat)
		}
		let session = self.session
		lock.unlock()
		guard let session else {
			return
		}
		VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, pixels, _, _ in
			guard status == noErr, let pixels else {
				return
			}
			self?.store(pixels)
		}
	}

	func latestImage() -> CGImage? {
		lock.lock()
		let pixels = latest
		lock.unlock()
		guard let pixels else {
			return nil
		}
		var image: CGImage?
		VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
		return image
	}

	func reset() {
		lock.lock()
		if let session {
			VTDecompressionSessionInvalidate(session)
		}
		session = nil
		format = nil
		latest = nil
		frameCount = 0
		lock.unlock()
	}

	private func store(_ pixels: CVPixelBuffer) {
		lock.lock()
		latest = pixels
		frameCount += 1
		lock.unlock()
	}

	/// Called with the lock held.
	private func makeSession(for sampleFormat: CMFormatDescription) {
		if let session {
			VTDecompressionSessionInvalidate(session)
		}
		session = nil
		format = sampleFormat
		let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
		var created: VTDecompressionSession?
		let status = VTDecompressionSessionCreate(
			allocator: nil,
			formatDescription: sampleFormat,
			decoderSpecification: nil,
			imageBufferAttributes: attributes,
			outputCallback: nil,
			decompressionSessionOut: &created
		)
		session = status == noErr ? created : nil
	}
}
#endif
