import Foundation
import SQLite3

enum QuotaError: Error, CustomStringConvertible {
    case missingDatabase(String)
    case missingToken(String)
    case expiredToken
    case http(Int, String)
    case network(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .missingDatabase(let path):
            return "无法读取额度：本机找不到 Cursor 状态库（\(path)）。请确认已安装并打开过 Cursor。"
        case .missingToken:
            return "无法读取额度：本机 Cursor 没有可用登录令牌。请先在 Cursor 登录账号。"
        case .expiredToken:
            return "无法读取额度：Cursor 登录已过期。请重新登录 Cursor。"
        case .http(let code, let body):
            if code == 401 || code == 403 {
                return "无法读取额度：Cursor 会话被拒绝（HTTP \(code)）。请重新登录 Cursor 后再试。"
            }
            return "无法读取额度：官方接口返回 HTTP \(code)。\(Self.shortBody(body))"
        case .network(let message):
            return "无法读取额度：网络请求失败（\(message)）。"
        case .unreadable(let message):
            return "无法读取额度：接口已响应，但无法解析出用量字段。\(message) 未显示任何数字。"
        }
    }

    private static func shortBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return " " + String(trimmed.prefix(120))
    }
}

struct UsageSnapshot: Codable {
    var fetchedAt: String
    var source: String
    var email: String?
    var membershipType: String?
    var isUnlimited: Bool?
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var totalPercentUsed: Double?
    var autoPercentUsed: Double?
    var apiPercentUsed: Double?
    var autoDisplayMessage: String?
    var namedDisplayMessage: String?
    var onDemandEnabled: Bool?
    var onDemandUsed: Double?
    var onDemandLimit: Double?
    var planUsed: Double?
    var planLimit: Double?
    var planRemaining: Double?
}

enum UsageClient {
    static let snapshotDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CursorQuotaBar")
    static let snapshotURL = snapshotDirectory.appendingPathComponent("last-snapshot.json")

    static func fetch() throws -> UsageSnapshot {
        let token = try readAccessToken()
        let claims = decodeJWTClaims(token)
        if let exp = claims["exp"] as? Double, exp < Date().timeIntervalSince1970 + 30 {
            throw QuotaError.expiredToken
        }
        if let exp = claims["exp"] as? Int, Double(exp) < Date().timeIntervalSince1970 + 30 {
            throw QuotaError.expiredToken
        }

        let cookie = sessionCookie(token: token, claims: claims)
        let summaryData = try getJSON(url: "https://cursor.com/api/usage-summary", cookie: cookie)
        guard let summary = summaryData as? [String: Any] else {
            throw QuotaError.unreadable("usage-summary 不是 JSON 对象。")
        }

        var snapshot = UsageSnapshot(
            fetchedAt: isoNow(),
            source: "cursor.com/api/usage-summary + 本机 Cursor cursorAuth/accessToken"
        )
        snapshot.membershipType = summary["membershipType"] as? String
        snapshot.isUnlimited = summary["isUnlimited"] as? Bool
        snapshot.billingCycleStart = summary["billingCycleStart"] as? String
        snapshot.billingCycleEnd = summary["billingCycleEnd"] as? String
        snapshot.autoDisplayMessage = summary["autoModelSelectedDisplayMessage"] as? String
        snapshot.namedDisplayMessage = summary["namedModelSelectedDisplayMessage"] as? String

        if let individual = summary["individualUsage"] as? [String: Any] {
            if let plan = individual["plan"] as? [String: Any] {
                snapshot.totalPercentUsed = doubleValue(plan["totalPercentUsed"])
                snapshot.autoPercentUsed = doubleValue(plan["autoPercentUsed"])
                snapshot.apiPercentUsed = doubleValue(plan["apiPercentUsed"])
                snapshot.planUsed = doubleValue(plan["used"])
                snapshot.planLimit = doubleValue(plan["limit"])
                snapshot.planRemaining = doubleValue(plan["remaining"])
            }
            if let onDemand = individual["onDemand"] as? [String: Any] {
                snapshot.onDemandEnabled = onDemand["enabled"] as? Bool
                snapshot.onDemandUsed = doubleValue(onDemand["used"])
                snapshot.onDemandLimit = doubleValue(onDemand["limit"])
            }
        }

        let hasAnyUsage =
            snapshot.totalPercentUsed != nil
            || snapshot.autoPercentUsed != nil
            || snapshot.apiPercentUsed != nil
            || snapshot.autoDisplayMessage != nil
            || snapshot.namedDisplayMessage != nil
            || snapshot.isUnlimited == true
        if !hasAnyUsage {
            throw QuotaError.unreadable("缺少百分比、官方说明或无限额度标记。")
        }

        if let me = try? getJSON(url: "https://cursor.com/api/auth/me", cookie: cookie) as? [String: Any] {
            snapshot.email = me["email"] as? String
        }

        try persist(snapshot)
        return snapshot
    }

    static func persist(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    static func persistError(_ message: String) {
        let payload: [String: String] = [
            "fetchedAt": isoNow(),
            "error": message,
            "source": "cursor.com/api/usage-summary + 本机 Cursor cursorAuth/accessToken",
        ]
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: snapshotURL, options: .atomic)
        }
    }

    private static func readAccessToken() throws -> String {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw QuotaError.missingDatabase(dbPath)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(dbPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw QuotaError.missingDatabase(dbPath)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QuotaError.missingToken(dbPath)
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw QuotaError.missingToken(dbPath)
        }

        let bytes = sqlite3_column_blob(stmt, 0)
        let length = sqlite3_column_bytes(stmt, 0)
        if let bytes, length > 0 {
            let data = Data(bytes: bytes, count: Int(length))
            if let token = decodeToken(data) { return token }
        }
        if let cString = sqlite3_column_text(stmt, 0) {
            let token = String(cString: cString)
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        throw QuotaError.missingToken(dbPath)
    }

    private static func decodeToken(_ data: Data) -> String? {
        let candidates: [String?] = [
            String(data: data, encoding: .utf8),
            String(data: data, encoding: .utf16LittleEndian),
            String(data: data, encoding: .utf16),
        ]
        for candidate in candidates {
            guard var text = candidate else { continue }
            text = text.replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains(".") && text.count > 20 {
                return text
            }
        }
        return nil
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func sessionCookie(token: String, claims: [String: Any]) -> String {
        if let sub = claims["sub"] as? String, !sub.isEmpty {
            return "WorkosCursorSessionToken=\(sub)::\(token)"
        }
        return "WorkosCursorSessionToken=\(token)"
    }

    private static func getJSON(url: String, cookie: String) throws -> Any {
        guard let requestURL = URL(string: url) else {
            throw QuotaError.network("无效地址")
        }
        var request = URLRequest(url: requestURL, timeoutInterval: 20)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 CursorQuotaBar", forHTTPHeaderField: "User-Agent")

        let result: (Data, URLResponse)
        do {
            result = try syncRequest(request)
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        let response = result.1 as? HTTPURLResponse
        let code = response?.statusCode ?? 0
        if code == 401 || code == 403 {
            throw QuotaError.http(code, String(data: result.0, encoding: .utf8) ?? "")
        }
        if !(200...299).contains(code) {
            throw QuotaError.http(code, String(data: result.0, encoding: .utf8) ?? "")
        }
        do {
            return try JSONSerialization.jsonObject(with: result.0)
        } catch {
            throw QuotaError.unreadable("JSON 解析失败。")
        }
    }

    private static func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        var captured: Result<(Data, URLResponse), Error>?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                captured = .failure(error)
            } else if let data, let response {
                captured = .success((data, response))
            } else {
                captured = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        switch captured {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case nil:
            throw URLError(.timedOut)
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }

    static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

enum UsageFormatter {
    static func line(from snapshot: UsageSnapshot) -> String {
        var parts: [String] = ["Cursor 额度"]
        if let membership = snapshot.membershipType, !membership.isEmpty {
            parts.append(planLabel(membership))
        }
        if snapshot.isUnlimited == true {
            parts.append("不限量")
        }
        if let total = snapshot.totalPercentUsed {
            parts.append("总用量已用 \(percent(total))")
        }
        if let auto = snapshot.autoPercentUsed {
            parts.append("Auto \(percent(auto))")
        }
        if let api = snapshot.apiPercentUsed {
            parts.append("API \(percent(api))")
        }
        if snapshot.totalPercentUsed == nil, let message = snapshot.autoDisplayMessage, !message.isEmpty {
            parts.append(message)
        }
        if let end = formatDate(snapshot.billingCycleEnd) {
            parts.append("本周期至 \(end)")
        }
        if let enabled = snapshot.onDemandEnabled {
            if enabled, let used = snapshot.onDemandUsed {
                if let limit = snapshot.onDemandLimit {
                    parts.append("按量 \(cents(used))/\(cents(limit))")
                } else {
                    parts.append("按量已用 \(cents(used))")
                }
            } else if !enabled {
                parts.append("按量未开启")
            }
        }
        parts.append("\(clock(snapshot.fetchedAt)) 更新")
        return parts.joined(separator: "  ·  ")
    }

    static func statusItemTitle(from snapshot: UsageSnapshot) -> String {
        if let total = snapshot.totalPercentUsed {
            return "额度 \(percent(total))"
        }
        if snapshot.isUnlimited == true {
            return "额度 不限量"
        }
        return "额度"
    }

    static func usedRatio(from snapshot: UsageSnapshot) -> Double? {
        snapshot.totalPercentUsed.map { min(max($0 / 100.0, 0), 1) }
    }

    static func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro_plus": return "Pro+"
        case "pro": return "Pro"
        case "ultra": return "Ultra"
        case "hobby", "free": return "免费"
        case "enterprise": return "Enterprise"
        case "business": return "Business"
        default: return raw
        }
    }

    static func percent(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "—" }
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    static func cents(_ value: Double) -> String {
        String(format: "$%.2f", value / 100.0)
    }

    static func formatDate(_ iso: String?) -> String? {
        guard let iso, let date = parseISO(iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    static func clock(_ iso: String) -> String {
        let date = parseISO(iso) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func parseISO(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
