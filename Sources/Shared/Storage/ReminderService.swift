import EventKit
import Foundation
import OSLog

public enum ReminderServiceError: LocalizedError, Sendable {
    case permissionDenied
    case noReminderListAvailable
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "未获得系统「提醒事项」访问权限，请在系统设置 → 隐私与安全性 → 提醒事项中允许访问。"
        case .noReminderListAvailable:
            return "系统中没有可写入的「提醒事项」列表。"
        case let .saveFailed(reason):
            return "保存到「提醒事项」失败：\(reason)"
        }
    }
}

public struct ReminderSchedule: Equatable, Sendable {
    public let dueDateComponents: DateComponents
    public let dueDate: Date
    public let alarmDate: Date
    public let isExplicitEmailDate: Bool
    public let scheduleLabel: String

    public init(
        dueDateComponents: DateComponents,
        dueDate: Date,
        alarmDate: Date,
        isExplicitEmailDate: Bool,
        scheduleLabel: String
    ) {
        self.dueDateComponents = dueDateComponents
        self.dueDate = dueDate
        self.alarmDate = alarmDate
        self.isExplicitEmailDate = isExplicitEmailDate
        self.scheduleLabel = scheduleLabel
    }
}

/// Pure date-math calculator for mapping email task deadlines into Gregorian `EKReminder` schedules.
public enum ReminderScheduleCalculator {
    private static let isoDateRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})"#,
        options: []
    )

    private static let chineseMonthDayRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#,
        options: []
    )

    private static let yearRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(20\d{2})"#,
        options: []
    )

    public static func calculate(
        dueDateISO: String?,
        deadlineText: String?,
        emailDateString: String? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> ReminderSchedule {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone

        if let (year, month, day) = resolveExplicitYMD(
            dueDateISO: dueDateISO,
            deadlineText: deadlineText,
            emailDateString: emailDateString,
            gregorian: gregorian,
            now: now
        ) {
            let dueComponents = DateComponents(
                calendar: gregorian,
                timeZone: timeZone,
                year: year,
                month: month,
                day: day,
                hour: 9,
                minute: 0,
                second: 0
            )
            let dueDate = gregorian.date(from: dueComponents) ?? now
            let oneDayEarlier = gregorian.date(byAdding: .day, value: -1, to: dueDate) ?? dueDate
            let alarmDate: Date
            if oneDayEarlier > now {
                alarmDate = oneDayEarlier
            } else if dueDate > now {
                alarmDate = dueDate
            } else {
                alarmDate = now.addingTimeInterval(300)
            }
            let label = String(format: "截止 %02d/%02d · 提前1天提醒", month, day)
            return ReminderSchedule(
                dueDateComponents: dueComponents,
                dueDate: dueDate,
                alarmDate: alarmDate,
                isExplicitEmailDate: true,
                scheduleLabel: label
            )
        }

        // Default when email does not mention a specific task date: +7 days at 09:00.
        let plus7 = gregorian.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86_400)
        let ymd = gregorian.dateComponents([.year, .month, .day], from: plus7)
        let year = ymd.year ?? gregorian.component(.year, from: now)
        let month = ymd.month ?? gregorian.component(.month, from: now)
        let day = ymd.day ?? gregorian.component(.day, from: now)

        let dueComponents = DateComponents(
            calendar: gregorian,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: 9,
            minute: 0,
            second: 0
        )
        let dueDate = gregorian.date(from: dueComponents) ?? plus7
        let label = String(format: "默认1周后 (%02d/%02d)", month, day)
        return ReminderSchedule(
            dueDateComponents: dueComponents,
            dueDate: dueDate,
            alarmDate: dueDate,
            isExplicitEmailDate: false,
            scheduleLabel: label
        )
    }

    // MARK: - Private Parsing Helpers

    private static func resolveExplicitYMD(
        dueDateISO: String?,
        deadlineText: String?,
        emailDateString: String?,
        gregorian: Calendar,
        now: Date
    ) -> (Int, Int, Int)? {
        if let iso = dueDateISO?.trimmingCharacters(in: .whitespacesAndNewlines), !iso.isEmpty,
           let match = parseYMD(from: iso, gregorian: gregorian)
        {
            return match
        }

        guard let dl = deadlineText?.trimmingCharacters(in: .whitespacesAndNewlines), !dl.isEmpty else {
            return nil
        }

        if let match = parseYMD(from: dl, gregorian: gregorian) {
            return match
        }

        if let regex = chineseMonthDayRegex,
           let match = regex.firstMatch(in: dl, options: [], range: NSRange(location: 0, length: (dl as NSString).length))
        {
            let ns = dl as NSString
            if let month = Int(ns.substring(with: match.range(at: 1))),
               let day = Int(ns.substring(with: match.range(at: 2)))
            {
                let inferredYear = inferYear(from: emailDateString) ?? gregorian.component(.year, from: now)
                if isValidGregorianDate(year: inferredYear, month: month, day: day, gregorian: gregorian) {
                    return (inferredYear, month, day)
                }
            }
        }

        return nil
    }

    private static func parseYMD(from text: String, gregorian: Calendar) -> (Int, Int, Int)? {
        guard let regex = isoDateRegex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        guard let year = Int(ns.substring(with: match.range(at: 1))),
              let month = Int(ns.substring(with: match.range(at: 2))),
              let day = Int(ns.substring(with: match.range(at: 3))),
              isValidGregorianDate(year: year, month: month, day: day, gregorian: gregorian)
        else {
            return nil
        }
        return (year, month, day)
    }

    private static func inferYear(from emailDateString: String?) -> Int? {
        guard let emailDateString, !emailDateString.isEmpty, let regex = yearRegex else { return nil }
        let ns = emailDateString as NSString
        guard let match = regex.firstMatch(in: emailDateString, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private static func isValidGregorianDate(year: Int, month: Int, day: Int, gregorian: Calendar) -> Bool {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return false
        }
        var comps = DateComponents()
        comps.calendar = gregorian
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = gregorian.date(from: comps) else { return false }
        let check = gregorian.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day
    }
}

@MainActor
public final class ReminderService {
    public static let shared = ReminderService()
    public static let reminderListTitle = "Moxa 邮件待办"
    private static let addedKeysDefaultsKey = "com.bao3.AppleMailAI.addedReminderKeys"
    private static let maxStoredAddedKeys = 500

    private let eventStore = EKEventStore()

    private init() {}

    public func isAdded(_ todo: EmailTodoItem, messageID: String) -> Bool {
        let key = todo.reminderStorageKey(messageID: messageID)
        return storedKeysList().contains(key)
    }

    public func loadAddedKeys() -> Set<String> {
        Set(storedKeysList())
    }

    public func markAdded(_ todo: EmailTodoItem, messageID: String) {
        let key = todo.reminderStorageKey(messageID: messageID)
        var list = storedKeysList()
        list.removeAll { $0 == key }
        list.append(key)
        if list.count > Self.maxStoredAddedKeys {
            list.removeFirst(list.count - Self.maxStoredAddedKeys)
        }
        UserDefaults.standard.set(list, forKey: Self.addedKeysDefaultsKey)
    }

    public static func mailMessageURL(forMessageID rawMessageID: String) -> URL? {
        let normalized = ParsedEmailContext.normalizeMessageID(rawMessageID)
        guard !normalized.isEmpty, !normalized.hasPrefix("sha256:") else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@+"))
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "message://%3C\(encoded)%3E")
    }

    public func addReminder(
        for todo: EmailTodoItem,
        email: ParsedEmailContext,
        analysis: EmailAIAnalysis
    ) async throws -> ReminderSchedule {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            ExtensionLogger.reminders.warning("Reminders access denied by user")
            throw ReminderServiceError.permissionDenied
        }

        let targetCalendar = resolveTargetReminderList()
        guard let targetCalendar else {
            throw ReminderServiceError.noReminderListAvailable
        }

        let schedule = ReminderScheduleCalculator.calculate(
            dueDateISO: todo.dueDateISO,
            deadlineText: todo.deadline,
            emailDateString: email.dateString
        )

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = targetCalendar

        if let project = analysis.businessElements.projects.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !project.isEmpty,
           project.count <= 24,
           !todo.task.contains(project)
        {
            reminder.title = "[\(project)] \(todo.task)"
        } else {
            reminder.title = todo.task
        }

        switch todo.normalizedPriority {
        case "high":
            reminder.priority = Int(EKReminderPriority.high.rawValue)
        case "low":
            reminder.priority = Int(EKReminderPriority.low.rawValue)
        default:
            reminder.priority = Int(EKReminderPriority.medium.rawValue)
        }

        reminder.dueDateComponents = schedule.dueDateComponents
        reminder.addAlarm(EKAlarm(absoluteDate: schedule.alarmDate))

        let messageURL = Self.mailMessageURL(forMessageID: email.messageID)
        reminder.url = messageURL

        var noteLines: [String] = []
        if !email.subject.isEmpty {
            noteLines.append("邮件主题：\(email.subject)")
        }
        if !email.from.isEmpty {
            noteLines.append("发件人：\(email.from)")
        }
        if !todo.owner.isEmpty {
            noteLines.append("负责方：\(todo.owner)")
        }
        if let deadline = todo.deadline, !deadline.isEmpty {
            noteLines.append("原文时间：\(deadline)")
        }
        if !analysis.headline.isEmpty {
            noteLines.append("AI 结论：\(analysis.headline)")
        }
        if let messageURL {
            noteLines.append("原信直达：\(messageURL.absoluteString)")
        }
        reminder.notes = noteLines.joined(separator: "\n")

        do {
            try eventStore.save(reminder, commit: true)
            markAdded(todo, messageID: email.messageID)
            ExtensionLogger.reminders.info(
                "Saved EKReminder to '\(targetCalendar.title, privacy: .public)' (\(schedule.scheduleLabel, privacy: .public))"
            )
            return schedule
        } catch {
            ExtensionLogger.reminders.error(
                "EKEventStore.save failed: \(error.localizedDescription, privacy: .public)"
            )
            throw ReminderServiceError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func storedKeysList() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.addedKeysDefaultsKey) ?? []
    }

    private func resolveTargetReminderList() -> EKCalendar? {
        let writableCalendars = eventStore.calendars(for: .reminder).filter(\.allowsContentModifications)
        if let existing = writableCalendars.first(where: { $0.title == Self.reminderListTitle }) {
            return existing
        }

        let defaultCal = eventStore.defaultCalendarForNewReminders()
        if let source = defaultCal?.source ?? eventStore.sources.first(where: {
            $0.sourceType == .calDAV || $0.sourceType == .local
        }) {
            let newCal = EKCalendar(for: .reminder, eventStore: eventStore)
            newCal.title = Self.reminderListTitle
            newCal.source = source
            if (try? eventStore.saveCalendar(newCal, commit: true)) != nil, newCal.allowsContentModifications {
                return newCal
            }
        }

        return defaultCal ?? writableCalendars.first
    }
}
