#if os(iOS)
import AVFoundation

/// Keeps the glasses microphone open while shopping.
///
/// iOS suspends a backgrounded app about eight seconds after the phone locks, which drops the
/// glasses session. An active recording is background work iOS allows, so the session survives
/// the phone going into a pocket. Measured: 2.5 minutes locked at full frame rate.
final class MicKeepAlive {
	private let engine = AVAudioEngine()
	private(set) var isRunning = false

	func start() throws {
		guard !isRunning else {
			return
		}
		let audio = AVAudioSession.sharedInstance()
		try audio.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
		try audio.setActive(true)
		if let glasses = audio.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
			try audio.setPreferredInput(glasses)
		}
		let input = engine.inputNode
		input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { _, _ in }
		try engine.start()
		isRunning = true
	}

	func stop() {
		guard isRunning else {
			return
		}
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		isRunning = false
	}
}
#endif
