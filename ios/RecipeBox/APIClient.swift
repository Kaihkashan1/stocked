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

    func fetchRecipes() async throws -> RecipesResponse {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/recipes", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw APIError.badResponse(status)
        }

        let decoded = try JSONDecoder().decode(RecipesResponse.self, from: data)
        return decoded
    }

    private var trimmedBase: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
