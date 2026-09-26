import Foundation
import HandaCore

extension Notification.Name {
    static let handaPreferencesChanged = Notification.Name("HandaPreferencesChanged")
    static let handaReviewsChanged = Notification.Name("HandaReviewsChanged")
}

/// User settings, stored in the standard defaults.
enum Preferences {
    enum ReviewProvider: String {
        case claude
        case command
    }

    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let openInEditMode = "OpenInEditMode"
        static let escClosesPreview = "EscClosesPreview"
        static let textSize = "TextSize"
        static let wrapCode = "WrapCode"
        static let lineNumbers = "ShowLineNumbers"
        static let aiEnabled = "AIEnabled"
        static let provider = "ReviewProvider"
        static let model = "ClaudeModel"
        static let command = "ReviewCommand"
        static let instruction = "ReviewInstruction"
        static let autoReview = "AutoReview"
        static let rules = "ReviewRules"
        static let offeredDefault = "OfferedDefaultApp"
    }

    static let defaultInstruction = "Review this file. Point out mistakes, inconsistencies and anything that looks risky or unclear."
    static let defaultCommand = "claude -p {instruction}"

    static func register() {
        defaults.register(defaults: [
            Key.openInEditMode: false,
            Key.escClosesPreview: true,
            Key.textSize: 13.0,
            Key.wrapCode: false,
            Key.lineNumbers: true,
            Key.aiEnabled: false,
            Key.provider: ReviewProvider.claude.rawValue,
            Key.model: AnthropicClient.defaultModel,
            Key.command: defaultCommand,
            Key.instruction: defaultInstruction,
            Key.autoReview: false,
            Key.offeredDefault: false,
        ])
    }

    static func changed() {
        NotificationCenter.default.post(name: .handaPreferencesChanged, object: nil)
    }

    static var openInEditMode: Bool {
        get { defaults.bool(forKey: Key.openInEditMode) }
        set { defaults.set(newValue, forKey: Key.openInEditMode); changed() }
    }

    static var escClosesPreview: Bool {
        get { defaults.bool(forKey: Key.escClosesPreview) }
        set { defaults.set(newValue, forKey: Key.escClosesPreview); changed() }
    }

    static var textSize: CGFloat {
        get { CGFloat(min(max(defaults.double(forKey: Key.textSize), 9), 32)) }
        set { defaults.set(Double(newValue), forKey: Key.textSize); changed() }
    }

    static var wrapCode: Bool {
        get { defaults.bool(forKey: Key.wrapCode) }
        set { defaults.set(newValue, forKey: Key.wrapCode); changed() }
    }

    static var showLineNumbers: Bool {
        get { defaults.bool(forKey: Key.lineNumbers) }
        set { defaults.set(newValue, forKey: Key.lineNumbers); changed() }
    }

    static var aiEnabled: Bool {
        get { defaults.bool(forKey: Key.aiEnabled) }
        set { defaults.set(newValue, forKey: Key.aiEnabled); changed() }
    }

    static var reviewProvider: ReviewProvider {
        get { ReviewProvider(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .claude }
        set { defaults.set(newValue.rawValue, forKey: Key.provider); changed() }
    }

    static var claudeModel: String {
        get {
            let value = defaults.string(forKey: Key.model)?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? AnthropicClient.defaultModel : value
        }
        set { defaults.set(newValue, forKey: Key.model); changed() }
    }

    static var reviewCommand: String {
        get { defaults.string(forKey: Key.command) ?? defaultCommand }
        set { defaults.set(newValue, forKey: Key.command); changed() }
    }

    static var reviewInstruction: String {
        get {
            let value = defaults.string(forKey: Key.instruction)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? defaultInstruction : value
        }
        set { defaults.set(newValue, forKey: Key.instruction); changed() }
    }

    static var autoReview: Bool {
        get { defaults.bool(forKey: Key.autoReview) }
        set { defaults.set(newValue, forKey: Key.autoReview); changed() }
    }

    static var reviewRules: [ReviewRule] {
        get {
            guard let data = defaults.data(forKey: Key.rules) else { return [] }
            return (try? JSONDecoder().decode([ReviewRule].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.rules)
            changed()
        }
    }

    static var offeredDefaultApp: Bool {
        get { defaults.bool(forKey: Key.offeredDefault) }
        set { defaults.set(newValue, forKey: Key.offeredDefault) }
    }
}
