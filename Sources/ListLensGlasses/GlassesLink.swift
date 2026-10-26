#if os(iOS)
import Foundation
import ListLensCore
import MWDATCamera
import MWDATCore
import MWDATDisplay
import Observation

/// One live connection to the glasses: the camera stream in, the display out.
@MainActor
@Observable
public final class GlassesLink {
	public enum Phase: Equatable, Sendable {
		case idle
		case connecting
		case streaming
		case failed(String)
	}

	public private(set) var phase: Phase = .idle
	public private(set) var registration: RegistrationState
	public private(set) var isDisplayReady = false
	/// Glasses that are paired, connected and being worn. A session can only start on these.
	public private(set) var hasActiveDevice = false
	/// Runs whenever the display comes up, so the caller can draw the current screen.
	public var onDisplayReady: (@MainActor () -> Void)?
	/// Each step of connecting, for the phone's log.
	public var onLog: (@MainActor (String) -> Void)?
	/// Off leaves the glasses display to whatever else is showing, such as a list app's own glasses screen.
	public var drawsOnDisplay = true

	@ObservationIgnored private let wearables = Wearables.shared
	@ObservationIgnored private nonisolated let decoder = FrameDecoder()
	@ObservationIgnored private let mic = MicKeepAlive()
	@ObservationIgnored private let tokens = ListenerTokenBag()
	@ObservationIgnored private var session: DeviceSession?
	/// Made at launch and kept: it needs time to find the glasses, so one made on demand
	/// reports no eligible device.
	@ObservationIgnored private let selector: AutoDeviceSelector
	@ObservationIgnored private var camera: Camera?
	@ObservationIgnored private var display: Display?
	@ObservationIgnored private var tasks: [Task<Void, Never>] = []

	/// Call once at launch, before anything else touches the toolkit.
	public static func configure() {
		try? Wearables.configure()
	}

	public init() {
		registration = Wearables.shared.registrationState
		let selector = AutoDeviceSelector(wearables: Wearables.shared)
		self.selector = selector
		hasActiveDevice = selector.activeDevice != nil
		tasks.append(Task { [weak self] in
			for await device in selector.activeDeviceStream() {
				self?.hasActiveDevice = device != nil
				self?.note(device == nil ? "no active glasses" : "glasses active")
			}
		})
		tasks.append(Task { [weak self] in
			for await state in Wearables.shared.registrationStateStream() {
				self?.registration = state
				self?.note("registration: \(state)")
			}
		})
	}

	/// Opens the Meta AI app so the wearer can allow ListLens to use their glasses.
	public func register() async throws {
		try await wearables.startRegistration()
	}

	/// Meta AI returns to ListLens through its URL scheme after registration and permission prompts.
	public func handle(_ url: URL) async {
		_ = try? await wearables.handleUrl(url)
	}

	public func start() async {
		guard session == nil else {
			note("start ignored: a session already exists")
			return
		}
		phase = .connecting
		note("starting, registration \(registration)")
		guard await waitForActiveDevice() else {
			note("no active glasses after waiting")
			phase = .failed("Put on your glasses and make sure they're connected in the Meta AI app.")
			return
		}
		do {
			let session = try wearables.createSession(deviceSelector: selector)
			self.session = session
			let states = session.stateStream()
			let errors = session.errorStream()
			tasks.append(Task { [weak self] in
				for await state in states {
					self?.sessionChanged(to: state, on: session)
				}
			})
			tasks.append(Task { [weak self] in
				for await error in errors {
					self?.note("session error: \(error)")
					self?.phase = .failed(error.localizedDescription)
				}
			})
			try session.start()
			note("session start requested")
		} catch {
			note("start failed: \(error)")
			phase = .failed(error.localizedDescription)
			stop()
		}
	}

	public func stop() {
		mic.stop()
		display?.stop()
		camera?.stop()
		session?.stop()
		tokens.clear()
		display = nil
		camera = nil
		session = nil
		decoder.reset()
		isDisplayReady = false
		if case .failed = phase {
			return
		}
		phase = .idle
	}

	/// The newest camera frame, sized for Muse Spark. Safe to call from any thread.
	public nonisolated func latestJPEG() -> Data? {
		decoder.latestImage().flatMap { JPEG.encode($0) }
	}

	/// Replaces everything on the glasses display. There is no partial update.
	public func show(_ screen: FlexBox) async {
		guard let display, isDisplayReady else {
			return
		}
		try? await display.send(screen)
	}

	private func sessionChanged(to state: DeviceSessionState, on session: DeviceSession) {
		note("session: \(state)")
		switch state {
		case .started:
			Task { await cameraPermissionThenAttach(to: session) }
		case .stopped:
			stop()
		default:
			break
		}
	}

	private func waitForActiveDevice(timeout: Duration = .seconds(15)) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while selector.activeDevice == nil, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(250))
		}
		return selector.activeDevice != nil
	}

	/// Asked once the session is up, as Meta's samples do. The first time, this opens Meta AI.
	private func cameraPermissionThenAttach(to session: DeviceSession) async {
		do {
			let status = try await wearables.checkPermissionStatus(.camera)
			note("camera permission: \(status)")
			if status != .granted {
				let answer = try await wearables.requestPermission(.camera)
				note("camera permission answer: \(answer)")
				guard answer == .granted else {
					phase = .failed("ListLens needs the glasses camera. Allow it in the Meta AI app.")
					return
				}
			}
			attachCamera(to: session)
		} catch {
			note("camera permission failed: \(error)")
			phase = .failed(error.localizedDescription)
		}
	}

	private func attachCamera(to session: DeviceSession) {
		guard camera == nil else {
			return
		}
		/**
		 * HEVC rather than raw: the SDK pauses a raw stream when the app leaves the foreground.
		 * Medium is 504×896, already near the 480 px the judge wants, and lighter on Bluetooth.
		 */
		let config = StreamConfiguration(videoCodec: .hvc1, resolution: .medium, frameRate: 15)
		do {
			guard let camera = try session.addCamera(config: config) else {
				phase = .failed("The glasses camera didn't start. Try again.")
				return
			}
			self.camera = camera
			note("camera attached")
			let decoder = self.decoder
			camera.stream.statePublisher.listen { [weak self] state in
				Task { @MainActor in
					self?.note("stream: \(state)")
					if state == .streaming {
						self?.deviceArrived(on: session)
					}
				}
			}.store(in: tokens)
			camera.stream.errorPublisher.listen { [weak self] error in
				Task { @MainActor in self?.note("stream error: \(error)") }
			}.store(in: tokens)
			camera.stream.videoFramePublisher.listen { [weak self] frame in
				let first = decoder.received == 0
				decoder.decode(frame.sampleBuffer)
				if first {
					Task { @MainActor in
						self?.note("first frame")
						self?.deviceArrived(on: session)
					}
				}
			}.store(in: tokens)
			camera.stream.start()
			note("stream start requested")
		} catch {
			phase = .failed(error.localizedDescription)
		}
	}

	/// The display and microphone wait until the camera is streaming: a capability added before the
	/// glasses have fully arrived fails without an error.
	private func deviceArrived(on session: DeviceSession) {
		guard phase != .streaming else {
			return
		}
		phase = .streaming
		do {
			try mic.start()
			note("microphone open")
		} catch {
			note("microphone failed: \(error)")
		}
		Task { [weak self] in
			try? await Task.sleep(for: .seconds(3))
			guard let self else {
				return
			}
			self.note("after 3 s: \(self.decoder.received) frames received, \(self.decoder.frameCount) decoded, \(self.decoder.failures) failed")
		}
		guard display == nil, drawsOnDisplay else {
			note(drawsOnDisplay ? "display already attached" : "leaving the glasses display alone")
			return
		}
		do {
			let display = try session.addDisplay()
			self.display = display
			display.statePublisher.listen { [weak self] state in
				Task { @MainActor in self?.displayChanged(to: state) }
			}.store(in: tokens)
			display.start()
			note("display requested")
		} catch {
			note("display failed: \(error)")
			phase = .failed("The glasses display didn't start: \(error.localizedDescription)")
		}
	}

	private func displayChanged(to state: DisplayState) {
		note("display: \(state)")
		isDisplayReady = state == .started
		if isDisplayReady {
			onDisplayReady?()
		}
	}

	private func note(_ message: String) {
		onLog?(message)
	}
}
#endif
