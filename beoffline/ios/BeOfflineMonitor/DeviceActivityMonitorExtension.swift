import DeviceActivity
import ManagedSettings
import Foundation

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // Nowy dzień: reset sesji i blokada (najpierw trzeba odczekać)
        for cfg in SharedStore.limits {
            SharedStore.setState(LimitState(day: SharedStore.dayKey()), cfg.id)
            applyShield(cfg)
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let day = SharedStore.dayKey()
        if !SharedStore.exceededDays.contains(day) {
            var days = SharedStore.activeDays
            days.insert(day)
            SharedStore.activeDays = days
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name,
                                         activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let parts = event.rawValue.split(separator: "|").map(String.init)

        if parts.first == "L", parts.count == 3, let k = Int(parts[2]) {
            guard let cfg = SharedStore.limits.first(where: { $0.id == parts[1] }) else { return }
            var st = SharedStore.state(cfg.id)
            guard k > st.sessionsUsed else { return }
            st.sessionsUsed = k
            st.unlocked = false
            st.waitStartedAt = nil
            if k >= cfg.totalSessions { st.dailyReached = true }
            SharedStore.setState(st, cfg.id)
            applyShield(cfg)
            sendNotification(
                st.dailyReached ? "Limit wykorzystany" : "Sesja zakończona",
                st.dailyReached
                    ? "Na dziś koniec. Twoje życie dzieje się teraz."
                    : "Zostało sesji: \(cfg.totalSessions - k).")
        } else if parts.first == "D", parts.count == 2, let p = Int(parts[1]) {
            if p >= 100 {
                var ex = SharedStore.exceededDays
                ex.insert(SharedStore.dayKey())
                SharedStore.exceededDays = ex
            }
            sendNotification("beOFFline", "Wykorzystano \(p)% dziennego limitu.")
        }
    }
}