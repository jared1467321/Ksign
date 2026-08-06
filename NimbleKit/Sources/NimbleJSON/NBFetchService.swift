//
//  FetchService.swift
//  Loader
//
//  Created by samara on 14.03.2025.
//

import Foundation

// MARK: - Class
public class NBFetchService {
	public enum NBFetchServiceError: Error, LocalizedError {
		case invalidURL
		case networkError(Error)
		case httpError(statusCode: Int)
		case noData
		case parsingError(Error)

		public var errorDescription: String? {
			switch self {
			case .invalidURL:
				return "The URL is invalid."
			case .networkError(let error):
				return "Network error: \(error.localizedDescription)"
			case .httpError(let statusCode):
				return "The server returned HTTP \(statusCode)."
			case .noData:
				return "No data received."
			case .parsingError(let error):
				return "Failed to parse data: \(error.localizedDescription)"
			}
		}
	}

	public init() {}
}

// MARK: - Class extension: fetch
extension NBFetchService {
	public func fetch<T: Decodable>(
		from urlString: String,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		guard let url = URL(string: urlString) else {
			completion(.failure(NBFetchServiceError.invalidURL))
			return
		}

		fetch(from: url, completion: completion)
	}

	public func fetch<T: Decodable>(
		from url: URL,
		completion: @escaping (Result<T, Error>) -> Void
	) {
		var request = URLRequest(
			url: url,
			cachePolicy: .reloadIgnoringLocalCacheData,
			timeoutInterval: 30
		)
		request.setValue("application/json", forHTTPHeaderField: "Accept")

		let task = URLSession.shared.dataTask(with: request) { data, response, error in
			if let error {
				completion(.failure(NBFetchServiceError.networkError(error)))
				return
			}

			if
				let response = response as? HTTPURLResponse,
				!(200...299).contains(response.statusCode)
			{
				completion(.failure(NBFetchServiceError.httpError(statusCode: response.statusCode)))
				return
			}

			guard let data else {
				completion(.failure(NBFetchServiceError.noData))
				return
			}

			do {
				let decodedData = try JSONDecoder().decode(T.self, from: data)
				completion(.success(decodedData))
			} catch {
				completion(.failure(NBFetchServiceError.parsingError(error)))
			}
		}

		task.resume()
	}
}
