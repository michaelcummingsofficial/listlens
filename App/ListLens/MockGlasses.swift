#if DEBUG
import AVFoundation
import ListLensCore
import MWDATMockDevice
import SwiftUI
import UIKit

/**
 * Simulated Ray-Ban Display glasses for the iOS Simulator: the glasses display is drawn in the
 * app and a recorded clip stands in for the camera. Launch with `-mockFeed clip.mov`, a file in the
 * app's Documents folder; the simulator moves that folder on every reinstall.
 */
@MainActor
enum MockGlasses {
	private(set) static var glasses: (any MWDATMockDevice.MockGlasses)?
	private(set) static var clip: ClipFrames?

	static func startIfRequested() {
		guard let path = UserDefaults.standard.string(forKey: "mockFeed") else {
			return
		}
		MockDeviceKit.shared.enable(config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
		do {
			let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
			glasses.powerOn()
			glasses.don()
			let url = URL.documentsDirectory.appending(path: path)
			// The stream won't start without a feed, though frames come from `clip` instead.
			glasses.services.camera.setCameraFeed(fileURL: url)
			self.glasses = glasses
			clip = ClipFrames(url: url)
		} catch {
			print("Mock glasses failed: \(error)")
		}
	}
}

/// The simulated 600×600 display, drawn over black the way the real one floats over the world.
struct MockDisplayPreview: UIViewRepresentable {
	let glasses: any MWDATMockDevice.MockGlasses

	func makeUIView(context: Context) -> UIView {
		let container = UIView()
		container.backgroundColor = .black
		let preview = glasses.services.display.createPreviewView()
		preview.frame = container.bounds
		preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		container.addSubview(preview)
		return container
	}

	func updateUIView(_ view: UIView, context: Context) {}
}
#endif

#if DEBUG
/**
 * Frames from a recorded clip at the moment they would arrive live. The mock camera's own
 * video feed delivered no frames to the stream in the simulator, so the clip is read directly.
 */
final class ClipFrames: @unchecked Sendable {
	private let generator: AVAssetImageGenerator
	private let asset: AVURLAsset
	private let lock = NSLock()
	private var startedAt: Date?

	init(url: URL) {
		asset = AVURLAsset(url: url)
		generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		// An exact time makes the generator decode from the last keyframe on every call, which stalls sampling.
		generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
		generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
	}

	func latestJPEG() async -> Data? {
		let startedAt = lock.withLock {
			let startedAt = self.startedAt ?? Date()
			self.startedAt = startedAt
			return startedAt
		}
		guard let duration = try? await asset.load(.duration).seconds, duration > 0 else {
			return nil
		}
		let time = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: duration)
		guard let (image, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else {
			return nil
		}
		return JPEG.encode(image)
	}
}
#endif
