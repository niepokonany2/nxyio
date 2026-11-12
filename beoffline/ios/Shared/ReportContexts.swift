import DeviceActivity
import SwiftUI

extension DeviceActivityReport.Context {
    static let today = Self("today")
    static let topApps = Self("topApps")
    static let allTime = Self("allTime")
    static let week = Self("week")
    static let limit = Self("limit")
}