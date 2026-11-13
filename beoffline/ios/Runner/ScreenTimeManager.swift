import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftUI

@available(iOS 16.0, *)
class ScreenTimeManager: ObservableObject {
  static let shared = ScreenTimeManager()
  private let store = ManagedSettingsStore()
  
  // Grupa App Group musi być utworzona w Xcode (np. group.pl.beoffline.app)
  private let appGroup = "group.pl.beoffline.app"
  private var userDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
  
  private let selectionKey = "deviceSelection"
  
  var hasDeviceSelection: Bool {
    return userDefaults?.data(forKey: selectionKey) != nil
  }

  func pickDeviceSelection(completion: @escaping () -> Void) {
    // To jest wywoływane w AppDelegate, ale okno wyboru aplikacji (FamilyActivityPicker)
    // musi być zaprezentowane z UIHostingController na głównym wątku.
  }

  func setDeviceSettings(minutes: Int, notifications: Bool) {
    userDefaults?.set(minutes, forKey: "globalLimitMinutes")
    userDefaults?.set(notifications, forKey: "notificationsEnabled")
  }

  func pickLimitApps(existingId: String?, completion: @escaping (String?) -> Void) {
    let id = existingId ?? UUID().uuidString
    let selection = ScreenTimeStore.getSelection(for: id)
    let picker = FamilyActivityPickerSheet(selection: selection, onSave: { newSelection in
      ScreenTimeStore.saveSelection(newSelection, for: id)
      completion(id)
    })
    let hosting = UIHostingController(rootView: picker)
    UIApplication.shared.windows.first?.rootViewController?.present(hosting, animated: true)
  }

  func saveLimit(id: String, daily: Int, session: Int, wait: Int, result: @escaping FlutterResult) {
    // Zapis do bazy
    userDefaults?.set(["daily": daily, "session": session, "wait": wait], forKey: "limit_\(id)")
    
    // Nakładanie tarczy (blokady) na wybrane aplikacje
    if let selection = ScreenTimeStore.getSelection(for: id) {
      store.shield.applicationCategories = ShieldSettings.ActivityCategoryPolicy.specific(selection.categoryTokens)
      store.shield.applications = selection.applicationTokens
    }

    // Konfiguracja monitorowania w tle (odpala rozszerzenie DeviceActivityMonitor)
    startDeviceActivityMonitoring(id: id, daily: daily, session: session)
    result(nil)
  }

  func removeLimit(id: String) {
    userDefaults?.removeObject(forKey: "limit_\(id)")
    ScreenTimeStore.removeSelection(for: id)
    
    // Wyłączenie tarczy dla usuniętego ID
    DeviceActivityCenter().stopMonitoring([DeviceActivityName(id)])
    store.clearAllSettings() // W uproszczeniu – w produkcji trzeba czyścić tylko to ID
  }

  func getLimits() -> [[String: Any]] {
    // Zwraca dane dla Darta
    var limits: [[String: Any]] = []
    let keys = userDefaults?.dictionaryRepresentation().keys.filter { $0.hasPrefix("limit_") } ?? []
    for key in keys {
      let id = key.replacingOccurrences(of: "limit_", with: "")
      if let data = userDefaults?.dictionary(forKey: key),
         let daily = data["daily"] as? Int,
         let session = data["session"] as? Int,
         let wait = data["wait"] as? Int {
        
        // Pobieranie czasu użycia
        let usage = DeviceActivityCenter().activities.first { $0.rawValue == id }
        
        limits.append([
          "id": id,
          "daily": daily,
          "session": session,
          "wait": wait,
          "apps": 1, // Wartość poglądowa do wyliczenia z tokenów
          "categories": 1,
          "sessionsUsed": 0, 
          "dailyReached": false
        ])
      }
    }
    return limits
  }

  private func startDeviceActivityMonitoring(id: String, daily: Int, session: Int) {
    let schedule = DeviceActivitySchedule(
      intervalStart: DateComponents(hour: 0, minute: 0),
      intervalEnd: DateComponents(hour: 23, minute: 59),
      repeats: true
    )
    do {
      try DeviceActivityCenter().startMonitoring(DeviceActivityName(id), during: schedule)
    } catch {
      print("Monitoring błąd: \(error)")
    }
  }
}

// Pamięć podręczna na wybory użytkownika
@available(iOS 16.0, *)
struct ScreenTimeStore {
  static let key = "saved_selections"
  
  static func getSelection(for id: String) -> FamilyActivitySelection {
    guard let data = UserDefaults.standard.data(forKey: "\(key)_\(id)") else { return FamilyActivitySelection() }
    return (try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)) ?? FamilyActivitySelection()
  }
  
  static func saveSelection(_ selection: FamilyActivitySelection, for id: String) {
    if let data = try? JSONEncoder().encode(selection) {
      UserDefaults.standard.set(data, forKey: "\(key)_\(id)")
    }
  }
  
  static func removeSelection(for id: String) {
    UserDefaults.standard.removeObject(forKey: "\(key)_\(id)")
  }
}

// Widok selektora aplikacji (SwiftUI)
@available(iOS 16.0, *)
struct FamilyActivityPickerSheet: View {
  @State var selection: FamilyActivitySelection
  var onSave: (FamilyActivitySelection) -> Void
  @Environment(\.dismiss) var dismiss

  var body: some View {
    NavigationView {
      FamilyActivityPicker(selection: $selection)
        .navigationTitle("Wybierz aplikacje")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Zapisz") {
              onSave(selection)
              dismiss()
            }
          }
        }
    }
  }
}