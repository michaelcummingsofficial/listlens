import Foundation
import ListLensCore

/**
 * Replays a trip the app recorded. Without `--rejudge` the cart watcher runs again over the
 * recorded verdicts, at no cost, which is how to tune its rules. With `--rejudge` every saved
 * frame goes back to Muse Spark first, which is how to tune the prompt.
 */
func replayTrip(_ folder: URL, rejudge: Bool, apiKey: String?) async throws {
	let decoder = JSONDecoder()
	decoder.dateDecodingStrategy = .iso8601
	let list = try decoder.decode(SavedTripList.self, from: Data(contentsOf: folder.appending(path: "list-start.json")))
	let recorded = try lines(folder.appending(path: "verdicts.jsonl"), as: RecordedVerdict.self, decoder).sorted { $0.time < $1.time }
	let events = (try? lines(folder.appending(path: "events.jsonl"), as: RecordedEvent.self, decoder)) ?? []
	let names = Dictionary(list.items.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
	let name = { (id: ListItem.ID?) in id.flatMap { names[$0] } ?? "-" }
	let judge = try rejudge ? FrameJudge(client: MuseClient(apiKey: apiKey ?? { throw ReplayError.noKey }())) : nil

	print("\(folder.lastPathComponent): \(list.title), \(recorded.count) frames, list: \(list.items.map(\.name).joined(separator: ", "))")
	print(rejudge ? "Judging every frame again with the current prompt.\n" : "Running the watcher again over the recorded verdicts.\n")

	var watcher = CartWatcher()
	var checked = Set(list.items.filter(\.isChecked).map(\.id))
	var wearer = events.filter { $0.kind == .wearerChecked || $0.kind == .wearerUnchecked }.sorted { $0.time < $1.time }
	var cost = 0.0
	var watcherChecks: [String] = []
	for entry in recorded {
		while let next = wearer.first, next.time <= entry.time {
			print(String(format: "%7.2f s  ☞ wearer %@ %@", next.time, next.kind == .wearerChecked ? "checked" : "unchecked", next.itemName ?? "-"))
			wearer.removeFirst()
		}
		var verdict = entry.verdict
		if let judge {
			let jpeg = try Data(contentsOf: folder.appending(path: "frames/\(entry.frame)"))
			let pending = list.items.filter { !checked.contains($0.id) }
			let judgement = try await judge.judge(jpeg: jpeg, at: entry.time, against: pending)
			verdict = judgement.verdict
			cost += judgement.reply.cost
		}
		let mark = switch verdict.state {
		case .empty: "     "
		case .holding: "hold "
		case .intoCart: "CART "
		}
		let basket = verdict.inBasket.isEmpty ? "" : "  basket: \(verdict.inBasket.map(name).joined(separator: ", "))"
		print(String(format: "%7.2f s  %@ %-14@ %-34@%@", verdict.time, mark, name(verdict.itemID), String(verdict.seen.prefix(34)), basket))
		for event in watcher.ingest(verdict) {
			switch event {
			case .holding(let itemID, _):
				print("           → holding \(name(itemID))")
			case .released:
				print("           → hand empty")
			case .checkedOff(let itemID, let seen):
				checked.insert(itemID)
				watcherChecks.append(name(itemID))
				print("           ✓ checked off \(name(itemID)) (\(seen))  frame \(entry.frame)")
			}
		}
	}
	for next in wearer {
		print(String(format: "%7.2f s  ☞ wearer %@ %@", next.time, next.kind == .wearerChecked ? "checked" : "unchecked", next.itemName ?? "-"))
	}
	let recordedChecks = events.filter { $0.kind == .checkedOff }.compactMap(\.itemName)
	print("\nChecked off in this replay: \(watcherChecks.isEmpty ? "nothing" : watcherChecks.joined(separator: ", "))")
	print("Checked off in the store:   \(recordedChecks.isEmpty ? "nothing" : recordedChecks.joined(separator: ", "))")
	let corrections = events.filter { $0.kind == .wearerChecked || $0.kind == .wearerUnchecked }
	if !corrections.isEmpty {
		print("Wearer corrections:         \(corrections.map { "\($0.kind == .wearerChecked ? "+" : "−")\($0.itemName ?? "-")" }.joined(separator: ", "))")
	}
	if rejudge {
		print(String(format: "Rejudging cost $%.4f", cost))
	}
}

enum ReplayError: Error, CustomStringConvertible {
	case noKey

	var description: String {
		"Set MODEL_API_KEY or save the key to ~/.meta-model-api-key"
	}
}

private func lines<T: Decodable>(_ url: URL, as type: T.Type, _ decoder: JSONDecoder) throws -> [T] {
	try String(contentsOf: url, encoding: .utf8)
		.split(separator: "\n")
		.map { try decoder.decode(T.self, from: Data($0.utf8)) }
}
