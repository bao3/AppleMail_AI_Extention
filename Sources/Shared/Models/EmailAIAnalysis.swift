import Foundation

public struct EmailTodoItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(priority)|\(owner)|\(task)|\(deadline ?? "")" }
    public let task: String
    public let owner: String
    public let deadline: String?
    public let priority: String

    public init(task: String, owner: String, deadline: String? = nil, priority: String = "medium") {
        self.task = task
        self.owner = owner
        self.deadline = deadline
        self.priority = priority
    }

    public var normalizedPriority: String {
        switch priority.lowercased() {
        case "high", "p0", "p1", "高", "urgent":
            return "high"
        case "low", "p3", "低":
            return "low"
        default:
            return "medium"
        }
    }

    public var priorityLabel: String {
        switch normalizedPriority {
        case "high": return "高优先"
        case "low": return "低优先"
        default: return "中优先"
        }
    }
}

public struct PricingElement: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(itemOrModel)|\(quantity ?? "")|\(unitPrice ?? "")|\(currency ?? "")|\(termsOrLeadTime ?? "")" }
    public let itemOrModel: String
    public let quantity: String?
    public let unitPrice: String?
    public let currency: String?
    public let termsOrLeadTime: String?
    public let notes: String?

    public init(
        itemOrModel: String,
        quantity: String? = nil,
        unitPrice: String? = nil,
        currency: String? = nil,
        termsOrLeadTime: String? = nil,
        notes: String? = nil
    ) {
        self.itemOrModel = itemOrModel
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.currency = currency
        self.termsOrLeadTime = termsOrLeadTime
        self.notes = notes
    }
}

public struct BusinessElements: Codable, Sendable, Hashable {
    public let projects: [String]
    public let customers: [String]
    public let models: [String]
    public let pricing: [PricingElement]

    public init(
        projects: [String] = [],
        customers: [String] = [],
        models: [String] = [],
        pricing: [PricingElement] = []
    ) {
        self.projects = projects
        self.customers = customers
        self.models = models
        self.pricing = pricing
    }

    public var isEmpty: Bool {
        projects.isEmpty && customers.isEmpty && models.isEmpty && pricing.isEmpty
    }
}

public struct TimelineEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(timeOrStep)|\(actor)|\(summary)" }
    public let timeOrStep: String
    public let actor: String
    public let summary: String

    public init(timeOrStep: String, actor: String, summary: String) {
        self.timeOrStep = timeOrStep
        self.actor = actor
        self.summary = summary
    }
}

public struct EmailAIAnalysis: Codable, Sendable, Hashable {
    public let headline: String
    public let coreConclusions: [String]
    public let todos: [EmailTodoItem]
    public let businessElements: BusinessElements
    public let plainChineseTranslation: String
    public let timeline: [TimelineEvent]

    public var messageID: String
    public var modelUsed: String
    public var analyzedAt: Date
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    public var latencyMs: Int?

    public init(
        headline: String,
        coreConclusions: [String],
        todos: [EmailTodoItem],
        businessElements: BusinessElements,
        plainChineseTranslation: String,
        timeline: [TimelineEvent],
        messageID: String = "",
        modelUsed: String = GeminiModel.defaultModel.rawValue,
        analyzedAt: Date = Date(),
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedTokens: Int? = nil,
        latencyMs: Int? = nil
    ) {
        self.headline = headline
        self.coreConclusions = coreConclusions
        self.todos = todos
        self.businessElements = businessElements
        self.plainChineseTranslation = plainChineseTranslation
        self.timeline = timeline
        self.messageID = messageID
        self.modelUsed = modelUsed
        self.analyzedAt = analyzedAt
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.latencyMs = latencyMs
    }

    public func toMarkdownReport(subject: String) -> String {
        var md: [String] = []
        md.append("# \(subject.isEmpty ? "邮件 AI 汇总分析" : subject)")
        md.append("")
        md.append("## 核心结论")
        md.append("**\(headline)**")
        for item in coreConclusions {
            md.append("- \(item)")
        }

        if !todos.isEmpty {
            md.append("")
            md.append("## 待办事项")
            for todo in todos {
                let dl = todo.deadline.flatMap { $0.isEmpty ? nil : "（截止: \($0)）" } ?? ""
                md.append("- [\(todo.priorityLabel)] **\(todo.owner)**: \(todo.task)\(dl)")
            }
        }

        if !businessElements.isEmpty {
            md.append("")
            md.append("## 商务与项目要素")
            if !businessElements.projects.isEmpty {
                md.append("- **项目**: \(businessElements.projects.joined(separator: "、"))")
            }
            if !businessElements.customers.isEmpty {
                md.append("- **客户/相关方**: \(businessElements.customers.joined(separator: "、"))")
            }
            if !businessElements.models.isEmpty {
                md.append("- **型号/料号**: \(businessElements.models.joined(separator: "、"))")
            }
            if !businessElements.pricing.isEmpty {
                md.append("- **价格与交期**:")
                for p in businessElements.pricing {
                    let parts = [
                        p.itemOrModel,
                        p.quantity.map { "数量: \($0)" },
                        p.unitPrice.map { "单价: \($0)" },
                        p.currency.map { "币种: \($0)" },
                        p.termsOrLeadTime.map { "条款/交期: \($0)" },
                        p.notes.map { "备注: \($0)" }
                    ].compactMap { $0 }.filter { !$0.isEmpty }
                    md.append("  - \(parts.joined(separator: " | "))")
                }
            }
        }

        if !plainChineseTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md.append("")
            md.append("## 英文通俗中译 / 核心译文")
            md.append(plainChineseTranslation)
        }

        if !timeline.isEmpty {
            md.append("")
            md.append("## 长信时间线")
            for event in timeline {
                md.append("- **\(event.timeOrStep)** [\(event.actor)]: \(event.summary)")
            }
        }

        md.append("")
        md.append("---")
        md.append("Message-ID: `\(messageID)` | 模型: `\(modelUsed)`")
        return md.joined(separator: "\n")
    }
}

public struct ComposeReplyDraft: Codable, Sendable, Hashable {
    public let suggestedSubject: String
    public let englishDraft: String
    public let chineseDraft: String
    public let bilingualCombinedDraft: String
    public let keyPointsCovered: [String]
    public var modelUsed: String
    public var generatedAt: Date

    public init(
        suggestedSubject: String,
        englishDraft: String,
        chineseDraft: String,
        bilingualCombinedDraft: String,
        keyPointsCovered: [String],
        modelUsed: String = GeminiModel.defaultModel.rawValue,
        generatedAt: Date = Date()
    ) {
        self.suggestedSubject = suggestedSubject
        self.englishDraft = englishDraft
        self.chineseDraft = chineseDraft
        self.bilingualCombinedDraft = bilingualCombinedDraft
        self.keyPointsCovered = keyPointsCovered
        self.modelUsed = modelUsed
        self.generatedAt = generatedAt
    }
}
