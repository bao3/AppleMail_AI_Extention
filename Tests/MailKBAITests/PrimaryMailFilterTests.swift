import Foundation
import XCTest

final class PrimaryMailFilterTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_795_140_000)

    private let scopedEnterpriseConfig = PrimaryMailFilterScope(
        allowedDomains: ["acme.example"],
        allowedTenantIDs: ["11111111-2222-3333-4444-555555555555"],
        selfAddresses: ["alex@acme.example"],
        customBotAddresses: ["portal.admin@acme.example", "oa.admin@acme.example", "it@acme.example"]
    )

    // MARK: - Universal Default Mode (Empty Scope)

    func testUniversalDefaultAllowsNormalEmailsAcrossProviders() {
        let defaultScope = PrimaryMailFilterScope()

        let workMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Project Helios BOM confirmation",
            fromAddress: "Bonnie <bonnie@partner.example>",
            toAddresses: ["alex@acme.example"],
            allRecipientAddresses: ["alex@acme.example"],
            dateReceived: fixedNow.addingTimeInterval(-3600)
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(workMail, scope: defaultScope, now: fixedNow), .allowPrimary)

        let personalICloudMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Weekend dinner plans",
            fromAddress: "Friend <friend@example.org>",
            toAddresses: ["alex@icloud.com"],
            allRecipientAddresses: ["alex@icloud.com"],
            dateReceived: fixedNow.addingTimeInterval(-1200)
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(personalICloudMail, scope: defaultScope, now: fixedNow), .allowPrimary)

        let gmailMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Invoice #2026-11",
            fromAddress: "Billing <billing@vendor.example>",
            toAddresses: ["alex.chen@gmail.com"],
            allRecipientAddresses: ["alex.chen@gmail.com"],
            dateReceived: fixedNow.addingTimeInterval(-600),
            headers: ["delivered-to": ["alex.chen@gmail.com"]]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(gmailMail, scope: defaultScope, now: fixedNow), .allowPrimary)
    }

    func testUniversalDefaultSkipsInvalidBulkNewsletterBotsAndCalendar() {
        let defaultScope = PrimaryMailFilterScope()

        let sentState = MessageFilterInput(
            isReceivedState: false,
            isEncrypted: false,
            subject: "Sent draft",
            fromAddress: "alex@acme.example",
            dateReceived: fixedNow
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(sentState, scope: defaultScope, now: fixedNow), .skip(.notReceivedState))

        let encryptedMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: true,
            subject: "Encrypted",
            fromAddress: "partner@acme.example",
            dateReceived: fixedNow
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(encryptedMail, scope: defaultScope, now: fixedNow), .skip(.encrypted))

        let staleMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Old thread",
            fromAddress: "partner@acme.example",
            dateReceived: fixedNow.addingTimeInterval(-(48 * 3600 + 60))
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(staleMail, scope: defaultScope, now: fixedNow), .skip(.tooOld))

        let highSCL = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Suspected spam",
            fromAddress: "promo@spam.example",
            dateReceived: fixedNow,
            headers: ["x-ms-exchange-organization-scl": ["6"]]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(highSCL, scope: defaultScope, now: fixedNow), .skip(.spamOrBulk("scl")))

        let bulkPrecedence = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Announcement",
            fromAddress: "news@vendor.example",
            dateReceived: fixedNow,
            headers: ["precedence": ["bulk"]]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(bulkPrecedence, scope: defaultScope, now: fixedNow), .skip(.spamOrBulk("precedence")))

        let newsletterListID = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Weekly roundup",
            fromAddress: "digest@vendor.example",
            dateReceived: fixedNow,
            headers: ["list-id": ["<weekly.vendor.example>"]]
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(newsletterListID, scope: defaultScope, now: fixedNow),
            .skip(.newsletterOrPromotion("list-id"))
        )

        let autoSubmitted = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Out of Office",
            fromAddress: "colleague@partner.example",
            dateReceived: fixedNow,
            headers: ["auto-submitted": ["auto-replied"]]
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(autoSubmitted, scope: defaultScope, now: fixedNow),
            .skip(.automatedSystem("auto-submitted"))
        )

        let suppressAll = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "System alert",
            fromAddress: "notify@partner.example",
            dateReceived: fixedNow,
            headers: ["x-auto-response-suppress": ["All"]]
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(suppressAll, scope: defaultScope, now: fixedNow),
            .skip(.automatedSystem("suppress-all"))
        )

        let genericBot = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Order shipped",
            fromAddress: "Vendor Bot <noreply@vendor.example>",
            dateReceived: fixedNow
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(genericBot, scope: defaultScope, now: fixedNow),
            .skip(.automatedSystem("bot sender"))
        )

        let calendarResp = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Accepted: Architecture Review",
            fromAddress: "colleague@partner.example",
            dateReceived: fixedNow
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(calendarResp, scope: defaultScope, now: fixedNow),
            .skip(.calendarNotification)
        )
    }

    // MARK: - Scoped Domain / Tenant / Self-Address Mode

    func testScopedModeAllowsInternalColleagueAndExternalTenantMail() {
        let internalMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Re: Substation Phase 2 Switch Quote",
            fromAddress: "Bonnie <bonnie@acme.example>",
            toAddresses: ["Alex <alex@acme.example>"],
            ccAddresses: ["Terry <terry@acme.example>"],
            allRecipientAddresses: ["alex@acme.example", "terry@acme.example"],
            dateReceived: fixedNow.addingTimeInterval(-3600),
            headers: [
                "x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"],
                "x-ms-exchange-organization-scl": ["1"]
            ]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(internalMail, scope: scopedEnterpriseConfig, now: fixedNow), .allowPrimary)

        let externalTenantMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Fw: Q4 BOM Pricing & Order",
            fromAddress: "Buyer <buyer@client.example>",
            toAddresses: ["Procurement <proc@client.example>"],
            allRecipientAddresses: ["proc@client.example"],
            dateReceived: fixedNow.addingTimeInterval(-1800),
            headers: [
                "x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"],
                "x-ms-exchange-organization-scl": ["1"]
            ]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(externalTenantMail, scope: scopedEnterpriseConfig, now: fixedNow), .allowPrimary)
    }

    func testScopedModeSkipsOutOfScopeAccountsAndForwardedCopies() {
        let iCloudInput = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Your Apple receipt",
            fromAddress: "no_reply@email.apple.com",
            toAddresses: ["personal@icloud.com"],
            allRecipientAddresses: ["personal@icloud.com"],
            dateReceived: fixedNow
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(iCloudInput, scope: scopedEnterpriseConfig, now: fixedNow),
            .skip(.outOfScopeAccount("outside configured scope"))
        )

        let forwardedToPersonalGmail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Re: Project Helios",
            fromAddress: "bonnie@acme.example",
            toAddresses: ["alex@acme.example"],
            allRecipientAddresses: ["alex@acme.example"],
            dateReceived: fixedNow,
            headers: [
                "delivered-to": ["personal.user@gmail.com"],
                "x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"]
            ]
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(forwardedToPersonalGmail, scope: scopedEnterpriseConfig, now: fixedNow),
            .skip(.outOfScopeAccount("delivered-to outside allowed domains"))
        )
    }

    func testScopedModeSkipsSelfSentCustomBotsNewslettersAndMassBroadcasts() {
        let selfSent = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "MOQ approval request",
            fromAddress: "Alex Chen <alex@acme.example>",
            toAddresses: ["ming@acme.example"],
            allRecipientAddresses: ["ming@acme.example"],
            dateReceived: fixedNow,
            headers: ["x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"]]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(selfSent, scope: scopedEnterpriseConfig, now: fixedNow), .skip(.selfSent))

        for bot in ["OA System <oa.admin@acme.example>", "IT Helpdesk <IT@acme.example>", "Teams <no-reply@teams.mail.microsoft>"] {
            let botInput = MessageFilterInput(
                isReceivedState: true,
                isEncrypted: false,
                subject: "System notification",
                fromAddress: bot,
                toAddresses: ["alex@acme.example"],
                allRecipientAddresses: ["alex@acme.example"],
                dateReceived: fixedNow,
                headers: ["x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"]]
            )
            XCTAssertEqual(
                PrimaryMailFilter.evaluate(botInput, scope: scopedEnterpriseConfig, now: fixedNow),
                .skip(.automatedSystem("bot sender"))
            )
        }

        let newsletter = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Monthly Digest",
            fromAddress: "marketing@partner.example",
            toAddresses: ["alex@acme.example"],
            allRecipientAddresses: ["alex@acme.example"],
            dateReceived: fixedNow,
            headers: [
                "x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"],
                "list-unsubscribe": ["<mailto:unsubscribe@partner.example>"]
            ]
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(newsletter, scope: scopedEnterpriseConfig, now: fixedNow),
            .skip(.newsletterOrPromotion("list-unsubscribe"))
        )

        let massBroadcast = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Year-end reimbursement notice",
            fromAddress: "Finance <finance@acme.example>",
            toAddresses: ["All Staff <all@acme.example>"],
            allRecipientAddresses: ["all@acme.example"],
            dateReceived: fixedNow,
            headers: [
                "x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"],
                "x-auto-response-suppress": ["DR, OOF, AutoReply"]
            ]
        )
        XCTAssertEqual(
            PrimaryMailFilter.evaluate(massBroadcast, scope: scopedEnterpriseConfig, now: fixedNow),
            .skip(.automatedSystem("mass-broadcast"))
        )

        let directMail = MessageFilterInput(
            isReceivedState: true,
            isEncrypted: false,
            subject: "Reimbursement receipt needed",
            fromAddress: "Finance <finance@acme.example>",
            toAddresses: ["Alex <alex@acme.example>"],
            allRecipientAddresses: ["alex@acme.example"],
            dateReceived: fixedNow,
            headers: [
                "x-ms-exchange-crosstenant-id": ["11111111-2222-3333-4444-555555555555"],
                "x-auto-response-suppress": ["DR, OOF, AutoReply"]
            ]
        )
        XCTAssertEqual(PrimaryMailFilter.evaluate(directMail, scope: scopedEnterpriseConfig, now: fixedNow), .allowPrimary)
    }

    // MARK: - Scope Persistence

    func testSaveAndLoadScopeInIsolatedUserDefaults() {
        let suite = "com.bao3.MailKBAI.filter-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(PrimaryMailFilter.loadScope(from: defaults), PrimaryMailFilterScope())

        let saved = PrimaryMailFilterScope(
            allowedDomains: ["@ACME.EXAMPLE", "partner.org", "acme.example"],
            allowedTenantIDs: ["tenant-1"],
            selfAddresses: ["Alex@ACME.Example"],
            customBotAddresses: ["Bot@acme.example"]
        )
        PrimaryMailFilter.saveScope(saved, to: defaults)

        let reloaded = PrimaryMailFilter.loadScope(from: defaults)
        XCTAssertEqual(reloaded.allowedDomains, ["acme.example", "partner.org"])
        XCTAssertEqual(reloaded.allowedTenantIDs, ["tenant-1"])
        XCTAssertEqual(reloaded.selfAddresses, ["alex@acme.example"])
        XCTAssertEqual(reloaded.customBotAddresses, ["bot@acme.example"])
    }
}
