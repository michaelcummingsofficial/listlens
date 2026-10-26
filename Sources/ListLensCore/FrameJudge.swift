import Foundation

public enum HandState: String, Codable, Sendable {
	case empty
	case holding
	case intoCart = "into_cart"
}

/// What Muse Spark saw in one frame.
public struct FrameVerdict: Sendable, Equatable {
	/// Seconds since the watch started, taken when the frame was captured.
	public let time: TimeInterval
	public let state: HandState
	/// What the model read on the product, such as "365 Large Brown eggs".
	public let seen: String
	/// The list item it satisfies, or nil.
	public let itemID: ListItem.ID?
	/// List items visible inside the basket or cart, not in the hand.
	public let inBasket: [ListItem.ID]

	public init(time: TimeInterval, state: HandState, seen: String, itemID: ListItem.ID?, inBasket: [ListItem.ID] = []) {
		self.time = time
		self.state = state
		self.seen = seen
		self.itemID = itemID
		self.inBasket = inBasket
	}
}

/// Asks Muse Spark what the shopper's hand is doing in one frame, against the current list.
public struct FrameJudge: Sendable {
	public struct Judgement: Sendable {
		public let verdict: FrameVerdict
		public let reply: MuseClient.Reply
	}

	private static let noMatch = "none"

	public let client: MuseClient

	public init(client: MuseClient) {
		self.client = client
	}

	public func judge(jpeg: Data, at time: TimeInterval, against items: [ListItem]) async throws -> Judgement {
		let names = Self.uniqueNames(items)
		let reply = try await client.respond(
			[.text(Self.prompt(names)), .jpeg(jpeg)],
			schemaName: "Frame",
			schema: Self.schema(names)
		)
		let answer = try JSONDecoder().decode(Answer.self, from: Data(reply.text.utf8))
		let id = { (name: String) in items.first(where: { $0.name == name })?.id }
		let itemID = answer.match == Self.noMatch ? nil : id(answer.match)
		return Judgement(
			verdict: FrameVerdict(
				time: time,
				state: answer.state,
				seen: answer.item,
				itemID: itemID,
				inBasket: answer.basket.compactMap(id)
			),
			reply: reply
		)
	}

	/// The schema's enum needs distinct values, and a duplicate name would match the first item anyway.
	private static func uniqueNames(_ items: [ListItem]) -> [String] {
		var seen = Set<String>()
		return items.map(\.name).filter { seen.insert($0).inserted }
	}

	static func prompt(_ names: [String]) -> String {
		"""
		First-person frame from a shopper's glasses. List: \(names.joined(separator: ", ")).
		state: "into_cart" only if the hand is letting go of the item into the basket or cart, or it is resting inside with the hand on it. "holding" if it is in their hand, including when they hold it up to look at it over the basket. Else "empty". Ignore shelf products and phones.
		item: short product name, or "". match: the list item it satisfies (a close variant counts, so oat milk satisfies Milk), or "none".
		basket: list items you can see inside the shopper's basket or cart, not in their hand and not on shelves. Empty if the basket isn't visible.
		"""
	}

	static func schema(_ names: [String]) throws -> Data {
		let schema: [String: Any] = [
			"type": "object",
			"properties": [
				"state": ["type": "string", "enum": ["empty", "holding", "into_cart"]],
				"item": ["type": "string"],
				"match": ["type": "string", "enum": names + [noMatch]],
				"basket": ["type": "array", "items": ["type": "string", "enum": names]]
			],
			"required": ["state", "item", "match", "basket"],
			"additionalProperties": false
		]
		return try JSONSerialization.data(withJSONObject: schema)
	}

	private struct Answer: Decodable {
		let state: HandState
		let item: String
		let match: String
		let basket: [String]
	}
}
