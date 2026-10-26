import Foundation

public struct ListItem: Identifiable, Hashable, Codable, Sendable {
	public let id: String
	public var name: String
	public var isChecked: Bool

	public init(id: String = UUID().uuidString, name: String, isChecked: Bool = false) {
		self.id = id
		self.name = name
		self.isChecked = isChecked
	}
}

/// Where the list lives. ListLens reads it and checks items off; it never adds or renames.
public protocol ListSource: Sendable {
	var title: String { get async }
	func items() async throws -> [ListItem]
	func setChecked(_ itemID: ListItem.ID, _ isChecked: Bool) async throws
}

public actor LocalListSource: ListSource {
	public let title: String
	private var stored: [ListItem]

	public init(title: String, items: [ListItem]) {
		self.title = title
		self.stored = items
	}

	public func items() -> [ListItem] {
		stored
	}

	public func setChecked(_ itemID: ListItem.ID, _ isChecked: Bool) {
		guard let index = stored.firstIndex(where: { $0.id == itemID }) else {
			return
		}
		stored[index].isChecked = isChecked
	}
}
