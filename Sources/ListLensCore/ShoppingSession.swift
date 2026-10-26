import Foundation

/// Watches a live frame feed and checks list items off as they go into the cart.
public actor ShoppingSession {
	public enum Update: Sendable {
		case list(title: String, items: [ListItem])
		case verdict(FrameVerdict, MuseClient.Reply)
		case event(CartWatcher.Event)
		case failure(String)
	}

	/// Returns the newest camera frame as a 480 px JPEG, or nil when none has arrived yet.
	public typealias FrameProvider = @Sendable () async -> Data?

	private let judge: FrameJudge
	private let list: any ListSource
	private let latestFrame: FrameProvider
	private let maxInFlight: Int
	private var watcher: CartWatcher
	private var items: [ListItem] = []
	private var inFlight = 0
	private var loop: Task<Void, Never>?
	private var continuation: AsyncStream<Update>.Continuation?
	private let clock = ContinuousClock()
	private var startedAt: ContinuousClock.Instant?

	public init(
		judge: FrameJudge,
		list: any ListSource,
		watcher: CartWatcher = CartWatcher(),
		maxInFlight: Int = 3,
		latestFrame: @escaping FrameProvider
	) {
		self.judge = judge
		self.list = list
		self.watcher = watcher
		self.maxInFlight = maxInFlight
		self.latestFrame = latestFrame
	}

	public func start() -> AsyncStream<Update> {
		let (stream, continuation) = AsyncStream.makeStream(of: Update.self)
		self.continuation = continuation
		startedAt = clock.now
		loop = Task { await run() }
		return stream
	}

	public func stop() {
		loop?.cancel()
		loop = nil
		continuation?.finish()
		continuation = nil
	}

	public func setChecked(_ itemID: ListItem.ID, _ isChecked: Bool) async {
		try? await list.setChecked(itemID, isChecked)
		await refreshList()
	}

	private func run() async {
		await refreshList()
		while !Task.isCancelled {
			if inFlight < maxInFlight, let jpeg = await latestFrame() {
				let time = elapsed
				let pending = items.filter { !$0.isChecked }
				if !pending.isEmpty {
					inFlight += 1
					Task { await judgeFrame(jpeg, at: time, against: pending) }
				}
			}
			try? await Task.sleep(for: .seconds(watcher.nextInterval))
		}
	}

	private func judgeFrame(_ jpeg: Data, at time: TimeInterval, against pending: [ListItem]) async {
		defer { inFlight -= 1 }
		do {
			let judgement = try await judge.judge(jpeg: jpeg, at: time, against: pending)
			continuation?.yield(.verdict(judgement.verdict, judgement.reply))
			for event in watcher.ingest(judgement.verdict) {
				if case .checkedOff(let itemID, _) = event {
					try? await list.setChecked(itemID, true)
					await refreshList()
				}
				continuation?.yield(.event(event))
			}
		} catch {
			continuation?.yield(.failure(String(describing: error)))
		}
	}

	private func refreshList() async {
		do {
			items = try await list.items()
			continuation?.yield(.list(title: await list.title, items: items))
		} catch {
			continuation?.yield(.failure("Couldn't read the list: \(error)"))
		}
	}

	private var elapsed: TimeInterval {
		guard let startedAt else {
			return 0
		}
		let duration = clock.now - startedAt
		return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
	}
}
