import Foundation

/// Turns a stream of per-frame verdicts into check-offs.
///
/// A single frame is not trusted on its own. An item is checked off when:
/// - an "into the cart" frame is followed by one showing the item has left the hand (a carton
///   held open over the basket was once called "into the cart" five seconds early), or
/// - an item just seen in hand shows up inside the basket, which catches drops that fall
///   between frames, or
/// - two frames close together both see the item inside the basket.
public struct CartWatcher: Sendable {
	public enum Event: Sendable, Equatable {
		/// A list item is in the shopper's hand. Fired when the held item changes.
		case holding(itemID: ListItem.ID, seen: String)
		/// The hand has been empty long enough to forget what it held.
		case released
		case checkedOff(itemID: ListItem.ID, seen: String)
	}

	public struct Tuning: Sendable {
		/// How long a held item is remembered once it leaves view, such as on the way down to the cart.
		public var holdMemory: TimeInterval = 8
		/// How long an "into the cart" frame waits for a later frame to confirm the item left the hand.
		public var releaseWindow: TimeInterval = 3
		/// How close two basket sightings of an item must be to confirm each other.
		public var basketWindow: TimeInterval = 3
		/// Repeated "into the cart" frames for an item inside this window are the same drop.
		public var dropCooldown: TimeInterval = 10
		/// Seconds between frames while nothing is held.
		public var idleInterval: TimeInterval = 1
		/// Seconds between frames while a list item is in hand or landing, so the drop is caught quickly.
		public var holdingInterval: TimeInterval = 0.33

		public init() {}
	}

	private struct Sighting {
		let itemID: ListItem.ID
		let seen: String
		let time: TimeInterval
	}

	public var tuning: Tuning
	private var held: Sighting?
	private var landing: Sighting?
	private var basketSightings: [ListItem.ID: TimeInterval] = [:]
	private var lastDrop: [ListItem.ID: TimeInterval] = [:]
	private var lastTime: TimeInterval = 0

	public init(tuning: Tuning = Tuning()) {
		self.tuning = tuning
	}

	/// How long to wait before sampling the next frame.
	public var nextInterval: TimeInterval {
		let awaitingBasket = basketSightings.values.contains { lastTime - $0 <= tuning.basketWindow }
		return held == nil && landing == nil && !awaitingBasket ? tuning.idleInterval : tuning.holdingInterval
	}

	public mutating func ingest(_ verdict: FrameVerdict) -> [Event] {
		lastTime = max(lastTime, verdict.time)
		var events = settleLanding(with: verdict)
		events += checkBasket(verdict)
		switch verdict.state {
		case .holding:
			events += hold(verdict)
		case .intoCart:
			startLanding(verdict)
		case .empty:
			events += forgetIfStale(at: verdict.time)
		}
		return events
	}

	/// Decides a pending drop using the frame after it.
	private mutating func settleLanding(with verdict: FrameVerdict) -> [Event] {
		guard let pending = landing, verdict.time > pending.time else {
			return []
		}
		if verdict.time - pending.time > tuning.releaseWindow {
			landing = nil
			return []
		}
		let stillInHand = verdict.state == .holding && verdict.itemID == pending.itemID
		if stillInHand {
			landing = nil
			return []
		}
		return [checkOff(pending.itemID, seen: pending.seen, at: pending.time)]
	}

	private mutating func checkBasket(_ verdict: FrameVerdict) -> [Event] {
		var events: [Event] = []
		for itemID in verdict.inBasket where !inCooldown(itemID, at: verdict.time) {
			let stillInHand = verdict.state != .empty && verdict.itemID == itemID
			let recentHold = held.flatMap { $0.itemID == itemID && verdict.time - $0.time <= tuning.holdMemory ? $0 : nil }
			let seenBefore = basketSightings[itemID].map { verdict.time > $0 && verdict.time - $0 <= tuning.basketWindow } ?? false
			if let recentHold, !stillInHand {
				events.append(checkOff(itemID, seen: recentHold.seen, at: verdict.time))
			} else if seenBefore {
				events.append(checkOff(itemID, seen: "", at: verdict.time))
			} else {
				basketSightings[itemID] = verdict.time
			}
		}
		return events
	}

	private mutating func checkOff(_ itemID: ListItem.ID, seen: String, at time: TimeInterval) -> Event {
		lastDrop[itemID] = time
		basketSightings[itemID] = nil
		if held?.itemID == itemID {
			held = nil
		}
		if landing?.itemID == itemID {
			landing = nil
		}
		return .checkedOff(itemID: itemID, seen: seen)
	}

	private func inCooldown(_ itemID: ListItem.ID, at time: TimeInterval) -> Bool {
		lastDrop[itemID].map { time - $0 < tuning.dropCooldown } ?? false
	}

	private mutating func hold(_ verdict: FrameVerdict) -> [Event] {
		guard let itemID = verdict.itemID else {
			return forgetIfStale(at: verdict.time)
		}
		let changed = held?.itemID != itemID
		held = Sighting(itemID: itemID, seen: verdict.seen, time: verdict.time)
		return changed ? [.holding(itemID: itemID, seen: verdict.seen)] : []
	}

	private mutating func startLanding(_ verdict: FrameVerdict) {
		let recentHold = held.flatMap { verdict.time - $0.time <= tuning.holdMemory ? $0 : nil }
		guard let itemID = verdict.itemID ?? recentHold?.itemID, landing == nil else {
			return
		}
		if inCooldown(itemID, at: verdict.time) {
			return
		}
		let fromHold = recentHold?.itemID == itemID ? recentHold?.seen : nil
		let seen = fromHold.flatMap { $0.count > verdict.seen.count ? $0 : nil } ?? verdict.seen
		landing = Sighting(itemID: itemID, seen: seen, time: verdict.time)
	}

	private mutating func forgetIfStale(at time: TimeInterval) -> [Event] {
		guard let held, time - held.time > tuning.holdMemory else {
			return []
		}
		self.held = nil
		return [.released]
	}
}
