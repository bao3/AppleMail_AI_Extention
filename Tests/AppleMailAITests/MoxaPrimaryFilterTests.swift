import Foundation
import XCTest

final class MoxaPrimaryFilterTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_795_140_000)

    func testAllowsMoxaInternalColleagueMail() {
        let input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "回覆: CRH380D 动车组娱乐系统改造-TM-1520-4GTX",
            fromAddress: "Bonnie Tsai (蔡淑媛) <Bonnie.Tsai@moxa.com>",
            toAddresses: ["Baoshan Wang (王宝山) <Baoshan.Wang@moxa.com>"],
            ccAddresses: ["Terry Tsai <Terry.Tsai@moxa.com>"],
            allRecipientAddresses: ["Baoshan.Wang@moxa.com", "Terry.Tsai@moxa.com"],
            dateReceived: fixedNow.addingTimeInterval(-3600),
            headers: [
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID],
                "x-ms-exchange-organization-scl": ["1"]
            ]
        )

        XCTAssertEqual(MoxaPrimaryFilter.evaluate(input, now: fixedNow), .allowMoxaPrimary)
    }

    func testAllowsExternalCustomerMailViaMoxaTenantHeader() {
        let input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Fw: 2026 年第四季度（Q4）FEP 拼单数量及下单",
            fromAddress: "\"张德信\" <zhangdexin@hki-smart.com>",
            toAddresses: ["倪君燕 <nijy@hki-smart.com>"],
            allRecipientAddresses: ["nijy@hki-smart.com"],
            dateReceived: fixedNow.addingTimeInterval(-1800),
            headers: [
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID],
                "x-ms-exchange-organization-scl": ["1"]
            ]
        )

        XCTAssertEqual(MoxaPrimaryFilter.evaluate(input, now: fixedNow), .allowMoxaPrimary)
    }

    func testAllowsMoxaDistributionListMailWithoutDirectUserAddress() {
        let input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "<20261119> 总部 Label 变更进度同步",
            fromAddress: "Grace Gu (谷禾) <Grace.Gu@moxa.com>",
            toAddresses: ["Henry Zhang <Henry.Zhang@moxa.com>"],
            allRecipientAddresses: ["Henry.Zhang@moxa.com"],
            dateReceived: fixedNow.addingTimeInterval(-600),
            headers: [
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID]
            ]
        )

        XCTAssertEqual(MoxaPrimaryFilter.evaluate(input, now: fixedNow), .allowMoxaPrimary)
    }

    func testSkipsPersonalAccountsAndForwardedGmailCopies() {
        let iCloudInput = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Your Apple receipt",
            fromAddress: "no_reply@email.apple.com",
            toAddresses: ["modbus@icloud.com"],
            allRecipientAddresses: ["modbus@icloud.com"],
            dateReceived: fixedNow
        )
        XCTAssertEqual(MoxaPrimaryFilter.evaluate(iCloudInput, now: fixedNow), .skip(.nonMoxaAccount("not moxa")))

        let bao3Input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Server alert",
            fromAddress: "admin@example.com",
            toAddresses: ["ai@bao3.org"],
            allRecipientAddresses: ["ai@bao3.org"],
            dateReceived: fixedNow
        )
        XCTAssertEqual(MoxaPrimaryFilter.evaluate(bao3Input, now: fixedNow), .skip(.nonMoxaAccount("not moxa")))

        let gmailInput = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Personal note",
            fromAddress: "friend@example.com",
            toAddresses: ["bao3.cn@gmail.com"],
            allRecipientAddresses: ["bao3.cn@gmail.com"],
            dateReceived: fixedNow,
            headers: ["delivered-to": ["bao3.cn@gmail.com"]]
        )
        XCTAssertEqual(
            MoxaPrimaryFilter.evaluate(gmailInput, now: fixedNow),
            .skip(.nonMoxaAccount("delivered-to non-moxa"))
        )

        // Moxa mail forwarded to personal Gmail must also be skipped via Delivered-To
        let forwardedToGmail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Re: CRH380D",
            fromAddress: "Bonnie.Tsai@moxa.com",
            toAddresses: ["Baoshan.Wang@moxa.com"],
            allRecipientAddresses: ["Baoshan.Wang@moxa.com"],
            dateReceived: fixedNow,
            headers: [
                "delivered-to": ["bao3.cn@gmail.com"],
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID]
            ]
        )
        XCTAssertEqual(
            MoxaPrimaryFilter.evaluate(forwardedToGmail, now: fixedNow),
            .skip(.nonMoxaAccount("delivered-to non-moxa"))
        )
    }

    func testSkipsSelfSentMail() {
        let input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "讨论取消或降低 DA-682B-FEP 机种 MOQ=50 限制",
            fromAddress: "Baoshan Wang (王宝山) <Baoshan.Wang@moxa.com>",
            toAddresses: ["Ming Yu <ming.yu@moxa.com>"],
            allRecipientAddresses: ["ming.yu@moxa.com"],
            dateReceived: fixedNow,
            headers: ["x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID]]
        )

        XCTAssertEqual(MoxaPrimaryFilter.evaluate(input, now: fixedNow), .skip(.selfSent))
    }

    func testSkipsAutomatedBotsAndSystemSenders() {
        let botAddresses = [
            "Moxa Portal Admin <portal.admin@moxa.com>",
            "MOXA OA System <oa.admin@moxa.com>",
            "IT (資訊處) <IT@moxa.com>",
            "Peter YH Yu in Teams <no-reply@teams.mail.microsoft>",
            "Vendor Bot <noreply@vendor.example.com>"
        ]

        for sender in botAddresses {
            let input = MessageFilterInput(
                isReceivedState: true,
                isEncrypted: false,
                subject: "System notification",
                fromAddress: sender,
                toAddresses: ["Baoshan.Wang@moxa.com"],
                allRecipientAddresses: ["Baoshan.Wang@moxa.com"],
                dateReceived: fixedNow,
                headers: ["x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID]]
            )
            XCTAssertEqual(
                MoxaPrimaryFilter.evaluate(input, now: fixedNow),
                .skip(.automatedSystem("bot sender")),
                "Expected bot sender \(sender) to be skipped"
            )
        }
    }

    func testSkipsNewsletters() {
        let input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Monthly Digest",
            fromAddress: "marketing@partner.example",
            toAddresses: ["baoshan.wang@moxa.com"],
            allRecipientAddresses: ["baoshan.wang@moxa.com"],
            dateReceived: fixedNow,
            headers: [
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID],
                "list-unsubscribe": ["<mailto:unsubscribe@partner.example>"]
            ]
        )

        XCTAssertEqual(
            MoxaPrimaryFilter.evaluate(input, now: fixedNow),
            .skip(.newsletterOrPromotion("list-unsubscribe"))
        )
    }

    func testMassBroadcastVsDirectAutoResponseSuppress() {
        let massBroadcast = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "跨年度报销提醒！",
            fromAddress: "Chen YC Yao (姚晨) <ChenYC.Yao@moxa.com>",
            toAddresses: ["Moxa China All <china.all@moxa.com>"],
            allRecipientAddresses: ["china.all@moxa.com"],
            dateReceived: fixedNow,
            headers: [
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID],
                "x-auto-response-suppress": ["DR, OOF, AutoReply"]
            ]
        )
        XCTAssertEqual(
            MoxaPrimaryFilter.evaluate(massBroadcast, now: fixedNow),
            .skip(.automatedSystem("mass-broadcast"))
        )

        let directMailWithHeader = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "报销单补充材料",
            fromAddress: "Chen YC Yao (姚晨) <ChenYC.Yao@moxa.com>",
            toAddresses: ["Baoshan Wang (王宝山) <Baoshan.Wang@moxa.com>"],
            allRecipientAddresses: ["Baoshan.Wang@moxa.com"],
            dateReceived: fixedNow,
            headers: [
                "x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID],
                "x-auto-response-suppress": ["DR, OOF, AutoReply"]
            ]
        )
        XCTAssertEqual(MoxaPrimaryFilter.evaluate(directMailWithHeader, now: fixedNow), .allowMoxaPrimary)
    }

    func testSkipsCalendarResponses() {
        for subject in ["已取消: TBG周会", "Accepted: Design Review", "已拒绝：项目评审"] {
            let input = MessageFilterInput(
                isReceivedState: true,
                isEncrypted: false,
                subject: subject,
                fromAddress: "colleague@moxa.com",
                toAddresses: ["baoshan.wang@moxa.com"],
                allRecipientAddresses: ["baoshan.wang@moxa.com"],
                dateReceived: fixedNow,
                headers: ["x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID]]
            )
            XCTAssertEqual(
                MoxaPrimaryFilter.evaluate(input, now: fixedNow),
                .skip(.calendarNotification),
                "Expected calendar subject '\(subject)' to be skipped"
            )
        }
    }

    func testSkipsStaleMessagesOlderThan48Hours() {
        let input = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Old Project Update",
            fromAddress: "colleague@moxa.com",
            toAddresses: ["baoshan.wang@moxa.com"],
            allRecipientAddresses: ["baoshan.wang@moxa.com"],
            dateReceived: fixedNow.addingTimeInterval(-(48 * 3600 + 60)),
            headers: ["x-ms-exchange-crosstenant-id": [MoxaPrimaryFilter.moxaTenantID]]
        )

        XCTAssertEqual(MoxaPrimaryFilter.evaluate(input, now: fixedNow), .skip(.tooOld))
    }
}
