#if os(iOS)
import ListLensCore
import MWDATDisplay
import UIKit

/// What ListLens draws on the 600×600 glasses display, modeled on Meta's glasses list pattern:
/// a header pill with the list name and status, then one card per item.
public enum GlassesScreens {
	/**
	 * The display kit has no empty circle and can't tint its icons, so both checkbox states are
	 * drawn here as small images in the toolkit's colors: a gray ring and a blue filled check.
	 */
	private static let unchecked = checkbox(symbol: "circle", color: UIColor(red: 0.69, green: 0.70, blue: 0.71, alpha: 1))
	private static let checked = checkbox(symbol: "checkmark.circle.fill", color: UIColor(red: 0.149, green: 0.580, blue: 0.996, alpha: 1))

	/// Items stay in list order, so a check-off lands where the wearer is looking.
	/// - Parameter status: the gray text after the list name, such as "3 left" or "Eggs in hand".
	public static func list(
		title: String,
		status: String,
		items: [ListItem],
		onToggle: @escaping @Sendable (ListItem.ID) -> Void
	) -> FlexBox {
		return FlexBox(direction: .column, spacing: 20, crossAlignment: .stretch, padding: EdgeInsets(top: 16, leading: 40, trailing: 40)) {
			FlexBox(direction: .row, alignment: .center) {
				FlexBox(
					direction: .row,
					spacing: 8,
					crossAlignment: .center,
					padding: EdgeInsets(top: 10, bottom: 10, leading: 18, trailing: 18)
				) {
					Text(title, style: .meta)
					Text(status, style: .meta, color: .secondary)
				}
				.background(.card)
			}
			for item in items {
				FlexBox(
					direction: .row,
					spacing: 28,
					crossAlignment: .center,
					padding: EdgeInsets(top: 30, bottom: 30, leading: 34, trailing: 34)
				) {
					item.isChecked ? checked : unchecked
					Text(item.name, style: .body).flexGrow(1)
				}
				.background(.card)
				.onTap { onToggle(item.id) }
			}
		}
	}

	private static func checkbox(symbol: String, color: UIColor) -> Image {
		let configuration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
		let symbolImage = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal)
		let size = CGSize(width: 48, height: 48)
		let rendered = UIGraphicsImageRenderer(size: size).image { _ in
			guard let symbolImage else {
				return
			}
			let origin = CGPoint(x: (size.width - symbolImage.size.width) / 2, y: (size.height - symbolImage.size.height) / 2)
			symbolImage.draw(at: origin)
		}
		return Image(image: rendered, sizePreset: .icon)
	}
}
#endif
