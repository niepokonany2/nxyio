import ManagedSettings
import Foundation

class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(process(action, SharedStore.limit(containing: application)))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(process(action, SharedStore.limit(containingDomain: webDomain)))
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(process(action, SharedStore.limit(containingCategory: category)))
    }

    private func process(_ action: ShieldAction, _ cfg: LimitConfig?) -> ShieldActionResponse {
        guard action == .primaryButtonPressed, let cfg else { return .close }
        var st = SharedStore.state(cfg.id)
        if st.dailyReached || st.sessionsUsed >= cfg.totalSessions { return .close }

        func unlock() -> ShieldActionResponse {
            st.unlocked = true
            st.waitStartedAt = nil
            SharedStore.setState(st, cfg.id)
            removeShield(cfg.id)
            return .defer
        }

        if cfg.waitSeconds == 0 { return unlock() }
        if let start = st.waitStartedAt {
            return Date().timeIntervalSince(start) >= Double(cfg.waitSeconds) ? unlock() : .defer
        }
        st.waitStartedAt = Date()
        SharedStore.setState(st, cfg.id)
        return .defer
    }
}