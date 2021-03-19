/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

import SwiftyJSON
import Shared


//private let ServerURL = "https://incoming.telemetry.mozilla.org".asURL!
private let AppName = "Fennec"

//public enum TelemetryDocType: String {
//    case core = "core"
//    case sync = "sync"
//}

public protocol SyncTelemetryEvent {
    func record(_ prefs: Prefs)
}

open class SyncTelemetry {
    private static var prefs: Prefs?
    private static var telemetryVersion: Int = 4

    open class func initWithPrefs(_ prefs: Prefs) {
        assert(self.prefs == nil, "Prefs already initialized")
        self.prefs = prefs
    }

    open class func recordEvent(_ event: SyncTelemetryEvent) {
        guard let prefs = prefs else {
            assertionFailure("Prefs not initialized")
            return
        }

        event.record(prefs)
    }


}

public protocol SyncTelemetryPing {
    var payload: JSON { get }
}
