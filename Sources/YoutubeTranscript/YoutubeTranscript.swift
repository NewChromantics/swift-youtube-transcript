// YoutubeTranscript.swift
// Updated to use Android client context for Innertube API, which returns captions
// reliably in 2025+. The WEB client no longer returns captionTracks in many cases.

import Foundation

// MARK: - Public Types

public struct TranscriptConfig {
	public let lang: String?
	
	public init(lang: String? = nil) {
		self.lang = lang
	}
}

public struct TranscriptResponse {
	public let text: String
	public let offset: Double  // seconds
	public let duration: Double
	
	public init(text: String, offset: Double, duration: Double) {
		self.text = text
		self.offset = offset
		self.duration = duration
	}
}

public enum YoutubeTranscriptError: Error, LocalizedError {
	case tooManyRequests
	case videoUnavailable
	case disabled
	case notAvailable
	case notAvailableLanguage(String, [String])
	case emptyTranscript
	case invalidVideoId
	case networkError(Error)
	case parsingError(String)
	
	public var errorDescription: String? {
		switch self {
			case .tooManyRequests:
				return "YouTube is rate-limiting your IP. Try again later."
			case .videoUnavailable:
				return "The video is not available."
			case .disabled:
				return "Transcripts are disabled for this video."
			case .notAvailable:
				return "No transcripts are available for this video."
			case .notAvailableLanguage(let requested, let available):
				return "No transcript in language '\(requested)'. Available: \(available.joined(separator: ", "))"
			case .emptyTranscript:
				return "The transcript is empty."
			case .invalidVideoId:
				return "The video ID is invalid."
			case .networkError(let underlying):
				return "Network error: \(underlying.localizedDescription)"
			case .parsingError(let detail):
				return "Failed to parse YouTube response: \(detail)"
		}
	}
}

// MARK: - Innertube Response Models

private struct PlayerResponse: Decodable {
	let playabilityStatus: PlayabilityStatus?
	let captions: CaptionsWrapper?
}

private struct PlayabilityStatus: Decodable {
	let status: String?
	let reason: String?
}

private struct CaptionsWrapper: Decodable {
	let playerCaptionsTracklistRenderer: TracklistRenderer?
}

private struct TracklistRenderer: Decodable {
	let captionTracks: [CaptionTrack]?
}

private struct CaptionTrack: Decodable {
	let baseUrl: String
	let languageCode: String
	let name: CaptionTrackName?
	let kind: String?
}

private struct CaptionTrackName: Decodable {
	let simpleText: String?
}

// MARK: - Main Entry Point

public enum YoutubeTranscript {
	
	/// Fetches the transcript for a YouTube video.
	/// - Parameters:
	///   - videoId: A YouTube video ID or supported URL format.
	///   - config: Optional configuration (e.g. language preference).
	/// - Returns: An array of `TranscriptResponse` items with text, offset, and duration.
	public static func fetchTranscript(
		for videoId: String,
		config: TranscriptConfig = .init()
	) async throws -> [TranscriptResponse] {
		let id = try extractVideoId(from: videoId)
		let videoURL = "https://www.youtube.com/watch?v=\(id)"
		
		// Step 1: Fetch the video page HTML to extract INNERTUBE_API_KEY
		let html = try await fetchHTML(url: videoURL)
		
		// Check for rate limiting
		if html.contains("class=\"g-recaptcha\"") || html.contains("Sorry for the interruption") {
			throw YoutubeTranscriptError.tooManyRequests
		}
		
		let apiKey = try extractInnertubeApiKey(from: html)
		
		// Step 2: Call the Innertube player API using Android client context
		// The Android client reliably returns captionTracks; the WEB client often does not.
		let playerResponse = try await fetchPlayerResponse(videoId: id, apiKey: apiKey)
		
		// Check playability
		if let status = playerResponse.playabilityStatus?.status,
		   status == "ERROR" || status == "UNPLAYABLE" || status == "LOGIN_REQUIRED" {
			throw YoutubeTranscriptError.videoUnavailable
		}
		
		// Step 3: Find the caption track URL
		guard let tracklist = playerResponse.captions?.playerCaptionsTracklistRenderer,
			  let tracks = tracklist.captionTracks, !tracks.isEmpty else {
			throw YoutubeTranscriptError.disabled
		}
		
		let track = try selectTrack(from: tracks, lang: config.lang)
		
		// Remove &fmt=... suffix so we always get the plain XML format
		let baseUrl = track.baseUrl
			.replacingOccurrences(of: #"&fmt=\w+"#, with: "", options: .regularExpression)
		
		// Step 4: Fetch and parse the captions XML
		let transcriptItems = try await fetchAndParseTranscript(from: baseUrl)
		
		if transcriptItems.isEmpty {
			throw YoutubeTranscriptError.emptyTranscript
		}
		
		return transcriptItems
	}
}

// MARK: - Private Helpers

private extension YoutubeTranscript {
	
	// MARK: Video ID Extraction
	
	static func extractVideoId(from input: String) throws -> String {
		// Already a bare 11-char ID?
		if input.range(of: #"^[a-zA-Z0-9_-]{11}$"#, options: .regularExpression) != nil {
			return input
		}
		
		// Standard watch URL: youtube.com/watch?v=ID
		if let url = URL(string: input),
		   let host = url.host,
		   host.contains("youtube.com") || host.contains("youtu.be") {
			
			if host.contains("youtu.be") {
				let id = url.pathComponents.dropFirst().first ?? ""
				if isValidId(id) { return id }
			}
			
			// /watch?v=, /shorts/, /embed/
			let pathComponents = url.pathComponents
			if let shortsIdx = pathComponents.firstIndex(of: "shorts"),
			   shortsIdx + 1 < pathComponents.count {
				let id = pathComponents[shortsIdx + 1]
				if isValidId(id) { return id }
			}
			if let embedIdx = pathComponents.firstIndex(of: "embed"),
			   embedIdx + 1 < pathComponents.count {
				let id = pathComponents[embedIdx + 1]
				if isValidId(id) { return id }
			}
			
			if let query = url.query {
				let params = query
					.split(separator: "&")
					.map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
					.filter { $0.count == 2 }
				for param in params {
					if param[0] == "v" && isValidId(param[1]) {
						return param[1]
					}
				}
			}
		}
		
		throw YoutubeTranscriptError.invalidVideoId
	}
	
	static func isValidId(_ id: String) -> Bool {
		id.range(of: #"^[a-zA-Z0-9_-]{11}$"#, options: .regularExpression) != nil
	}
	
	// MARK: Fetch HTML
	
	static func fetchHTML(url: String) async throws -> String {
		guard let requestURL = URL(string: url) else {
			throw YoutubeTranscriptError.invalidVideoId
		}
		var request = URLRequest(url: requestURL)
		// Use a realistic browser User-Agent to get the full page
		request.setValue(
			"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
			forHTTPHeaderField: "User-Agent"
		)
		request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
			throw YoutubeTranscriptError.tooManyRequests
		}
		
		guard let html = String(data: data, encoding: .utf8) else {
			throw YoutubeTranscriptError.parsingError("Could not decode HTML as UTF-8")
		}
		return html
	}
	
	// MARK: Extract INNERTUBE_API_KEY
	
	static func extractInnertubeApiKey(from html: String) throws -> String {
		// Try the standard key pattern
		let patterns = [
			#""INNERTUBE_API_KEY":"([^"]+)""#,
			#""innertubeApiKey":"([^"]+)""#,
			#"'INNERTUBE_API_KEY':'([^']+)'"#
		]
		for pattern in patterns {
			if let match = html.range(of: pattern, options: .regularExpression) {
				let slice = String(html[match])
				// Extract just the key value between the last pair of quotes
				let parts = slice.components(separatedBy: "\"")
				if parts.count >= 4 {
					return parts[3]
				}
				let singleParts = slice.components(separatedBy: "'")
				if singleParts.count >= 4 {
					return singleParts[3]
				}
			}
		}
		// Fallback: YouTube sometimes works without the key (key may be deprecated)
		// Use the keyless endpoint in that case
		return "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w" // well-known public fallback
	}
	
	// MARK: Fetch Player Response (Android Client)
	
	static func fetchPlayerResponse(videoId: String, apiKey: String) async throws -> PlayerResponse {
		// IMPORTANT: Using ANDROID client context is the key fix.
		// The WEB client stopped returning captionTracks for many videos in 2024/2025.
		// The ANDROID client consistently returns them.
		let endpoint = "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false"
		
		let body: [String: Any] = [
			"context": [
				"client": [
					"clientName": "ANDROID",
					"clientVersion": "20.10.38",
					"androidSdkVersion": 30,
					"userAgent": "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
					"hl": "en",
					"timeZone": "UTC",
					"utcOffsetMinutes": 0
				]
			],
			"videoId": videoId,
			"contentCheckOk": true,
			"racyCheckOk": true
		]
		
		guard let url = URL(string: endpoint) else {
			throw YoutubeTranscriptError.parsingError("Invalid Innertube endpoint URL")
		}
		guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
			throw YoutubeTranscriptError.parsingError("Failed to encode request body")
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = bodyData
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue(
			"com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
			forHTTPHeaderField: "User-Agent"
		)
		request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
		request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
		request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
		request.setValue("20.10.38", forHTTPHeaderField: "X-YouTube-Client-Version")
		
		do {
			let (data, response) = try await URLSession.shared.data(for: request)
			
			if let httpResponse = response as? HTTPURLResponse {
				if httpResponse.statusCode == 429 {
					throw YoutubeTranscriptError.tooManyRequests
				}
				guard (200..<300).contains(httpResponse.statusCode) else {
					throw YoutubeTranscriptError.parsingError("HTTP \(httpResponse.statusCode) from player API")
				}
			}
			
			let decoder = JSONDecoder()
			return try decoder.decode(PlayerResponse.self, from: data)
		} catch let error as YoutubeTranscriptError {
			throw error
		} catch let decodingError as DecodingError {
			throw YoutubeTranscriptError.parsingError("Decoding error: \(decodingError)")
		} catch {
			throw YoutubeTranscriptError.networkError(error)
		}
	}
	
	// MARK: Select Caption Track
	
	static func selectTrack(from tracks: [CaptionTrack], lang: String?) throws -> CaptionTrack {
		// Filter out auto-generated ASR tracks if a manual one exists
		let manualTracks = tracks.filter { $0.kind != "asr" }
		
		if let requestedLang = lang {
			// Try exact match first
			if let track = tracks.first(where: { $0.languageCode == requestedLang }) {
				return track
			}
			// Try prefix match (e.g. "en" matches "en-US")
			if let track = tracks.first(where: { $0.languageCode.hasPrefix(requestedLang) }) {
				return track
			}
			let available = tracks.map { $0.languageCode }
			throw YoutubeTranscriptError.notAvailableLanguage(requestedLang, available)
		}
		
		// No language specified: prefer English manual, then any manual, then any track
		if let enTrack = manualTracks.first(where: { $0.languageCode.hasPrefix("en") }) {
			return enTrack
		}
		if let firstManual = manualTracks.first {
			return firstManual
		}
		// Fall back to ASR / auto-generated
		if let enAsr = tracks.first(where: { $0.languageCode.hasPrefix("en") }) {
			return enAsr
		}
		guard let first = tracks.first else {
			throw YoutubeTranscriptError.notAvailable
		}
		return first
	}
	
	// MARK: Fetch and Parse Transcript XML
	
	static func fetchAndParseTranscript(from urlString: String) async throws -> [TranscriptResponse] {
		guard let url = URL(string: urlString) else {
			throw YoutubeTranscriptError.parsingError("Invalid transcript URL: \(urlString)")
		}
		
		let (data, _) = try await URLSession.shared.data(from: url)
		guard let xml = String(data: data, encoding: .utf8) else {
			throw YoutubeTranscriptError.parsingError("Could not decode transcript XML as UTF-8")
		}
		
		return try parseTranscriptXML(xml)
	}
	
	// MARK: Parse Transcript XML (no external dependencies)
	
	/// Parses YouTube's transcript XML format:
	/// <transcript>
	///   <text start="0.5" dur="2.5">Hello world</text>
	///   ...
	/// </transcript>
	static func parseTranscriptXML(_ xml: String) throws -> [TranscriptResponse] {
		// Use a simple regex-based approach to avoid requiring XMLParser delegate boilerplate.
		// For a production library, an XMLParser delegate is cleaner; this is dependency-free.
		let pattern = #"<text[^>]+start="([^"]+)"[^>]*dur="([^"]+)"[^>]*>([\s\S]*?)<\/text>"#
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			throw YoutubeTranscriptError.parsingError("Failed to compile transcript regex")
		}
		
		let nsXML = xml as NSString
		let matches = regex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))
		
		var results: [TranscriptResponse] = []
		for match in matches {
			guard match.numberOfRanges == 4 else { continue }
			
			let startStr  = nsXML.substring(with: match.range(at: 1))
			let durStr    = nsXML.substring(with: match.range(at: 2))
			let rawText   = nsXML.substring(with: match.range(at: 3))
			
			guard let start = Double(startStr), let dur = Double(durStr) else { continue }
			
			let cleanText = unescapeHTML(rawText)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			
			if !cleanText.isEmpty {
				results.append(TranscriptResponse(text: cleanText, offset: start, duration: dur))
			}
		}
		
		return results
	}
	
	/// Decodes common HTML entities found in YouTube caption XML.
	static func unescapeHTML(_ input: String) -> String {
		var result = input
		let entities: [(String, String)] = [
			("&amp;",   "&"),
			("&lt;",    "<"),
			("&gt;",    ">"),
			("&quot;",  "\""),
			("&#39;",   "'"),
			("&apos;",  "'"),
			("&#x27;",  "'"),
			("&#x2F;",  "/"),
			("&nbsp;",  " "),
			// YouTube sometimes encodes newlines
			("&#10;",   " "),
			("&#13;",   " ")
		]
		for (entity, char) in entities {
			result = result.replacingOccurrences(of: entity, with: char)
		}
		// Handle numeric decimal entities like &#123;
		if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
			let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
			// Iterate in reverse to preserve indices
			for match in matches.reversed() {
				if let range = Range(match.range, in: result),
				   let codeRange = Range(match.range(at: 1), in: result),
				   let codePoint = UInt32(result[codeRange]),
				   let scalar = Unicode.Scalar(codePoint) {
					result.replaceSubrange(range, with: String(scalar))
				}
			}
		}
		return result
	}
}
