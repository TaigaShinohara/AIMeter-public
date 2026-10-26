import Foundation

// MARK: - Pure Parsers & Calculations (Testable)
public enum UsageParser {
    public static func startOfMonthUnixTimestamp(for date: Date = Date()) -> Int {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = utcCalendar.dateComponents([.year, .month], from: date)
        let startOfMonth = utcCalendar.date(from: components) ?? date
        return Int(startOfMonth.timeIntervalSince1970)
    }

    public static func startTimestamp(for period: LimitPeriod, now: Date = Date()) -> Int {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        switch period {
        case .twoHours:
            return Int(now.addingTimeInterval(-2 * 3600).timeIntervalSince1970)
        case .fiveHours:
            return Int(now.addingTimeInterval(-5 * 3600).timeIntervalSince1970)
        case .daily:
            let startOfDay = utcCalendar.startOfDay(for: now)
            return Int(startOfDay.timeIntervalSince1970)
        case .weekly:
            let sevenDaysAgo = utcCalendar.date(byAdding: .day, value: -6, to: utcCalendar.startOfDay(for: now)) ?? now.addingTimeInterval(-7 * 86400)
            return Int(sevenDaysAgo.timeIntervalSince1970)
        case .monthly:
            return startOfMonthUnixTimestamp(for: now)
        }
    }

    public struct BucketTokenRecord: Equatable {
        public let startTime: Int
        public let endTime: Int
        public let tokens: Int

        public init(startTime: Int, endTime: Int, tokens: Int) {
            self.startTime = startTime
            self.endTime = endTime
            self.tokens = tokens
        }
    }

    public static func parseOpenAIUsagePageWithBuckets(data: Data) throws -> (buckets: [BucketTokenRecord], totalTokens: Int, nextPage: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var totalTokens = 0
        var records: [BucketTokenRecord] = []
        if let buckets = json["data"] as? [[String: Any]] {
            for bucket in buckets {
                let bStart = try parseIntValue(bucket["start_time"])
                let bEnd = try parseIntValue(bucket["end_time"])
                var bucketTokens = 0
                if let results = bucket["results"] as? [[String: Any]] {
                    for res in results {
                        let input = try parseIntValue(res["input_tokens"])
                        let output = try parseIntValue(res["output_tokens"])
                        bucketTokens = try UsageNumber.sum([bucketTokens, input, output])
                    }
                }
                totalTokens = try UsageNumber.add(totalTokens, bucketTokens)
                records.append(BucketTokenRecord(startTime: bStart, endTime: bEnd, tokens: bucketTokens))
            }
        }
        let hasMore = (json["has_more"] as? Bool) ?? true
        let nextPage = hasMore ? (json["next_page"] as? String) : nil
        return (records, totalTokens, (nextPage?.isEmpty == false) ? nextPage : nil)
    }

    public static func parseOpenAIUsagePage(data: Data) throws -> (tokens: Int, nextPage: String?) {
        let parsed = try parseOpenAIUsagePageWithBuckets(data: data)
        return (parsed.totalTokens, parsed.nextPage)
    }

    public static func parseOpenAICostsPage(data: Data) throws -> (costUSD: Double, nextPage: String?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        var totalCost = 0.0
        if let buckets = json["data"] as? [[String: Any]] {
            for bucket in buckets {
                if let results = bucket["results"] as? [[String: Any]] {
                    for res in results {
                        if let amountObj = res["amount"] as? [String: Any] {
                            totalCost = try UsageNumber.add(totalCost, parseDoubleValue(amountObj["value"]))
                        }
                    }
                }
            }
        }
        let hasMore = (json["has_more"] as? Bool) ?? true
        let nextPage = hasMore ? (json["next_page"] as? String) : nil
        return (totalCost, (nextPage?.isEmpty == false) ? nextPage : nil)
    }

    public static func parseGeminiMonitoringSeries(data: Data) throws -> Int {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        guard let series = json["timeSeries"] as? [[String: Any]] else {
            return 0
        }
        var total = 0
        for item in series {
            if let points = item["points"] as? [[String: Any]] {
                for pt in points {
                    if let valObj = pt["value"] as? [String: Any] {
                        total = try UsageNumber.add(total, parseIntValue(valObj["int64Value"] ?? valObj["doubleValue"]))
                    }
                }
            }
        }
        return total
    }

    public static func parseIntValue(_ anyVal: Any?) throws -> Int {
        try UsageNumber.count(anyVal)
    }

    public static func parseDoubleValue(_ anyVal: Any?) throws -> Double {
        try UsageNumber.nonnegative(anyVal)
    }

    /// Also used after pagination: individually valid pages can exceed the total budget.
    public static func totalTokens(in buckets: [BucketTokenRecord], since start: Int = 0) throws -> Int {
        try buckets.reduce(0) { total, bucket in
            _ = try UsageNumber.checked(bucket.tokens)
            return bucket.startTime >= start ? try UsageNumber.add(total, bucket.tokens) : total
        }
    }

    public static func isValidGCPProjectID(_ projectId: String) -> Bool {
        let pattern = #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+:)?[a-z][a-z0-9-]{4,28}[a-z0-9]$"#
        guard let match = projectId.range(of: pattern, options: .regularExpression) else { return false }
        return match == projectId.startIndex..<projectId.endIndex
    }

    /// Monitoring accepts either a project ID or its numeric project number.
    public static func isValidGCPProjectReference(_ project: String) -> Bool {
        if isValidGCPProjectID(project) { return true }
        return !project.isEmpty && project.allSatisfy { $0 >= "0" && $0 <= "9" }
            && UInt64(project).map { $0 > 0 } == true
    }

    public static func isTrustedExecutable(atPath path: String, currentUID: uid_t = geteuid()) -> Bool {
        var candidateInfo = Darwin.stat()
        guard Darwin.lstat(path, &candidateInfo) == 0 else { return false }
        guard candidateInfo.st_uid == 0 || candidateInfo.st_uid == currentUID else { return false }

        let candidateParent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var candidateParentInfo = Darwin.stat()
        guard Darwin.lstat(candidateParent, &candidateParentInfo) == 0 else { return false }
        guard (candidateParentInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard (candidateParentInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
        guard candidateParentInfo.st_uid == 0 || candidateParentInfo.st_uid == currentUID else { return false }

        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path
        var fileInfo = Darwin.stat()
        guard Darwin.lstat(resolvedPath, &fileInfo) == 0 else { return false }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else { return false }
        guard (fileInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
        guard fileInfo.st_uid == 0 || fileInfo.st_uid == currentUID else { return false }
        guard (fileInfo.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0 else { return false }

        let parentPath = resolvedURL.deletingLastPathComponent().path
        var dirInfo = Darwin.stat()
        guard Darwin.lstat(parentPath, &dirInfo) == 0 else { return false }
        guard (dirInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        guard (dirInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return false }
        guard dirInfo.st_uid == 0 || dirInfo.st_uid == currentUID else { return false }

        return FileManager.default.isExecutableFile(atPath: resolvedPath)
    }
}
