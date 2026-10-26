import Foundation
import ListLensCore
import ListLensGlasses
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
	struct Held: Equatable {
		let name: String
		let seen: String
	}

	struct CheckOff: Equatable {
		let itemID: ListItem.ID
		let name: String
		let seen: String
	}

	struct LogLine: Identifiable {
		let id = UUID()
		let text: String
		let isEvent: Bool
	}

	private static let listKey = "list"
	private static let apiKeyAccount = "meta-model-api"
	private static let drawsOnGlassesKey = "drawsOnGlasses"
	private static let checkOffShownFor: Duration = .seconds(4)
	private static let model = "muse-spark-1.3"

	let glasses = GlassesLink()
	var listTitle: String {
		didSet { save() }
	}
	var items: [ListItem] {
		didSet { save() }
	}
	var apiKey: String {
		didSet { Keychain.write(apiKey, for: Self.apiKeyAccount) }
	}
	var drawsOnGlasses: Bool {
		didSet { UserDefaults.standard.set(drawsOnGlasses, forKey: Self.drawsOnGlassesKey) }
	}
	private(set) var isShopping = false
	private(set) var held: Held?
	private(set) var lastCheckOff: CheckOff?
	private(set) var log: [LogLine] = []
	private(set) var calls = 0
	private(set) var cost = 0.0
	private(set) var medianLatency: Double?
	private(set) var preview: UIImage?
	var errorMessage: String?

	@ObservationIgnored private var session: ShoppingSession?
	@ObservationIgnored private var trip: TripRecorder?
	/// Where trips are saved. Visible in the Files app under On My iPhone › ListLens.
	static let tripsFolder = URL.documentsDirectory.appending(path: "trips", directoryHint: .isDirectory)
	@ObservationIgnored private var latencies: [Double] = []
	@ObservationIgnored private var tasks: [Task<Void, Never>] = []
	@ObservationIgnored private var checkOffTimer: Task<Void, Never>?

	init() {
		let saved = UserDefaults.standard.data(forKey: Self.listKey).flatMap { try? JSONDecoder().decode(SavedList.self, from: $0) }
		listTitle = saved?.title ?? "Groceries"
		items = saved?.items ?? ["Apples", "Milk", "Eggs", "Ground beef", "Frozen spinach"].map { ListItem(name: $0) }
		apiKey = Keychain.read(Self.apiKeyAccount) ?? ""
		drawsOnGlasses = UserDefaults.standard.object(forKey: Self.drawsOnGlassesKey) as? Bool ?? true
		importKeyFile()
		glasses.onDisplayReady = { [weak self] in
			self?.render()
		}
		glasses.onLog = { [weak self] message in
			self?.append("glasses: \(message)", isEvent: false)
		}
	}

	var remaining: Int {
		items.filter { !$0.isChecked }.count
	}

	func startShopping() async {
		guard !apiKey.isEmpty else {
			errorMessage = "Add your Meta Model API key in Settings first."
			return
		}
		guard !isShopping else {
			return
		}
		isShopping = true
		log = []
		do {
			let trip = try TripRecorder(in: Self.tripsFolder, title: listTitle, items: items)
			self.trip = trip
			glasses.startRecording(to: trip.folder.appending(path: "glasses.mov"))
		} catch {
			append("Couldn't start recording this trip: \(error)", isEvent: false)
		}
		append("Start shopping", isEvent: true)
		calls = 0
		cost = 0
		latencies = []
		medianLatency = nil
		glasses.drawsOnDisplay = drawsOnGlasses
		await glasses.start()
		let glasses = self.glasses
		var latestFrame: ShoppingSession.FrameProvider = { glasses.latestJPEG() }
		#if DEBUG
		if let clip = MockGlasses.clip {
			latestFrame = { await clip.latestJPEG() }
		}
		#endif
		let session = ShoppingSession(
			judge: FrameJudge(client: MuseClient(apiKey: apiKey, model: Self.model)),
			list: LocalListSource(title: listTitle, items: items),
			latestFrame: latestFrame
		)
		self.session = session
		let updates = await session.start()
		tasks.append(Task { [weak self] in
			for await update in updates {
				self?.apply(update)
			}
		})
		tasks.append(Task { [weak self] in
			while !Task.isCancelled {
				if UIApplication.shared.applicationState == .active, let jpeg = await latestFrame() {
					self?.preview = UIImage(data: jpeg)
				}
				try? await Task.sleep(for: .milliseconds(500))
			}
		})
	}

	func stopShopping() async {
		append("Stop shopping", isEvent: true)
		await session?.stop()
		session = nil
		let videoStartedAt = await glasses.stopRecording()
		await trip?.finish(title: listTitle, items: items, model: Self.model, videoStartedAt: videoStartedAt)
		trip = nil
		tasks.forEach { $0.cancel() }
		tasks = []
		checkOffTimer?.cancel()
		glasses.stop()
		isShopping = false
		held = nil
		lastCheckOff = nil
		preview = nil
	}

	/// The wearer checking or unchecking by hand, on the phone or the glasses.
	func setChecked(_ itemID: ListItem.ID, _ isChecked: Bool) async {
		if let session {
			let time = await session.elapsed
			await trip?.event(isChecked ? .wearerChecked : .wearerUnchecked, at: time, itemID: itemID, itemName: name(of: itemID))
			await session.setChecked(itemID, isChecked)
		} else if let index = items.firstIndex(where: { $0.id == itemID }) {
			items[index].isChecked = isChecked
		}
	}

	func undo(_ itemID: ListItem.ID) async {
		checkOffTimer?.cancel()
		lastCheckOff = nil
		append("Undid \(name(of: itemID))", isEvent: true)
		await setChecked(itemID, false)
		render()
	}

	func addItem(_ name: String) {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else {
			return
		}
		items.append(ListItem(name: trimmed))
	}

	func uncheckAll() {
		for index in items.indices {
			items[index].isChecked = false
		}
	}

	private func apply(_ update: ShoppingSession.Update) {
		switch update {
		case .list(_, let latest):
			items = latest
			render()
		case .verdict(let verdict, let reply, let jpeg):
			record(reply)
			append(describe(verdict, reply), isEvent: false)
			let items = self.items
			Task { [trip] in await trip?.frame(jpeg, verdict: verdict, reply: reply, items: items) }
		case .event(let event):
			recordEvent(event)
			show(event)
		case .failure(let message):
			append(message, isEvent: false)
			Task { [trip, session] in
				let time = await session?.elapsed ?? 0
				await trip?.event(.failure, at: time, detail: message)
			}
		}
	}

	private func recordEvent(_ event: CartWatcher.Event) {
		let (kind, itemID, seen): (RecordedEvent.Kind, ListItem.ID?, String?) = switch event {
		case .holding(let itemID, let seen): (.holding, itemID, seen)
		case .released: (.released, nil, nil)
		case .checkedOff(let itemID, let seen): (.checkedOff, itemID, seen)
		}
		let itemName = itemID.map(name(of:))
		Task { [trip, session] in
			let time = await session?.elapsed ?? 0
			await trip?.event(kind, at: time, itemID: itemID, itemName: itemName, detail: seen)
		}
	}

	private func show(_ event: CartWatcher.Event) {
		switch event {
		case .holding(let itemID, let seen):
			held = Held(name: name(of: itemID), seen: seen)
			append("In hand: \(name(of: itemID))", isEvent: true)
			render()
		case .released:
			held = nil
			render()
		case .checkedOff(let itemID, let seen):
			held = nil
			lastCheckOff = CheckOff(itemID: itemID, name: name(of: itemID), seen: seen)
			append("Checked off \(name(of: itemID))", isEvent: true)
			UINotificationFeedbackGenerator().notificationOccurred(.success)
			checkOffTimer?.cancel()
			checkOffTimer = Task { [weak self] in
				try? await Task.sleep(for: Self.checkOffShownFor)
				guard !Task.isCancelled else {
					return
				}
				self?.lastCheckOff = nil
				self?.render()
			}
			render()
		}
	}

	/// Draws the current state on the glasses. Each send replaces the whole display.
	private func render() {
		guard glasses.isDisplayReady else {
			return
		}
		let screen = GlassesScreens.list(title: listTitle, status: glassesStatus, items: items) { [weak self] itemID in
			Task { @MainActor in
				guard let self, let item = self.items.first(where: { $0.id == itemID }) else {
					return
				}
				await self.setChecked(itemID, !item.isChecked)
			}
		}
		Task { await glasses.show(screen) }
	}

	/// The gray text in the glasses header: what just happened, or how much is left.
	private var glassesStatus: String {
		if let lastCheckOff {
			return "Got \(lastCheckOff.name)"
		}
		if let held {
			return "\(held.name) in hand"
		}
		return remaining == 0 ? "All done" : "\(remaining) left"
	}

	private func record(_ reply: MuseClient.Reply) {
		calls += 1
		cost += reply.cost
		latencies.append(Double(reply.latency.components.attoseconds) / 1e18 + Double(reply.latency.components.seconds))
		medianLatency = latencies.sorted()[latencies.count / 2]
	}

	private func describe(_ verdict: FrameVerdict, _ reply: MuseClient.Reply) -> String {
		let ms = Int((Double(reply.latency.components.attoseconds) / 1e15).rounded()) + Int(reply.latency.components.seconds) * 1000
		let state = switch verdict.state {
		case .empty: "·"
		case .holding: "hold"
		case .intoCart: "cart"
		}
		let match = verdict.itemID.map { name(of: $0) } ?? ""
		let basket = verdict.inBasket.isEmpty ? "" : " · basket: \(verdict.inBasket.map(name(of:)).joined(separator: ", "))"
		return String(format: "%6.1fs %@ %@ %@%@ · %d ms", verdict.time, state, match, verdict.seen, basket, ms)
	}

	private func append(_ text: String, isEvent: Bool) {
		log.insert(LogLine(text: text, isEvent: isEvent), at: 0)
		if log.count > 200 {
			log.removeLast()
		}
		Self.writeToLogFile(text)
		Task { [trip] in await trip?.log(text) }
	}

	/// Kept in Documents so a Mac can pull it with `xcrun devicectl device copy from`.
	private static func writeToLogFile(_ text: String) {
		let file = URL.documentsDirectory.appending(path: "listlens.log")
		let line = Data("\(Date.now.formatted(.iso8601)) \(text)\n".utf8)
		if let handle = try? FileHandle(forWritingTo: file) {
			handle.seekToEndOfFile()
			handle.write(line)
			try? handle.close()
		} else {
			try? line.write(to: file)
		}
	}

	private func name(of itemID: ListItem.ID) -> String {
		items.first(where: { $0.id == itemID })?.name ?? itemID
	}

	/// A key copied into Documents from a Mac (`xcrun devicectl device copy to`) moves into the keychain
	/// on launch and the file is deleted, so a long key never has to be typed on the phone.
	private func importKeyFile() {
		let file = URL.documentsDirectory.appending(path: "meta-model-api-key")
		guard let key = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
			return
		}
		try? FileManager.default.removeItem(at: file)
		if !key.isEmpty {
			apiKey = key
		}
	}

	private func save() {
		if let data = try? JSONEncoder().encode(SavedList(title: listTitle, items: items)) {
			UserDefaults.standard.set(data, forKey: Self.listKey)
		}
	}
}

private struct SavedList: Codable {
	let title: String
	let items: [ListItem]
}
