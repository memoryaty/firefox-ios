/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

import SwiftyJSON



open class SQLiteRemoteClientsAndTabs: RemoteClientsAndTabs {
    let db: BrowserDB

    public init(db: BrowserDB) {
        self.db = db
    }

    class func remoteTabFactory(_ row: SDRow) -> RemoteTab {
        let clientGUID = row["client_guid"] as? String
        let url = URL(string: row["url"] as! String)! // TODO: find a way to make this less dangerous.
        let title = row["title"] as! String
        let history = SQLiteRemoteClientsAndTabs.convertStringToHistory(row["history"] as? String)
        let lastUsed = row.getTimestamp("last_used")!
        return RemoteTab(clientGUID: clientGUID, URL: url, title: title, history: history, lastUsed: lastUsed, icon: nil)
    }

    class func convertStringToHistory(_ history: String?) -> [URL] {
        guard let data = history?.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data, options: [JSONSerialization.ReadingOptions.allowFragments]),
            let urlStrings = decoded as? [String] else {
                return []
        }
        return optFilter(urlStrings.compactMap { URL(string: $0) })
    }

    class func convertHistoryToString(_ history: [URL]) -> String? {
        let historyAsStrings = optFilter(history.map { $0.absoluteString })

        guard let data = try? JSONSerialization.data(withJSONObject: historyAsStrings, options: []) else {
            return nil
        }
        return String(data: data, encoding: String.Encoding(rawValue: String.Encoding.utf8.rawValue))
    }

    open func wipeRemoteTabs() -> Success {
        return db.run("DELETE FROM tabs WHERE client_guid IS NOT NULL")
    }

    open func wipeTabs() -> Success {
        return db.run("DELETE FROM tabs")
    }

    open func insertOrUpdateTabs(_ tabs: [RemoteTab]) -> Deferred<Maybe<Int>> {
        return self.insertOrUpdateTabsForClientGUID(nil, tabs: tabs)
    }

    open func insertOrUpdateTabsForClientGUID(_ clientGUID: String?, tabs: [RemoteTab]) -> Deferred<Maybe<Int>> {
        let deleteQuery = "DELETE FROM tabs WHERE client_guid IS ?"
        let deleteArgs: Args = [clientGUID]

        return db.transaction { connection -> Int in
            // Delete any existing tabs.
            try connection.executeChange(deleteQuery, withArgs: deleteArgs)

            // Insert replacement tabs.
            var inserted = 0
            for tab in tabs {
                let args: Args = [
                    tab.clientGUID,
                    tab.URL.absoluteString,
                    tab.title,
                    SQLiteRemoteClientsAndTabs.convertHistoryToString(tab.history),
                    NSNumber(value: tab.lastUsed)
                ]

                let lastInsertedRowID = connection.lastInsertedRowID

                // We trust that each tab's clientGUID matches the supplied client!
                // Really tabs shouldn't have a GUID at all. Future cleanup!
                try connection.executeChange("INSERT INTO tabs (client_guid, url, title, history, last_used) VALUES (?, ?, ?, ?, ?)", withArgs: args)

                if connection.lastInsertedRowID == lastInsertedRowID {
                    //log.debug("Unable to INSERT RemoteTab!")
                } else {
                    inserted += 1
                }
            }

            return inserted
        }
    }

    open func getClientGUIDs() -> Deferred<Maybe<Set<GUID>>> {
        let c = db.runQuery("SELECT guid FROM clients WHERE guid IS NOT NULL", args: nil, factory: { $0["guid"] as! String })
        return c >>== { cursor in
            let guids = Set<GUID>(cursor.asArray())
            return deferMaybe(guids)
        }
    }

    open func getTabsForClientWithGUID(_ guid: GUID?) -> Deferred<Maybe<[RemoteTab]>> {
        let tabsSQL: String
        let clientArgs: Args?
        if let _ = guid {
            tabsSQL = "SELECT * FROM tabs WHERE client_guid = ?"
            clientArgs = [guid]
        } else {
            tabsSQL = "SELECT * FROM tabs WHERE client_guid IS NULL"
            clientArgs = nil
        }

        //log.debug("Looking for tabs for client with guid: \(guid ?? "nil")")
        return db.runQuery(tabsSQL, args: clientArgs, factory: SQLiteRemoteClientsAndTabs.remoteTabFactory) >>== {
            let tabs = $0.asArray()
            //log.debug("Found \(tabs.count) tabs for client with guid: \(guid ?? "nil")")
            return deferMaybe(tabs)
        }
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

