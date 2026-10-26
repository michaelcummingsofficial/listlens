import Foundation

/// One judged frame as it was recorded, alongside its JPEG in `frames/`.
public struct RecordedVerdict: Codable, Sendable {
	/// Seconds since the trip started.
	public let time: TimeInterval
	public let frame: String
	public let state: HandState
	public let seen: String
	public let itemID: ListItem.ID?
	public let itemName: String?
	public let inBasket: [ListItem.ID]
	public let latencyMs: Int
	public let inputTokens: Int
	public let outputTokens: Int
	/// The model's reply exactly as returned.
	public let reply: String

	public var verdict: FrameVerdict {
		FrameVerdict(time: time, state: state, seen: seen, itemID: itemID, inBasket: inBasket)
	}
}

/// Something that changed the list or the hand during a trip.
public struct RecordedEvent: Codable, Sendable {
	public enum Kind: String, Codable, Sendable {
		case holding
		case released
		/// ListLens checked the item off.
		case checkedOff
		/// The wearer checked or unchecked an item by hand. An uncheck right after a check-off
		/// marks a wrong one; a check by hand marks one ListLens missed.
		case wearerChecked
		case wearerUnchecked
		case failure
	}

	public let time: TimeInterval
	public let kind: Kind
	public let itemID: ListItem.ID?
	public let itemName: String?
	public let detail: String?
}

public struct TripSummary: Codable, Sendable {
	public let startedAt: Date
	public let endedAt: Date
	/// When the first glasses video frame was written, to line the video up with trip time.
	public let videoStartedAt: Date?
	public let model: String
	public let frames: Int
	public let failures: Int
	public let cost: Double
	public let medianLatencyMs: Int?
	public let checkedOff: [String]
}

/**
 * Writes everything one shopping trip produces, as it happens, so a trip that ends badly is
 * still on disk. A trip folder holds `frames/` (every JPEG sent to Muse Spark), `verdicts.jsonl`,
 * `events.jsonl`, `log.txt`, `list-start.json`, `list-end.json`, `summary.json`, and the glasses
 * video when the app records one.
 */
public actor TripRecorder {
	public nonisolated let folder: URL
	public let startedAt: Date
	private let frames: URL
	private let encoder: JSONEncoder
	private var frameCount = 0
	private var failureCount = 0
	private var cost = 0.0
	private var latencies: [Int] = []
	private var checkedOff: [String] = []

	public init(in root: URL, title: String, items: [ListItem], startedAt: Date = .now) throws {
		let stamp = startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
		folder = root.appending(path: "trip-\(stamp)", directoryHint: .isDirectory)
		frames = folder.appending(path: "frames", directoryHint: .isDirectory)
		self.startedAt = startedAt
		encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
		try Self.write(SavedTripList(title: title, items: items), to: folder.appending(path: "list-start.json"), encoder: encoder)
	}

	public func frame(_ jpeg: Data, verdict: FrameVerdict, reply: MuseClient.Reply, items: [ListItem]) {
		frameCount += 1
		let name = String(format: "%05d_%07.2fs.jpg", frameCount, verdict.time)
		try? jpeg.write(to: frames.appending(path: name))
		let latencyMs = Int((Double(reply.latency.components.seconds) + Double(reply.latency.components.attoseconds) / 1e18) * 1000)
		cost += reply.cost
		latencies.append(latencyMs)
		append(
			RecordedVerdict(
				time: verdict.time,
				frame: name,
				state: verdict.state,
				seen: verdict.seen,
				itemID: verdict.itemID,
				itemName: verdict.itemID.flatMap { id in items.first { $0.id == id }?.name },
				inBasket: verdict.inBasket,
				latencyMs: latencyMs,
				inputTokens: reply.inputTokens,
				outputTokens: reply.outputTokens,
				reply: reply.text
			),
			to: "verdicts.jsonl"
		)
	}

	public func event(_ kind: RecordedEvent.Kind, at time: TimeInterval, itemID: ListItem.ID? = nil, itemName: String? = nil, detail: String? = nil) {
		if kind == .failure {
			failureCount += 1
		}
		if kind == .checkedOff, let itemName {
			checkedOff.append(itemName)
		}
		append(RecordedEvent(time: time, kind: kind, itemID: itemID, itemName: itemName, detail: detail), to: "events.jsonl")
	}

	public func log(_ line: String) {
		let entry = "\(Date.now.formatted(.iso8601)) \(line)\n"
		Self.appendLine(Data(entry.utf8), to: folder.appending(path: "log.txt"))
	}

	public func finish(title: String, items: [ListItem], model: String, videoStartedAt: Date?) {
		let sorted = latencies.sorted()
		let summary = TripSummary(
			startedAt: startedAt,
			endedAt: .now,
			videoStartedAt: videoStartedAt,
			model: model,
			frames: frameCount,
			failures: failureCount,
			cost: cost,
			medianLatencyMs: sorted.isEmpty ? nil : sorted[sorted.count / 2],
			checkedOff: checkedOff
		)
		try? Self.write(summary, to: folder.appending(path: "summary.json"), encoder: encoder)
		try? Self.write(SavedTripList(title: title, items: items), to: folder.appending(path: "list-end.json"), encoder: encoder)
	}

	private func append(_ value: some Encodable, to file: String) {
		guard var data = try? encoder.encode(value) else {
			return
		}
		data.append(0x0A)
		Self.appendLine(data, to: folder.appending(path: file))
	}

	private static func appendLine(_ data: Data, to url: URL) {
		if let handle = try? FileHandle(forWritingTo: url) {
			handle.seekToEndOfFile()
			handle.write(data)
			try? handle.close()
		} else {
			try? data.write(to: url)
		}
	}

	private static func write(_ value: some Encodable, to url: URL, encoder: JSONEncoder) throws {
		try encoder.encode(value).write(to: url)
	}
}

public struct SavedTripList: Codable, Sendable {
	public let title: String
	public let items: [ListItem]
}
