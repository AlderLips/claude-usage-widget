import Foundation

struct UsageWindow {
    var percent: Double
    var resetsAt: Date?

    /// The window as it stands at `now`: once the reset time passes, usage is back to zero.
    func current(at now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageWindow(percent: 0, resetsAt: nil)
    }

    enum Pace {
        case runsOut(Date)
        case onTrack(projectedPercent: Double)
    }

    /// Straight-line projection of the current burn rate to the end of the window.
    func pace(now: Date, length: TimeInterval) -> Pace? {
        guard let resetsAt, percent > 0, percent < 100 else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        // Too early in the window for the projection to mean anything.
        guard elapsed > length * 0.05 else { return nil }
        let projected = percent * length / elapsed
        if projected < 100 { return .onTrack(projectedPercent: projected) }
        return .runsOut(start.addingTimeInterval(elapsed * 100 / percent))
    }
}

struct UsageSnapshot {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var plan: String?
    var fetchedAt: Date
}

enum UsageError: LocalizedError {
    case notSignedIn
    case loginExpired
    case rateLimited(retryAfter: TimeInterval)
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to Claude Code first"
        case .loginExpired: "Login expired — open Claude Code"
        case .rateLimited: "Rate limited — retrying later"
        case .server(let status): "Couldn't load usage (HTTP \(status))"
        }
    }
}

/// Reads Claude Code's login from the Keychain and asks the same endpoint its `/usage` command uses.
enum UsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    static func fetch() async throws -> UsageSnapshot {
        let login = try readLogin()
        if let expiresAt = login.expiresAt, expiresAt <= Date() { throw UsageError.loginExpired }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: break
        case 401: throw UsageError.loginExpired
        case 429:
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 600
            throw UsageError.rateLimited(retryAfter: retryAfter)
        case let status: throw UsageError.server(status: status)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(UsageResponse.self, from: data)
        return UsageSnapshot(
            session: body.fiveHour?.window,
            weekly: body.sevenDay?.window,
            plan: login.plan,
            fetchedAt: Date()
        )
    }

    private struct Login {
        var accessToken: String
        var expiresAt: Date?
        var plan: String?
    }

    private static func readLogin() throws -> Login {
        // Going through /usr/bin/security, which Claude Code's Keychain item already trusts, avoids an access prompt.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data),
              let oauth = stored.claudeAiOauth
        else { throw UsageError.notSignedIn }

        return Login(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            plan: planName(subscription: oauth.subscriptionType, tier: oauth.rateLimitTier)
        )
    }

    /// "max" + "default_claude_max_5x" → "Max 5x"; "pro" → "Pro".
    private static func planName(subscription: String?, tier: String?) -> String? {
        if let tier, let match = tier.firstMatch(of: #/max_(\d+)x/#) { return "Max \(match.1)x" }
        return subscription?.capitalized
    }
}

private struct StoredCredentials: Decodable {
    struct OAuth: Decodable {
        var accessToken: String
        var expiresAt: Double?
        var subscriptionType: String?
        var rateLimitTier: String?
    }

    var claudeAiOauth: OAuth?
}

private struct UsageResponse: Decodable {
    struct Window: Decodable {
        var utilization: Double?
        var resetsAt: String?

        var window: UsageWindow {
            UsageWindow(percent: utilization ?? 0, resetsAt: resetsAt.flatMap(parseTimestamp))
        }
    }

    var fiveHour: Window?
    var sevenDay: Window?
}

/// The API sends microseconds ("…:00.838267+00:00"), which ISO8601DateFormatter won't parse.
private func parseTimestamp(_ string: String) -> Date? {
    let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var problem: String?
    @Published var isRefreshing = false

    private var lastAttempt = Date.distantPast
    private var notBefore = Date.distantPast
    private var timer: Timer?

    func start(every interval: TimeInterval = 300) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Skips the call if one just happened or the API asked us to back off.
    func refresh() {
        let now = Date()
        guard !isRefreshing, now >= notBefore, now.timeIntervalSince(lastAttempt) >= 20 else { return }
        lastAttempt = now
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            do {
                snapshot = try await UsageClient.fetch()
                problem = nil
            } catch let error as UsageError {
                if case .rateLimited(let retryAfter) = error { notBefore = Date().addingTimeInterval(retryAfter) }
                problem = error.localizedDescription
            } catch is URLError {
                problem = "Offline — showing last update"
            } catch {
                problem = "Unexpected response from Claude"
            }
        }
    }
}
