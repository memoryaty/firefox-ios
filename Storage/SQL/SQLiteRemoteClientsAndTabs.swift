/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

import SwiftyJSON



open class SQLiteRemoteClientsAndTabs {
    let db: BrowserDB

    public init(db: BrowserDB) {
        self.db = db
    }

    func insert(_ db: SQLiteDBConnection, sql: String, args: Args?) throws -> Int64? {
        let lastID = db.lastInsertedRowID
        try db.executeChange(sql, withArgs: args)

        let id = db.lastInsertedRowID
        if id == lastID {
            //log.debug("INSERT did not change last inserted row ID.")
            return nil
        }

        return id
    }
}

extension SQLiteRemoteClientsAndTabs: ResettableSyncStorage {
    public func resetClient() -> Success {
        // For this engine, resetting is equivalent to wiping.
        return self.clear()
    }

    public func clear() -> Success {
        return db.transaction { conn -> Void in
            try conn.executeChange("DELETE FROM tabs WHERE client_guid IS NOT NULL")
            try conn.executeChange("DELETE FROM clients")
        }
    }
}

