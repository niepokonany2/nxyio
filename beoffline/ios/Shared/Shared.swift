import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import UserNotifications

let appGroupID = "group.pl.beoffline.shared"

struct LimitConfig: Codable {
    var id: String
    var selection: FamilyActivitySelection
    var dailyMinutes: Int
    var sessionMinutes: Int
    var waitSeconds: Int

    var totalSessions: Int {
        sessionMinutes <= 0 ? 0 : Int(ceil(Double(dailyMinutes) / Double(sessionMinutes)))
    }
}

struct LimitState: Codable {
    var day: String
    var sessionsUsed: Int = 0
    var dailyReached: Bool = false
    var unlocked: Bool = false
    var waitStartedAt: Date? = nil
}

enum SharedStore {
    static let defaults = UserDefaults(suiteName: appGroupID)!

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    private static func load<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // ---------- limity ----------
    static var limits: [LimitConfig] {
        get { load("limits", [LimitConfig].self) ?? [] }
        set { save(newValue, "limits") }
    }

    static func limit(containing token: ApplicationToken) -> LimitConfig? {
        limits.first { $0.selection.applicationTokens.contains(token) }
    }
    static func limit(containingCategory token: ActivityCategoryToken) -> LimitConfig? {
        limits.first { $0.selection.categoryTokens.contains(token) }
    }
    static func limit(containingDomain token: WebDomainToken) -> LimitConfig? {
        limits.first { $0.selection.webDomainTokens.contains(token) }
    }

    static func state(_ id: String) -> LimitState {
        if let s = load("state_\(id)", LimitState.self), s.day == dayKey() { return s }
        return LimitState(day: dayKey())
    }

    static func setState(_ state: LimitState, _ id: String) { save(state, "state_\(id)") }

    // ---------- limit urządzenia ----------
    static var deviceSelection: FamilyActivitySelection? {
        get { load("deviceSelection", FamilyActivitySelection.self) }
        set { save(newValue, "deviceSelection") }
    }

    static var deviceLimitMinutes: Int {
        get { let v = defaults.integer(forKey: "deviceLimit"); return v > 0 ? v : 120 }
        set { defaults.set(newValue, forKey: "deviceLimit") }
    }

    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: "notifications") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notifications") }
    }

    // ---------- seria dni ----------
    static var activeDays: Set<String> {
        get { Set(defaults.stringArray(forKey: "activeDays") ?? []) }
        set { defaults.set(Array(newValue), forKey: "activeDays") }
    }

    static var exceededDays: Set<String> {
        get { Set(defaults.stringArray(forKey: "exceededDays") ?? []) }
        set { defaults.set(Array(newValue), forKey: "exceededDays") }
    }

    static func streakJSON() -> String {
        let days = activeDays
        let cal = Calendar.current
        var current = 0
        var d = Date()
        if !days.contains(dayKey(d)) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        while days.contains(dayKey(d)) {
            current += 1
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        let dates = days.compactMap { dayFormatter.date(from: $0) }.sorted()
        var best = 0, run = 0
        var prev: Date?
        for date in dates {
            if let p = prev, cal.dateComponents([.day], from: p, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            prev = date
        }
        best = max(best, current)
        let obj: [String: Any] = [
            "currentStreak": current,
            "bestStreak": best,
            "activeDays": Array(days),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// ---------- blokowanie ----------
func managedStore(_ id: String) -> ManagedSettingsStore {
    ManagedSettingsStore(named: ManagedSettingsStore.Name("limit_\(id)"))
}

func applyShield(_ cfg: LimitConfig) {
    let s = managedStore(cfg.id)
    let sel = cfg.selection
    s.shield.applications = sel.applicationTokens.isEmpty ? nil : sel.applicationTokens
    s.shield.applicationCategories = sel.categoryTokens.isEmpty ? nil : .specific(sel.categoryTokens)
    s.shield.webDomains = sel.webDomainTokens.isEmpty ? nil : sel.webDomainTokens
}

func removeShield(_ id: String) {
    managedStore(id).clearAllSettings()
}

func sendNotification(_ title: String, _ body: String) {
    guard SharedStore.notificationsEnabled else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

func formatDurationPL(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s <= 0 { return "0 min" }
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return "\(h) godz. \(String(format: "%02d", m)) min" }
    if m > 0 { return "\(m) min" }
    return "\(s) sek."
}

extension DeviceActivityName {
    static let daily = Self("beoffline.daily")
}

// ---------- harmonogram ----------
enum Scheduler {
    static func threshold(_ minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60)
    }

    static func restart() {
        let center = DeviceActivityCenter()
        center.stopMonitoring([.daily])

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]

        for cfg in SharedStore.limits where cfg.totalSessions > 0 {
            for k in 1...cfg.totalSessions {
                let minutes = min(k * cfg.sessionMinutes, cfg.dailyMinutes)
                events[DeviceActivityEvent.Name("L|\(cfg.id)|\(k)")] = DeviceActivityEvent(
                    applications: cfg.selection.applicationTokens,
                    categories: cfg.selection.categoryTokens,
                    webDomains: cfg.selection.webDomainTokens,
                    threshold: threshold(minutes))
            }
        }

        if let sel = SharedStore.deviceSelection {
            for p in [50, 80, 100] {
                let m = max(1, SharedStore.deviceLimitMinutes * p / 100)
                events[DeviceActivityEvent.Name("D|\(p)")] = DeviceActivityEvent(
                    applications: sel.applicationTokens,
                    categories: sel.categoryTokens,
                    webDomains: sel.webDomainTokens,
                    threshold: threshold(m))
            }
        }

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true)

        do {
            try center.startMonitoring(.daily, during: schedule, events: events)
        } catch {
            print("startMonitoring error: \(error)")
        }

        for cfg in SharedStore.limits {
            let st = SharedStore.state(cfg.id)
            if st.unlocked && !st.dailyReached { removeShield(cfg.id) } else { applyShield(cfg) }
        }
    }
}