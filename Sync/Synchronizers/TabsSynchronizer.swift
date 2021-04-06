/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage

import SwiftyJSON


let TabsStorageVersion = 1

open class TabsSynchronizer: TimestampedSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, basePrefs: Prefs, why: SyncReason) {
        super.init(scratchpad: scratchpad, basePrefs: basePrefs, why: why, collection: "tabs")
    }

    override var storageVersion: Int {
        return TabsStorageVersion
    }

    /**
     * This is a dedicated resetting interface that does both tabs and clients at the
     * same time.
     */
    public static func resetClientsAndTabsWithStorage(_ storage: ResettableSyncStorage, basePrefs: Prefs) -> Success {
        let clientPrefs = BaseCollectionSynchronizer.prefsForCollection("clients", withBasePrefs: basePrefs)
        let tabsPrefs = BaseCollectionSynchronizer.prefsForCollection("tabs", withBasePrefs: basePrefs)
        clientPrefs.removeObjectForKey("lastFetched")
        tabsPrefs.removeObjectForKey("lastFetched")
        return storage.resetClient()
    }
}

extension RemoteTab {
    public func toDictionary() -> Dictionary<String, Any>? {
        let tabHistory = history.compactMap { $0.absoluteString }
        if tabHistory.isEmpty {
            return nil
        }
        return [
            "title": title,
            "icon": icon?.absoluteString as Any? ?? NSNull(),
            "urlHistory": tabHistory,
            "lastUsed": millisecondsToDecimalSeconds(lastUsed)
        ]
    }
}
