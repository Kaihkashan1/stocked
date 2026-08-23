import Foundation

enum APIError: LocalizedError {
    case badURL
    case unreachable(String)
    case badResponse(Int)
    /// A FastAPI HTTPException's `detail` — usually a real, actionable
    /// message (e.g. "Gemini's free daily quota is used up...") rather than
    /// just a status code.
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The server address is not a valid URL."
        case .unreachable(let host):
            return "Could not reach \(host). Check your internet connection, or update the server address in Settings."
        case .badResponse(let code):
            return "The server returned HTTP \(code)."
        case .serverMessage(let message):
            return message
        }
    }
}

private struct ServerErrorDetail: Decodable {
    let detail: String
}

/// Throws .serverMessage(detail) when the body carries a FastAPI-style
/// {"detail": "..."} payload, otherwise .badResponse(status).
private func throwForStatus(_ status: Int, data: Data) throws -> Never {
    if let detail = try? JSONDecoder().decode(ServerErrorDetail.self, from: data).detail {
        throw APIError.serverMessage(detail)
    }
    throw APIError.badResponse(status)
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
            try throwForStatus(status, data: data)
        }

        return try Self.decoder.decode(RecipesResponse.self, from: data)
    }

    /// Saves a recipe typed straight into the app — no capture pipeline.
    func createRecipe(_ draft: RecipeCreate, secret: String) async throws -> Recipe {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/recipes", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = try JSONEncoder().encode(draft)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(Recipe.self, from: data)
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
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(Recipe.self, from: data)
    }

    func deleteRecipe(id: Int, secret: String) async throws {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/recipes/\(id)", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try throwForStatus(status, data: data)
        }
    }

    /// Re-runs the server's Gemini categorization for a recipe. A real API
    /// call each time — used from a deliberate "Recategorize" action, not
    /// automatically.
    func recategorize(id: Int, secret: String) async throws -> Recipe {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/recipes/\(id)/recategorize", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(Recipe.self, from: data)
    }

    func fetchPlan() async throws -> [Int] {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/plan", relativeTo: base)
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
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(PlanResponse.self, from: data).ids
    }

    func updatePlan(ids: [Int], secret: String) async throws -> [Int] {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/plan", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = try JSONEncoder().encode(PlanResponse(ids: ids))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.unreachable(trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(PlanResponse.self, from: data).ids
    }

    private var trimmedBase: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct PlanResponse: Codable {
    let ids: [Int]
}
