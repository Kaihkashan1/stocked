import Foundation

enum APIError: LocalizedError {
    case badURL
    case unreachable(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The server address is not a valid URL."
        case .unreachable(let host):
            return "Could not reach \(host). Check your internet connection, or update the server address in Settings."
        case .badResponse(let code):
            return "The server returned HTTP \(code)."
        }
    }
}

struct APIClient {
    var baseURLString: String

    private static let decoder = JSONDecoder()
    private static let session: URLSession = {
        let cache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func fetchRecipes() async throws -> RecipesResponse {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/recipes", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError.badResponse(status)
        }

        return try Self.decoder.decode(RecipesResponse.self, from: data)
    }

    func updateRecipe(id: Int, patch: RecipePatch, secret: String) async throws -> Recipe {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/recipes/\(id)", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = try JSONEncoder().encode(patch)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError.badResponse(status)
        }
        return try Self.decoder.decode(Recipe.self, from: data)
    }

    private var trimmedBase: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
