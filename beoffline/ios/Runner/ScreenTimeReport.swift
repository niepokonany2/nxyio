import Flutter
import SwiftUI
import FamilyControls
import DeviceActivity

// Rejestracja widoku dla Fluttera
class ScreenTimeReportFactory: NSObject, FlutterPlatformViewFactory {
  private var messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    return ScreenTimeReportWrapper(frame: frame, args: args)
  }
}

class ScreenTimeReportWrapper: NSObject, FlutterPlatformView {
  let hostingController: UIHostingController<AnyView>
  
  init(frame: CGRect, args: Any?) {
    let dict = args as? [String: Any]
    let kind = dict?["kind"] as? String ?? "today"
    
    // Tworzymy widok SwiftUI który wyświetli raport Apple
    let view = ReportView(kind: kind)
    hostingController = UIHostingController(rootView: AnyView(view))
    
    super.init()
    hostingController.view.frame = frame
  }
  
  func view() -> UIView {
    return hostingController.view
  }
}

// To jest wbudowany widok Apple do raportów czasu ekranu
@available(iOS 16.0, *)
struct ReportView: View {
  let kind: String
  
  var body: some View {
    DeviceActivityReport(
      DeviceActivityReport.Context(rawValue: kind),
      filter: DeviceActivityFilter()
    )
  }
}