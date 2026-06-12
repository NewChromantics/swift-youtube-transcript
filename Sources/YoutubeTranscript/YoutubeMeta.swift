/*
	grab innerubte meta for video without needing an API key
*/ 
import Foundation


public struct Video
{
	private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/85.0.4183.83 Safari/537.36,gzip(gfe)"

	var videoUid : String
	
	public init(videoUid:String)
	{
		self.videoUid = videoUid
	}
	
	public func GetMeta(language:String?=nil) async throws -> InnerTubeResponse
	{
		let config = TranscriptConfig(lang: language)
		return try await Self.fetchTranscriptWithInnerTube(videoId: videoUid, config: config)
	}
	
		
	private static func fetchTranscriptWithInnerTube(videoId: String, config: TranscriptConfig) async throws -> InnerTubeResponse
	{
		let identifier = try retrieveVideoId(from: videoId)
		guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player") else {
			throw YoutubeTranscriptError.invalidVideoId
		}
		
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		
		if let lang = config.lang {
			request.setValue(lang, forHTTPHeaderField: "Accept-Language")
		}
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
		request.setValue("https://www.youtube.com/watch?v=\(identifier)", forHTTPHeaderField: "Referer")
		
		let body: [String: Any] = [
			"context": [
				"client": [
					"clientName": "WEB",
					"clientVersion": "2.20250312.04.00",
					"userAgent": userAgent,
				]
			],
			"videoId": identifier,
		]
		
		request.httpBody = try JSONSerialization.data(withJSONObject: body)
		
		let (data, _) = try await URLSession.shared.data(for: request)
		
		//	for debug, though the response should parse... but let the decoder deal with that
		guard let json = String(data:data, encoding: .utf8) else
		{
			throw YoutubeTranscriptError.parsingError("Failed to parse utf8 string from data")
		}
		print("Innertube caption response:\n\(json)")

		do
		{
			let decoder = JSONDecoder()
			let response = try decoder.decode(InnerTubeResponse.self, from: data)
			
			return response
		}
		catch
		{
			print(error)
			throw YoutubeTranscriptError.parsingError("Failed to parse json response: \(json)")
		}
	}
	
	
	private static func retrieveVideoId(from string: String) throws -> String {
		if string.count == 11 {
			return string
		}
		let regex = try! NSRegularExpression(
			pattern:
				"(?:youtube\\.com\\/(?:[^\\/]+\\/.+\\/|(?:v|e(?:mbed)?|shorts)\\/|.*[?&]v=)|youtu\\.be\\/)([^\"&?\\/\\s]{11})",
			options: .caseInsensitive
		)
		let range = NSRange(string.startIndex..., in: string)
		if let match = regex.firstMatch(in: string, range: range) {
			if let videoIdRange = Range(match.range(at: 1), in: string) {
				return String(string[videoIdRange])
			}
		}
		throw YoutubeTranscriptError.invalidVideoId
	}
}



public struct InnerTubeResponse: Codable 
{
	public var videoDetails : VideoDetails?
	public var thumbnail : URL?				
	{
		videoDetails?.thumbnail.thumbnails.first.map{ URL(string:$0.url) } ?? nil
	}
}

public struct VideoDetails : Codable
{
	public var title : String
	public var shortDescription : String
	public var lengthSeconds : String		//	always an int? but in a string!
	public var thumbnail : ThumbnailsMeta
}

public struct ThumbnailsMeta : Codable
{
	public var thumbnails : [ThumbnailMeta]
}

public struct ThumbnailMeta : Codable
{
	public var url : String
	public var width : Int
	public var height : Int
}
