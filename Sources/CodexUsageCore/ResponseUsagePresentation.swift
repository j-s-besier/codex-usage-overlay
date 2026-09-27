import Foundation

public struct ModelEffortCapability: Sendable {
    public let displayName: String
    public let supportedEfforts: [String]
}

public enum ModelEffortRegistry {
    // Canonical model IDs and the effort levels offered by the current Codex model set.
    public static let capabilities: [String: ModelEffortCapability] = [
        "gpt-6-astra": .init(displayName: "GPT-6 Astra", supportedEfforts: ["ultra", "max", "xhigh", "high", "medium", "low"]),
        "gpt-6-sol": .init(displayName: "GPT-6 Sol", supportedEfforts: ["ultra", "max", "xhigh", "high", "medium", "low"]),
        "gpt-6-luna": .init(displayName: "GPT-6 Luna", supportedEfforts: ["max", "xhigh", "high", "medium", "low"]),
        "gpt-5.6-sol": .init(displayName: "GPT-5.6 Sol", supportedEfforts: ["ultra", "max", "xhigh", "high", "medium", "low"]),
        "gpt-5.6-terra": .init(displayName: "GPT-5.6 Terra", supportedEfforts: ["ultra", "max", "xhigh", "high", "medium", "low"]),
        "gpt-5.6-luna": .init(displayName: "GPT-5.6 Luna", supportedEfforts: ["max", "xhigh", "high", "medium", "low"]),
        "gpt-5.5": .init(displayName: "GPT-5.5", supportedEfforts: ["high", "medium", "low"])
    ]

    public static func capability(for model: String) -> ModelEffortCapability? {
        capabilities[model.lowercased()]
    }
}

public struct ResponseUsageTotals: Sendable, Equatable {
    public let input: Int64?
    public let output: Int64?
    public let total: Int64?

    public init(records: [ResponseTokenUsageRecord]) {
        func sum(_ keyPath: KeyPath<ResponseTokenUsage, Int64?>) -> Int64? {
            if records.isEmpty { return 0 }
            let values = records.compactMap { $0.usage[keyPath: keyPath] }
            guard values.count == records.count else { return nil }
            return values.reduce(0, +)
        }
        input = sum(\.inputTokens)
        output = sum(\.outputTokens)
        total = sum(\.totalTokens)
    }
}

public struct ResponseEffortSummary: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let records: [ResponseTokenUsageRecord]
    public let totals: ResponseUsageTotals

    public init(id: String, label: String, records: [ResponseTokenUsageRecord]) {
        self.id = id
        self.label = label
        self.records = records
        totals = ResponseUsageTotals(records: records)
    }
}

public struct ResponseModelSummary: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilityListAvailable: Bool
    public let records: [ResponseTokenUsageRecord]
    public let efforts: [ResponseEffortSummary]
    public let totals: ResponseUsageTotals
    let latestDate: Date

    public init(id: String, displayName: String, capabilityListAvailable: Bool,
                records: [ResponseTokenUsageRecord], efforts: [ResponseEffortSummary]) {
        self.id = id
        self.displayName = displayName
        self.capabilityListAvailable = capabilityListAvailable
        self.records = records
        self.efforts = efforts
        totals = ResponseUsageTotals(records: records)
        latestDate = records.compactMap(\.occurredAt).max() ?? .distantPast
    }
}

public struct ResponseThreadSummary: Identifiable, Sendable {
    public let id: String
    public let records: [ResponseTokenUsageRecord]
    public let totals: ResponseUsageTotals
    let latestDate: Date

    public init(id: String, records: [ResponseTokenUsageRecord]) {
        self.id = id
        self.records = records
        totals = ResponseUsageTotals(records: records)
        latestDate = records.compactMap(\.occurredAt).max() ?? .distantPast
    }
}

public struct ResponseSessionSummary: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let records: [ResponseTokenUsageRecord]
    public let threads: [ResponseThreadSummary]
    public let totals: ResponseUsageTotals
    let latestDate: Date

    public init(id: String, displayName: String, records: [ResponseTokenUsageRecord], threads: [ResponseThreadSummary]) {
        self.id = id
        self.displayName = displayName
        self.records = records
        self.threads = threads
        totals = ResponseUsageTotals(records: records)
        latestDate = records.compactMap(\.occurredAt).max() ?? .distantPast
    }
}

public enum ResponseUsagePresentation {
    private static let effortOrder = ["ultra", "max", "xhigh", "high", "medium", "low", "minimal"]

    private struct DatedRecord {
        let record: ResponseTokenUsageRecord
        let date: Date
    }

    public static func responses(_ records: [ResponseTokenUsageRecord], on day: Date, calendar: Calendar = .current) -> [ResponseTokenUsageRecord] {
        records.filter { $0.occurredAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast) }
    }

    public static func models(_ records: [ResponseTokenUsageRecord]) -> [ResponseModelSummary] {
        Dictionary(grouping: records, by: \.model).map { model, items in
            let capability = ModelEffortRegistry.capability(for: model)
            let observed = Dictionary(grouping: items) { record -> String in
                let effort = record.effort.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let canonical = effort == "extra high" ? "xhigh" : effort
                return effortOrder.contains(canonical) ? canonical : "unknown"
            }
            let names = Set(capability?.supportedEfforts ?? []).union(observed.keys)
            let efforts = names.sorted { left, right in
                let leftRank = effortOrder.firstIndex(of: left) ?? Int.max
                let rightRank = effortOrder.firstIndex(of: right) ?? Int.max
                return leftRank == rightRank ? left < right : leftRank < rightRank
            }.map { name in
                ResponseEffortSummary(id: name, label: name == "unknown" ? "Unknown" : name == "xhigh" ? "Extra high" : name.capitalized, records: observed[name] ?? [])
            }
            return ResponseModelSummary(id: model, displayName: capability?.displayName ?? model,
                capabilityListAvailable: capability != nil, records: items, efforts: efforts)
        }.sorted { $0.latestDate == $1.latestDate ? $0.id < $1.id : $0.latestDate > $1.latestDate }
    }

    public static func sessions(_ records: [ResponseTokenUsageRecord], names: [String: String] = [:]) -> [ResponseSessionSummary] {
        let sessionsByID = Dictionary(grouping: records) { record in
            record.sessionId ?? "Unknown session"
        }
        var summaries: [ResponseSessionSummary] = []
        summaries.reserveCapacity(sessionsByID.count)

        for (sessionID, items) in sessionsByID {
            let threadsByID = Dictionary(grouping: items) { record in
                record.threadId ?? "Unknown thread"
            }
            var threads: [ResponseThreadSummary] = []
            threads.reserveCapacity(threadsByID.count)
            for (threadID, threadItems) in threadsByID {
                threads.append(ResponseThreadSummary(id: threadID, records: sorted(threadItems)))
            }
            threads.sort {
                $0.latestDate == $1.latestDate ? $0.id < $1.id : $0.latestDate > $1.latestDate
            }
            let name = names[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = ResponseSessionSummary(
                id: sessionID,
                displayName: name?.isEmpty == false ? name! : sessionID,
                records: sorted(items),
                threads: threads
            )
            summaries.append(summary)
        }
        summaries.sort {
            $0.latestDate == $1.latestDate ? $0.id < $1.id : $0.latestDate > $1.latestDate
        }
        return summaries
    }

    private static func sorted(_ records: [ResponseTokenUsageRecord]) -> [ResponseTokenUsageRecord] {
        var datedRecords: [DatedRecord] = records.map { record in
            DatedRecord(record: record, date: record.occurredAt ?? .distantPast)
        }
        datedRecords.sort {
            $0.date == $1.date ? $0.record.responseId < $1.record.responseId : $0.date > $1.date
        }
        return datedRecords.map(\.record)
    }
}

public enum SessionIndexNames {
    private struct Entry: Decodable {
        let id: String?
        let threadName: String?
    }

    public static func read(codexHomeURL: URL? = nil) -> [String: String] {
        let home = codexHomeURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex").path, isDirectory: true)
        guard let data = try? Data(contentsOf: home.appendingPathComponent("session_index.jsonl")) else { return [:] }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [String: String] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let id = entry.id, !id.isEmpty,
                  let name = entry.threadName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}
