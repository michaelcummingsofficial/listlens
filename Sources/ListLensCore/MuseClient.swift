import Foundation

/// A minimal client for the Meta Model API Responses endpoint, with structured output.
public struct MuseClient: Sendable {
	public enum Part: Sendable {
		case text(String)
		case jpeg(Data)
		case mp4(Data)
	}

	public struct Reply: Sendable {
		public let text: String
		public let inputTokens: Int
		public let outputTokens: Int
		public let latency: Duration

		/// Muse Spark Standard mode list prices, per token.
		public var cost: Double {
			Double(inputTokens) * 1.25e-6 + Double(outputTokens) * 4.25e-6
		}
	}

	public struct Failure: Error, CustomStringConvertible {
		public let status: Int
		public let body: String
		public var description: String { "Meta Model API returned \(status): \(body.prefix(300))" }
	}

	public var apiKey: String
	public var model: String
	public var baseURL: URL
	public var session: URLSession

	public init(
		apiKey: String,
		model: String = "muse-spark-1.3",
		baseURL: URL = URL(string: "https://api.meta.ai/v1")!,
		session: URLSession = .shared
	) {
		self.apiKey = apiKey
		self.model = model
		self.baseURL = baseURL
		self.session = session
	}

	/// - Parameter schema: a JSON Schema as JSON data; the reply text is guaranteed to match it.
	public func respond(
		_ parts: [Part],
		schemaName: String,
		schema: Data,
		effort: String = "minimal",
		maxOutputTokens: Int = 1000
	) async throws -> Reply {
		let content: [[String: Any]] = parts.map { part in
			switch part {
			case .text(let text):
				["type": "input_text", "text": text]
			case .jpeg(let data):
				["type": "input_image", "image_url": "data:image/jpeg;base64,\(data.base64EncodedString())"]
			case .mp4(let data):
				["type": "input_video", "video_url": "data:video/mp4;base64,\(data.base64EncodedString())"]
			}
		}
		let body: [String: Any] = [
			"model": model,
			"input": [["type": "message", "role": "user", "content": content]],
			"reasoning": ["effort": effort],
			"max_output_tokens": maxOutputTokens,
			"text": ["format": [
				"type": "json_schema",
				"name": schemaName,
				"schema": try JSONSerialization.jsonObject(with: schema)
			]]
		]
		var request = URLRequest(url: baseURL.appending(path: "responses"))
		request.httpMethod = "POST"
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		let clock = ContinuousClock()
		let startedAt = clock.now
		let (data, response) = try await session.data(for: request)
		let latency = clock.now - startedAt
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard status == 200 else {
			throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
		}
		let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
		guard let text = decoded.output.flatMap({ $0.content ?? [] }).first(where: { $0.type == "output_text" })?.text else {
			throw Failure(status: status, body: "no output_text in reply")
		}
		return Reply(
			text: text,
			inputTokens: decoded.usage?.input_tokens ?? 0,
			outputTokens: decoded.usage?.output_tokens ?? 0,
			latency: latency
		)
	}
}

private struct ResponseBody: Decodable {
	struct Output: Decodable {
		struct Content: Decodable {
			let type: String
			let text: String?
		}

		let content: [Content]?
	}

	struct Usage: Decodable {
		let input_tokens: Int?
		let output_tokens: Int?
	}

	let output: [Output]
	let usage: Usage?
}
