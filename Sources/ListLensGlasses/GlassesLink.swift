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
	/// Runs whenever the display comes up, so the caller can draw the current screen.
	public var onDisplayReady: (@MainActor () -> Void)?

	@ObservationIgnored private let wearables = Wearables.shared
	@ObservationIgnored private nonisolated let decoder = FrameDecoder()
	@ObservationIgnored private let mic = MicKeepAlive()
	@ObservationIgnored private let tokens = ListenerTokenBag()
	@ObservationIgnored private var session: DeviceSession?
	@ObservationIgnored private var camera: Camera?
	@ObservationIgnored private var display: Display?
	@ObservationIgnored private var tasks: [Task<Void, Never>] = []

	/// Call once at launch, before anything else touches the toolkit.
	public static func configure() {
		try? Wearables.configure()
	}

	public init() {
		registration = Wearables.shared.registrationState
		tasks.append(Task { [weak self] in
			for await state in Wearables.shared.registrationStateStream() {
				self?.registration = state
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
			return
		}
		phase = .connecting
		do {
			if try await wearables.checkPermissionStatus(.camera) != .granted {
				guard try await wearables.requestPermission(.camera) == .granted else {
					phase = .failed("ListLens needs the glasses camera. Allow it in the Meta AI app.")
					return
				}
			}
			let session = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables))
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
					self?.phase = .failed(error.localizedDescription)
				}
			})
			try session.start()
		} catch {
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

	public nonisolated var framesDecoded: Int {
		decoder.frameCount
	}

	/// Replaces everything on the glasses display. There is no partial update.
	public func show(_ screen: FlexBox) async {
		guard let display, isDisplayReady else {
			return
		}
		try? await display.send(screen)
	}

	private func sessionChanged(to state: DeviceSessionState, on session: DeviceSession) {
		switch state {
		case .started:
			attachCamera(to: session)
		case .stopped:
			stop()
		default:
			break
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
			let decoder = self.decoder
			camera.stream.videoFramePublisher.listen { [weak self] frame in
				decoder.decode(frame.sampleBuffer)
				if decoder.frameCount == 1 {
					Task { @MainActor in self?.firstFrameArrived(on: session) }
				}
			}.store(in: tokens)
			camera.stream.start()
		} catch {
			phase = .failed(error.localizedDescription)
		}
	}

	/// The display and microphone wait for the first frame: a capability added before the glasses
	/// have fully arrived fails without an error.
	private func firstFrameArrived(on session: DeviceSession) {
		phase = .streaming
		try? mic.start()
		guard display == nil else {
			return
		}
		do {
			let display = try session.addDisplay()
			self.display = display
			display.statePublisher.listen { [weak self] state in
				Task { @MainActor in self?.displayChanged(to: state) }
			}.store(in: tokens)
			display.start()
		} catch {
			phase = .failed("The glasses display didn't start: \(error.localizedDescription)")
		}
	}

	private func displayChanged(to state: DisplayState) {
		isDisplayReady = state == .started
		if isDisplayReady {
			onDisplayReady?()
		}
	}
}
#endif
