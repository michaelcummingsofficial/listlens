import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum JPEG {
	/// 480 px wide measured as fast as 720 with the same accuracy, at three quarters of the cost.
	public static let judgeWidth = 480

	public static func encode(_ image: CGImage, width: Int = judgeWidth, quality: Double = 0.7) -> Data? {
		let scaled = image.width > width ? resize(image, width: width) ?? image : image
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
			return nil
		}
		CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
		return CGImageDestinationFinalize(destination) ? data as Data : nil
	}

	private static func resize(_ image: CGImage, width: Int) -> CGImage? {
		let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
		guard let context = CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
		) else {
			return nil
		}
		context.interpolationQuality = .medium
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}
}
