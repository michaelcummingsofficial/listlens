import AVFoundation
import Foundation
import ListLensCore

/**
 * Replays a recorded glasses clip through the same judge and watcher the app uses, pacing frames
 * in video time the way the live session paces them in real time.
 *
 *     swift run listlens-replay clip.mov --list "Apples,Milk,Eggs"
 *
 * The API key comes from MODEL_API_KEY or ~/.meta-model-api-key.
 */

func apiKey() -> String? {
	if let key = ProcessInfo.processInfo.environment["MODEL_API_KEY"], !key.isEmpty {
		return key
	}
	let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".meta-model-api-key")
	return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
	exit(1)
}

func seconds(_ duration: Duration) -> Double {
	Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

var arguments = Array(CommandLine.arguments.dropFirst())
var listNames = ["Apples", "Milk", "Ground beef", "Frozen spinach", "Eggs", "Bananas"]
if let flag = arguments.firstIndex(of: "--list"), flag + 1 < arguments.count {
	listNames = arguments[flag + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
	arguments.removeSubrange(flag...(flag + 1))
}
guard let path = arguments.first else {
	fail("usage: listlens-replay <clip> [--list \"Apples,Milk,Eggs\"]")
}
guard let key = apiKey() else {
	fail("Set MODEL_API_KEY or save the key to ~/.meta-model-api-key")
}

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let judge = FrameJudge(client: MuseClient(apiKey: key))
var watcher = CartWatcher()
var items = listNames.map { ListItem(id: $0, name: $0) }
var time = 0.0
var calls = 0
var cost = 0.0
var latencies: [Double] = []

print("\(URL(fileURLWithPath: path).lastPathComponent), \(String(format: "%.1f", duration)) s, list: \(listNames.joined(separator: ", "))\n")
while time < duration {
	let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
	guard let jpeg = JPEG.encode(image) else {
		fail("Couldn't encode the frame at \(time) s")
	}
	let pending = items.filter { !$0.isChecked }
	let judgement = try await judge.judge(jpeg: jpeg, at: time, against: pending)
	let latency = seconds(judgement.reply.latency)
	calls += 1
	cost += judgement.reply.cost
	latencies.append(latency)
	let verdict = judgement.verdict
	let mark = switch verdict.state {
	case .empty: "     "
	case .holding: "hold "
	case .intoCart: "CART "
	}
	let match = verdict.itemID ?? "-"
	let basket = verdict.inBasket.isEmpty ? "" : "  basket: \(verdict.inBasket.joined(separator: ", "))"
	print(String(format: "%5.2f s  %@ %-14@ %-34@ %4.0f ms%@", time, mark, match, String(verdict.seen.prefix(34)), latency * 1000, basket))
	for event in watcher.ingest(verdict) {
		switch event {
		case .holding(let itemID, let seen):
			print("         → holding \(itemID) (\(seen))")
		case .released:
			print("         → hand empty")
		case .checkedOff(let itemID, let seen):
			if let index = items.firstIndex(where: { $0.id == itemID }) {
				items[index].isChecked = true
			}
			print(String(format: "         ✓ checked off %@ (%@), on the glasses at %.2f s", itemID, seen, time + latency))
		}
	}
	time += watcher.nextInterval
}

latencies.sort()
let checked = items.filter(\.isChecked).map(\.name)
print("\nChecked off: \(checked.isEmpty ? "nothing" : checked.joined(separator: ", "))")
print(String(
	format: "%d calls, $%.4f, latency p50 %.0f ms, p90 %.0f ms",
	calls,
	cost,
	latencies[latencies.count / 2] * 1000,
	latencies[min(latencies.count - 1, latencies.count * 9 / 10)] * 1000
))
