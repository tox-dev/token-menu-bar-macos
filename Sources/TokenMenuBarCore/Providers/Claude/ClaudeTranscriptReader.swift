import Foundation

public struct ModelPrice: Sendable, Equatable {
  public let input: Double
  public let output: Double
  public let cacheWrite: Double
  public let cacheRead: Double

  public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
  }
}

public enum ClaudePricing {
  public static let perMillion: [String: ModelPrice] = [
    "opus": ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
    "sonnet": ModelPrice(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
    "haiku": ModelPrice(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1),
    "fable": ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
    "mythos": ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
  ]

  public static func price(for model: String) -> ModelPrice? {
    let lowered = model.lowercased()
    return perMillion.first { lowered.contains($0.key) }?.value
  }

  public static func cost(_ usage: TokenUsage, model: String) -> Double {
    guard let price = price(for: model) else { return 0 }
    return
      (Double(usage.input) * price.input + Double(usage.output) * price.output + Double(usage.cacheWrite)
      * price.cacheWrite
      + Double(usage.cacheRead) * price.cacheRead) / 1_000_000
  }
}

public struct TokenUsage: Sendable, Equatable, Hashable {
  public var input: Int
  public var output: Int
  public var cacheWrite: Int
  public var cacheRead: Int

  public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
  }

  public var total: Int {
    input + output + cacheWrite + cacheRead
  }

  public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
    lhs.input += rhs.input
    lhs.output += rhs.output
    lhs.cacheWrite += rhs.cacheWrite
    lhs.cacheRead += rhs.cacheRead
  }
}

public struct TranscriptMessage: Sendable, Equatable, Hashable {
  public let id: String
  public let timestamp: Date
  public let session: String
  public let model: String
  public let usage: TokenUsage
  public let toolCalls: Int

  public init(id: String, timestamp: Date, session: String, model: String, usage: TokenUsage, toolCalls: Int) {
    self.id = id
    self.timestamp = timestamp
    self.session = session
    self.model = model
    self.usage = usage
    self.toolCalls = toolCalls
  }

  public var cost: Double {
    ClaudePricing.cost(usage, model: model)
  }
}

public struct LocalUsage: Sendable, Equatable, Hashable, Codable {
  public let windowTokens: Int
  public let windowCost: Double
  public let costPerHour: Double
  public let todayTokens: Int
  public let todayCost: Double
  public let todayMessages: Int

  public init(
    windowTokens: Int, windowCost: Double, costPerHour: Double, todayTokens: Int, todayCost: Double, todayMessages: Int
  ) {
    self.windowTokens = windowTokens
    self.windowCost = windowCost
    self.costPerHour = costPerHour
    self.todayTokens = todayTokens
    self.todayCost = todayCost
    self.todayMessages = todayMessages
  }
}

public actor ClaudeTranscriptReader {
  public static let retentionDays = 60

  private let root: URL
  private var offsets: [String: Int] = [:]
  private var seen: Set<String> = []
  private var messages: [TranscriptMessage] = []

  public init(root: URL) {
    self.root = root
  }

  public func refresh(now: Date) -> [TranscriptMessage] {
    let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86400)
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
    let urls = (enumerator?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    for url in urls {
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      let size = values?.fileSize ?? 0
      let modified = values?.contentModificationDate ?? .distantPast
      let key = url.path
      let offset = offsets[key] ?? 0
      guard size > offset, modified >= cutoff, let handle = try? FileHandle(forReadingFrom: url) else { continue }
      defer { try? handle.close() }
      try? handle.seek(toOffset: UInt64(offset))
      let data = (try? handle.readToEnd()) ?? Data()
      let newline = UInt8(ascii: "\n")
      let complete = data.lastIndex(of: newline).map { data.prefix(through: $0) } ?? Data()
      offsets[key] = offset + complete.count
      for line in complete.split(separator: newline) where line.contains(Array("\"usage\"".utf8)) {
        guard let message = Self.parse(line: line), message.timestamp >= cutoff, seen.insert(message.id).inserted else {
          continue
        }
        messages.append(message)
      }
    }
    messages.removeAll { $0.timestamp < cutoff }
    return messages
  }

  static func parse(line: Data) -> TranscriptMessage? {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: line), json["type"]?.stringValue == "assistant",
      let message = json["message"], let usage = message["usage"], let model = message["model"]?.stringValue,
      let timestamp = ISODate.parse(json["timestamp"]?.stringValue)
    else { return nil }
    let id = message["id"]?.stringValue ?? json["uuid"]?.stringValue ?? ""
    let requestID = json["requestId"]?.stringValue ?? ""
    let toolCalls = message["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "tool_use" }.count ?? 0
    return TranscriptMessage(
      id: "\(id):\(requestID)",
      timestamp: timestamp,
      session: json["sessionId"]?.stringValue ?? "",
      model: model,
      usage: TokenUsage(
        input: Int(usage["input_tokens"]?.doubleValue ?? 0),
        output: Int(usage["output_tokens"]?.doubleValue ?? 0),
        cacheWrite: Int(usage["cache_creation_input_tokens"]?.doubleValue ?? 0),
        cacheRead: Int(usage["cache_read_input_tokens"]?.doubleValue ?? 0)
      ),
      toolCalls: toolCalls
    )
  }

  public static func analytics(_ messages: [TranscriptMessage], now: Date) -> ProviderAnalytics? {
    guard !messages.isEmpty else { return nil }
    var byDayModel: [String: [String: TokenUsage]] = [:]
    var daily: [String: (messages: Int, sessions: Set<String>, toolCalls: Int, cost: Double)] = [:]
    for message in messages {
      let day = DayStamp.string(message.timestamp)
      byDayModel[day, default: [:]][message.model, default: TokenUsage()] += message.usage
      var entry = daily[day] ?? (0, [], 0, 0)
      entry.messages += 1
      entry.sessions.insert(message.session)
      entry.toolCalls += message.toolCalls
      entry.cost += message.cost
      daily[day] = entry
    }
    var points: [AnalyticsPoint] = []
    for (day, models) in byDayModel {
      for (model, usage) in models {
        points.append(AnalyticsPoint(day: day, metric: .inputTokens, series: model, value: Double(usage.input)))
        points.append(AnalyticsPoint(day: day, metric: .outputTokens, series: model, value: Double(usage.output)))
        points.append(
          AnalyticsPoint(day: day, metric: .cachedInputTokens, series: model, value: Double(usage.cacheRead)))
        points.append(
          AnalyticsPoint(day: day, metric: .cacheWriteTokens, series: model, value: Double(usage.cacheWrite)))
        points.append(
          AnalyticsPoint(day: day, metric: .costUSD, series: model, value: ClaudePricing.cost(usage, model: model)))
      }
    }
    for (day, entry) in daily {
      points.append(AnalyticsPoint(day: day, metric: .messages, series: "messages", value: Double(entry.messages)))
      points.append(
        AnalyticsPoint(day: day, metric: .sessions, series: "sessions", value: Double(entry.sessions.count)))
      points.append(AnalyticsPoint(day: day, metric: .toolCalls, series: "tool calls", value: Double(entry.toolCalls)))
    }
    return ProviderAnalytics(
      provider: .claude,
      points: points.sorted { ($0.day, $0.metric.rawValue, $0.series) < ($1.day, $1.metric.rawValue, $1.series) },
      fetchedAt: now)
  }

  public static func localUsage(
    _ messages: [TranscriptMessage], windowResetsAt: Date?, windowDuration: TimeInterval, now: Date,
    calendar: Calendar = .current
  ) -> LocalUsage? {
    guard !messages.isEmpty else { return nil }
    let windowStart = (windowResetsAt ?? now).addingTimeInterval(-windowDuration)
    let inWindow = messages.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
    let windowTokens = inWindow.reduce(0) { $0 + $1.usage.total }
    let windowCost = inWindow.reduce(0) { $0 + $1.cost }
    let elapsedHours = max(now.timeIntervalSince(inWindow.map(\.timestamp).min() ?? now) / 3600, 1.0 / 60)
    let todayStart = calendar.startOfDay(for: now)
    let today = messages.filter { $0.timestamp >= todayStart }
    return LocalUsage(
      windowTokens: windowTokens,
      windowCost: windowCost,
      costPerHour: inWindow.isEmpty ? 0 : windowCost / elapsedHours,
      todayTokens: today.reduce(0) { $0 + $1.usage.total },
      todayCost: today.reduce(0) { $0 + $1.cost },
      todayMessages: today.count
    )
  }
}
