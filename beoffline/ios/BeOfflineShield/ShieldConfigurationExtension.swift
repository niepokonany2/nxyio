import ManagedSettings
import ManagedSettingsUI
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        build(application.token.flatMap { SharedStore.limit(containing: $0) })
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        build(application.token.flatMap { SharedStore.limit(containing: $0) }
              ?? category.token.flatMap { SharedStore.limit(containingCategory: $0) })
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        build(webDomain.token.flatMap { SharedStore.limit(containingDomain: $0) })
    }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        build(webDomain.token.flatMap { SharedStore.limit(containingDomain: $0) }
              ?? category.token.flatMap { SharedStore.limit(containingCategory: $0) })
    }

    private func make(_ title: String, _ subtitle: String,
                      _ primary: String, _ secondary: String?) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            title: .init(text: title, color: .label),
            subtitle: .init(text: subtitle, color: .secondaryLabel),
            primaryButtonLabel: .init(text: primary, color: .systemBackground),
            primaryButtonBackgroundColor: .label,
            secondaryButtonLabel: secondary.map { .init(text: $0, color: .label) })
    }

    private func build(_ cfg: LimitConfig?) -> ShieldConfiguration {
        guard let cfg else {
            return make("beOFFline", "Ta aplikacja jest ograniczona.", "Zamknij", nil)
        }
        let st = SharedStore.state(cfg.id)
        let remaining = max(0, cfg.totalSessions - st.sessionsUsed)

        if st.dailyReached || remaining == 0 {
            return make("Limit na dziś wykorzystany",
                        "Wróć jutro. Telefon może poczekać.", "Zamknij", nil)
        }
        if let start = st.waitStartedAt {
            let left = cfg.waitSeconds - Int(Date().timeIntervalSince(start))
            if left > 0 {
                return make("Poczekaj jeszcze \(left) s",
                            "Weź oddech. Potem naciśnij przycisk ponownie.",
                            "Sprawdź ponownie", "Zamknij")
            }
            return make("Możesz wejść",
                        "Sesja: \(cfg.sessionMinutes) min. Zostało sesji: \(remaining).",
                        "Rozpocznij sesję", "Zamknij")
        }
        return make("Chcesz otworzyć tę aplikację?",
                    "Pozostało sesji: \(remaining) z \(cfg.totalSessions)."
                        + (cfg.waitSeconds > 0 ? " Najpierw odczekasz \(cfg.waitSeconds) s." : ""),
                    cfg.waitSeconds > 0 ? "Zacznij odliczanie" : "Rozpocznij sesję",
                    "Zamknij")
    }
}