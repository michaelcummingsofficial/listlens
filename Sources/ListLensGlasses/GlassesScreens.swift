#if os(iOS)
import ListLensCore
import MWDATDisplay

/// What ListLens draws on the 600×600 glasses display.
public enum GlassesScreens {
	/// More rows than this don't fit on the display at body size.
	private static let visibleRows = 5

	public static func list(
		title: String,
		items: [ListItem],
		holding: (name: String, seen: String)?,
		onToggle: @escaping @Sendable (ListItem.ID) -> Void
	) -> FlexBox {
		let pending = items.filter { !$0.isChecked }
		let done = items.filter(\.isChecked)
		let rows = Array((pending + done).prefix(visibleRows))
		let hidden = items.count - rows.count
		return FlexBox(direction: .column, spacing: 8) {
			FlexBox(direction: .row, spacing: 8, crossAlignment: .center) {
				Icon(name: .cart)
				Text(title, style: .meta, color: .secondary).flexGrow(1)
				Text(pending.isEmpty ? "Done" : "\(pending.count) left", style: .meta, color: .secondary)
			}
			if let holding {
				FlexBox(direction: .column, spacing: 2) {
					Text("In hand: \(holding.name)", style: .heading)
					Text(holding.seen, style: .meta, color: .secondary)
				}
				.padding(16)
				.background(.card)
			}
			for item in rows {
				FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
					Icon(name: item.isChecked ? .checkmarkCircle : .circle)
					Text(item.name, style: .body, color: item.isChecked ? .secondary : .primary)
				}
				.padding(12)
				.onTap { onToggle(item.id) }
			}
			if hidden > 0 {
				Text("\(hidden) more on your phone", style: .meta, color: .secondary)
			}
		}
		.padding(16)
	}

	public static func checkedOff(
		name: String,
		seen: String,
		remaining: Int,
		onUndo: @escaping @Sendable () -> Void
	) -> FlexBox {
		FlexBox(direction: .column, spacing: 12) {
			FlexBox(direction: .column, spacing: 4) {
				FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
					Icon(name: .checkmarkCircle)
					Text(name, style: .heading)
				}
				if !seen.isEmpty {
					Text(seen, style: .body, color: .secondary)
				}
				Text(remaining == 0 ? "That's everything" : "\(remaining) left", style: .meta, color: .secondary)
			}
			.padding(24)
			.background(.card)
			ButtonGroup {
				Button(label: "Undo", style: .secondary, iconName: .x, onClick: onUndo)
			}
		}
		.padding(16)
	}
}
#endif
