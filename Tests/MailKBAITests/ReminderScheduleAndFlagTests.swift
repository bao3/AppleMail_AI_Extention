import Foundation
import MailKit
import XCTest

final class ReminderScheduleAndFlagTests: XCTestCase {
    private let shanghaiTZ = TimeZone(identifier: "Asia/Shanghai")!

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghaiTZ
        return cal.date(from: DateComponents(
            calendar: cal,
            timeZone: shanghaiTZ,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: 0
        ))!
    }

    func testExplicitDueDateISOSchedulesOneDayEarlierAlarm() {
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 15)
        let schedule = ReminderScheduleCalculator.calculate(
            dueDateISO: "2026-11-25",
            deadlineText: "11月25日前",
            emailDateString: "Fri, 20 Nov 2026 10:00:00 +0800",
            now: now,
            timeZone: shanghaiTZ
        )

        XCTAssertTrue(schedule.isExplicitEmailDate)
        XCTAssertEqual(schedule.dueDateComponents.calendar?.identifier, .gregorian)
        XCTAssertEqual(schedule.dueDateComponents.year, 2026)
        XCTAssertEqual(schedule.dueDateComponents.month, 11)
        XCTAssertEqual(schedule.dueDateComponents.day, 25)
        XCTAssertEqual(schedule.dueDateComponents.hour, 9)
        XCTAssertEqual(schedule.dueDate, makeDate(year: 2026, month: 11, day: 25, hour: 9))
        XCTAssertEqual(schedule.alarmDate, makeDate(year: 2026, month: 11, day: 24, hour: 9))
        XCTAssertEqual(schedule.scheduleLabel, "截止 11/25 · 提前1天提醒")
    }

    func testChineseDeadlineTextFallbackInfersYearFromEmailDate() {
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 15)
        let schedule = ReminderScheduleCalculator.calculate(
            dueDateISO: "",
            deadlineText: "请在11月28日前确认",
            emailDateString: "Fri, 20 Nov 2026 09:30:00 +0800",
            now: now,
            timeZone: shanghaiTZ
        )

        XCTAssertTrue(schedule.isExplicitEmailDate)
        XCTAssertEqual(schedule.dueDate, makeDate(year: 2026, month: 11, day: 28, hour: 9))
        XCTAssertEqual(schedule.alarmDate, makeDate(year: 2026, month: 11, day: 27, hour: 9))
        XCTAssertEqual(schedule.scheduleLabel, "截止 11/28 · 提前1天提醒")
    }

    func testNearTermExplicitDateClampsPastAlarmForward() {
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 16)
        let schedule = ReminderScheduleCalculator.calculate(
            dueDateISO: "2026-11-21",
            deadlineText: "明天前",
            emailDateString: "Fri, 20 Nov 2026 15:00:00 +0800",
            now: now,
            timeZone: shanghaiTZ
        )

        XCTAssertTrue(schedule.isExplicitEmailDate)
        XCTAssertEqual(schedule.dueDate, makeDate(year: 2026, month: 11, day: 21, hour: 9))
        // 2026-11-20 09:00 is already past `now` (16:00), so alarm clamps to `dueDate` (2026-11-21 09:00 > now)
        XCTAssertEqual(schedule.alarmDate, makeDate(year: 2026, month: 11, day: 21, hour: 9))
        XCTAssertGreaterThan(schedule.alarmDate, now)
    }

    func testMissingDateDefaultsToOneWeekLater() {
        let now = makeDate(year: 2026, month: 11, day: 20, hour: 15)
        let schedule = ReminderScheduleCalculator.calculate(
            dueDateISO: "",
            deadlineText: "",
            emailDateString: "Fri, 20 Nov 2026 15:00:00 +0800",
            now: now,
            timeZone: shanghaiTZ
        )

        XCTAssertFalse(schedule.isExplicitEmailDate)
        XCTAssertEqual(schedule.dueDateComponents.calendar?.identifier, .gregorian)
        let expected = makeDate(year: 2026, month: 11, day: 27, hour: 9)
        XCTAssertEqual(schedule.dueDate, expected)
        XCTAssertEqual(schedule.alarmDate, expected)
        XCTAssertEqual(schedule.scheduleLabel, "默认1周后 (11/27)")
    }

    func testMailFlagCategoryLabelsAndMailKitMapping() {
        let expected: [(MailFlagCategory, String, MEMessageAction.Flag?)] = [
            (.red, "紧急待回", .red),
            (.orange, "等审批", .orange),
            (.yellow, "跟报价", .yellow),
            (.green, "重点项目", .green),
            (.blue, "技术卡点", .blue),
            (.purple, "产品变更", .purple),
            (.gray, "发票报销", .gray),
            (.none, "无旗标", nil)
        ]

        for (category, label, flag) in expected {
            XCTAssertEqual(category.label, label)
            XCTAssertEqual(category.mailKitFlag, flag)
        }
    }

    func testLegacyCachedAnalysisJSONDecodesWithoutFlagOrDueDateISO() throws {
        let legacyJSON = """
        {
          "headline": "客户询价 100 台 EDS-4012",
          "coreConclusions": ["需要尽快报价"],
          "todos": [
            {
              "task": "发送正式报价单",
              "owner": "我方",
              "deadline": "下周三",
              "priority": "high"
            }
          ],
          "businessElements": {
            "projects": ["Helios"],
            "customers": ["Acme"],
            "models": ["EDS-4012"],
            "pricing": []
          },
          "plainChineseTranslation": "请提供报价。",
          "timeline": [],
          "messageID": "legacy-1@moxa.com",
          "modelUsed": "gemini-3.8-flash",
          "analyzedAt": "2026-11-20T04:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EmailAIAnalysis.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.headline, "客户询价 100 台 EDS-4012")
        XCTAssertEqual(decoded.todos.count, 1)
        XCTAssertNil(decoded.todos[0].dueDateISO)
        XCTAssertNil(decoded.suggestedFlag)
        XCTAssertNil(decoded.flagReason)
        XCTAssertEqual(decoded.resolvedFlag, .none)
        XCTAssertNil(decoded.resolvedFlag.mailKitFlag)
    }
}
