import Foundation

enum APIError: LocalizedError {
    case badURL
    case unreachable(String)
    case timedOut
    case badResponse(Int)
    /// A FastAPI HTTPException's `detail` — usually a real, actionable
    /// message (e.g. "Gemini's free daily quota is used up...") rather than
    /// just a status code.
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return L("The server address is not a valid URL.")
        case .unreachable(let host):
            return L("Could not reach \(host). Check your internet connection, or update the server address in Settings.")
        case .timedOut:
            return L("That took too long. Check your connection and try again.")
        case .badResponse(let code):
            return L("The server returned HTTP \(code).")
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

private func throwForTransport(_ error: Error, host: String) throws -> Never {
    if (error as? URLError)?.code == .timedOut {
        throw APIError.timedOut
    }
    throw APIError.unreachable(host)
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

    /// Photo extract and /ingest wait on Gemini with no bytes until the
    /// function finishes (up to Vercel's 60s). The default session's 15s
    /// between-packets timer otherwise fails those as "could not reach".
    private static let longSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 75
        config.timeoutIntervalForResource = 75
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    func fetchRecipes() async throws -> RecipesResponse {
        try await decodeJSON(RecipesResponse.self, from: get("/api/recipes"))
    }

    /// Reads a recipe out of a photo (card, cookbook page, screenshot — a
    /// real Gemini vision call). Nothing is saved server-side; the result
    /// pre-fills the Add Recipe form for review.
    func extractPhoto(imageData: Data, secret: String) async throws -> RecipeExtraction {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/extract-photo", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.longSession.data(for: request)
        } catch {
            try throwForTransport(error, host: trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(RecipeExtraction.self, from: data)
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

    /// Posts a link to the same `/ingest` endpoint the Save Recipe Shortcut
    /// uses. On the hosted (Vercel) backend this runs the whole fetch →
    /// Gemini → save pipeline in-request and can take close to 60s, so the
    /// timeout here is set well past that rather than the usual 15s.
    func ingest(url: String, secret: String) async throws -> IngestResult {
        guard let base = URL(string: trimmedBase),
              let endpoint = URL(string: "/ingest", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: endpoint.absoluteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = Data(url.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.longSession.data(for: request)
        } catch {
            try throwForTransport(error, host: trimmedBase)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try throwForStatus(status, data: data)
        }
        return try Self.decoder.decode(IngestResult.self, from: data)
    }

    func fetchPantry() async throws -> [String] {
        try await decodeJSON(PantryResponse.self, from: get("/api/pantry")).items
    }

    func updatePantry(items: [String], secret: String) async throws -> [String] {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/pantry", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = try JSONEncoder().encode(PantryResponse(items: items))

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
        return try Self.decoder.decode(PantryResponse.self, from: data).items
    }

    func fetchPantryInventory() async throws -> [PantryItem] {
        try await decodeJSON(PantryInventoryResponse.self, from: get("/api/pantry-inventory")).items
    }

    func updatePantryInventory(items: [PantryItem], secret: String) async throws -> [PantryItem] {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/pantry-inventory", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = try JSONEncoder().encode(PantryInventoryResponse(items: items))

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
        return try Self.decoder.decode(PantryInventoryResponse.self, from: data).items
    }

    func fetchToBuy() async throws -> [ToBuyItem] {
        try await decodeJSON(ToBuyResponse.self, from: get("/api/to-buy")).items
    }

    func updateToBuy(items: [ToBuyItem], secret: String) async throws -> [ToBuyItem] {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/to-buy", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty {
            request.setValue(trimmedSecret, forHTTPHeaderField: "X-Recipe-Box-Key")
        }
        request.httpBody = try JSONEncoder().encode(ToBuyResponse(items: items))

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
        return try Self.decoder.decode(ToBuyResponse.self, from: data).items
    }

    /// Backs the Settings screen's "API usage" card.
    func fetchUsage(secret: String) async throws -> UsageStats {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: "/api/usage", relativeTo: base)
        else { throw APIError.badURL }

        var request = URLRequest(url: url.absoluteURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
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
        return try Self.decoder.decode(UsageStats.self, from: data)
    }

    private var trimmedBase: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func get(_ path: String) async throws -> Data {
        guard let base = URL(string: trimmedBase),
              let url = URL(string: path, relativeTo: base)
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
        return data
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }
}

struct PantryResponse: Codable {
    let items: [String]
}
