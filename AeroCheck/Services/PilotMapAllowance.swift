import Foundation

/// The pilot's map's monthly online allowance (the trial page's t3 A): per device and calendar month, the tiles read
/// from tiles.aerocheck.app, map and relief alike. A downloaded region's tiles and MapLibre's cached ones never
/// count, so a pilot who downloads the regions they fly never meets it. (6.8.0)
///
/// Free 1,500 reads (about 40 screens), Pro and lifetime 15,000. At 80 % the map offers the region's download; at
/// 100 % online loading stops outside downloaded regions until the next month. 500 pilots, 30 % Pro, all at the
/// limit: 2.8 million R2 reads a month, of 10 million free.
final class PilotMapAllowance: @unchecked Sendable {
    enum Plan: Equatable, Sendable { case free, pro }

    enum Level: Equatable, Sendable {
        case open
        /// 80 % used: offer the download.
        case nearLimit
        /// All used: online tiles stop until the month turns.
        case exhausted
    }

    static let freeReads = 1_500
    static let proReads = 15_000
    static let nearLimitShare = 0.8

    /// Posted on the main queue when `level` changes (a threshold crossed, the plan changed, the month turned).
    static let levelChanged = Notification.Name("PilotMapAllowanceLevelChanged")

    static func limit(for plan: Plan) -> Int { plan == .pro ? proReads : freeReads }

    private static let key = "pilotMapAllowance"

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let lock = NSLock()
    private var month: String
    private var count: Int
    private var currentPlan: Plan = .free
    private var lastLevel: Level

    init(defaults: UserDefaults, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        let stored = defaults.dictionary(forKey: Self.key)
        month = stored?["month"] as? String ?? ""
        count = stored?["used"] as? Int ?? 0
        lastLevel = .open
        lock.withLock {
            rollOver()
            lastLevel = levelLocked()
        }
    }

    /// Pro and lifetime get the larger allowance. Set from `SubscriptionManager.shouldAllowPremiumAccess()`, which
    /// holds Pro through a flight started with it.
    var plan: Plan {
        get { lock.withLock { currentPlan } }
        set {
            lock.withLock { currentPlan = newValue }
            announceIfChanged()
        }
    }

    var limit: Int { lock.withLock { Self.limit(for: currentPlan) } }

    /// Reads used this month.
    var used: Int { lock.withLock { rollOver(); return count } }

    var remaining: Int { lock.withLock { rollOver(); return max(0, Self.limit(for: currentPlan) - count) } }

    var level: Level { lock.withLock { rollOver(); return levelLocked() } }

    /// Takes one read from this month's allowance; false when none is left.
    func reserve() -> Bool {
        let granted = lock.withLock { () -> Bool in
            rollOver()
            guard count < Self.limit(for: currentPlan) else { return false }
            count += 1
            save()
            return true
        }
        announceIfChanged()
        return granted
    }

    /// Gives back a read that didn't happen (the request failed).
    func refund() {
        lock.withLock {
            rollOver()
            guard count > 0 else { return }
            count -= 1
            save()
        }
        announceIfChanged()
    }

    // MARK: - Private (under the lock)

    private func monthKey() -> String {
        let parts = calendar.dateComponents([.year, .month], from: now())
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func rollOver() {
        let current = monthKey()
        guard current != month else { return }
        month = current
        count = 0
        save()
    }

    private func save() {
        defaults.set(["month": month, "used": count], forKey: Self.key)
    }

    private func levelLocked() -> Level {
        let limit = Self.limit(for: currentPlan)
        if count >= limit { return .exhausted }
        if Double(count) >= Double(limit) * Self.nearLimitShare { return .nearLimit }
        return .open
    }

    private func announceIfChanged() {
        let changed = lock.withLock { () -> Bool in
            rollOver()
            let level = levelLocked()
            defer { lastLevel = level }
            return level != lastLevel
        }
        guard changed else { return }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.levelChanged, object: self) }
    }
}
