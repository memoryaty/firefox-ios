/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared



public let TopSiteCacheSize: Int32 = 16

private var ignoredSchemes = ["about"]

public func isIgnoredURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme else { return false }

    if let _ = ignoredSchemes.firstIndex(of: scheme) {
        return true
    }

    if url.host == "localhost" {
        return true
    }

    return false
}

public func isIgnoredURL(_ url: String) -> Bool {
    if let url = URL(string: url) {
        return isIgnoredURL(url)
    }

    return false
}

/*
// Here's the Swift equivalent of the below.
func simulatedFrecency(now: MicrosecondTimestamp, then: MicrosecondTimestamp, visitCount: Int) -> Double {
    let ageMicroseconds = (now - then)
    let ageDays = Double(ageMicroseconds) / 86400000000.0         // In SQL the .0 does the coercion.
    let f = 100 * 225 / ((ageSeconds * ageSeconds) + 225)
    return Double(visitCount) * max(1.0, f)
}
*/

// The constants in these functions were arrived at by utterly unscientific experimentation.

func getRemoteFrecencySQL() -> String {
    let visitCountExpression = "remoteVisitCount"
    let now = Date.nowMicroseconds()
    let microsecondsPerDay = 86_400_000_000.0      // 1000 * 1000 * 60 * 60 * 24
    let ageDays = "((\(now) - remoteVisitDate) / \(microsecondsPerDay))"

    return "\(visitCountExpression) * max(1, 100 * 110 / (\(ageDays) * \(ageDays) + 110))"
}

func getLocalFrecencySQL() -> String {
    let visitCountExpression = "((2 + localVisitCount) * (2 + localVisitCount))"
    let now = Date.nowMicroseconds()
    let microsecondsPerDay = 86_400_000_000.0      // 1000 * 1000 * 60 * 60 * 24
    let ageDays = "((\(now) - localVisitDate) / \(microsecondsPerDay))"

    return "\(visitCountExpression) * max(2, 100 * 225 / (\(ageDays) * \(ageDays) + 225))"
}

fileprivate func escapeFTSSearchString(_ search: String) -> String {
    // Remove double-quotes, split search string on whitespace
    // and remove any empty strings
    let words = search.replacingOccurrences(of: "\"", with: "").components(separatedBy: .whitespaces).filter({ !$0.isEmpty })

    // If there's only one word, ensure it is longer than 2
    // characters. Otherwise, form a different type of search
    // string to attempt to match the start of URLs.
    guard words.count > 1 else {
        guard let word = words.first else {
            return ""
        }

        let charThresholdForSearchAll = 2
        if word.count > charThresholdForSearchAll {
            return "\"\(word)*\""
        } else {
            let titlePrefix = "title: \"^"
            let httpPrefix = "url: \"^http://"
            let httpsPrefix = "url: \"^https://"

            return [titlePrefix,
                    httpPrefix,
                    httpsPrefix,
                    httpPrefix + "www.",
                    httpsPrefix + "www.",
                    httpPrefix + "m.",
                    httpsPrefix + "m."]
                .map({ "\($0)\(word)*\"" })
                .joined(separator: " OR ")
        }
    }

    // Remove empty strings, wrap each word in double-quotes, append
    // "*", then join it all back together. For words with fewer than
    // three characters, anchor the search to the beginning of word
    // bounds by prepending "^".
    // Example: "foo bar a b" -> "\"foo*\"\"bar*\"\"^a*\"\"^b*\""
    return words.map({ "\"\($0)*\"" }).joined()
}

extension SDRow {
    func getTimestamp(_ column: String) -> Timestamp? {
        return (self[column] as? NSNumber)?.uint64Value
    }

    func getBoolean(_ column: String) -> Bool {
        if let val = self[column] as? Int {
            return val != 0
        }
        return false
    }
}

/**
 * The sqlite-backed implementation of the history protocol.
 */
open class SQLiteHistory {
    let db: BrowserDB
    let favicons: SQLiteFavicons
    let prefs: Prefs
    let clearTopSitesQuery: (String, Args?) = ("DELETE FROM cached_top_sites", nil)

    required public init(db: BrowserDB, prefs: Prefs) {
        self.db = db
        self.favicons = SQLiteFavicons(db: self.db)
        self.prefs = prefs
    }

    public func getSites(forURLs urls: [String]) -> Deferred<Maybe<Cursor<Site?>>> {
        let inExpression = urls.joined(separator: "\",\"")
        let sql = """
        SELECT history.id AS historyID, history.url AS url, title, guid, iconID, iconURL, iconDate, iconType, iconWidth
        FROM view_favicons_widest, history
        WHERE history.id = siteID AND history.url IN (\"\(inExpression)\")
        """

        let args: Args = []
        return db.runQueryConcurrently(sql, args: args, factory: SQLiteHistory.iconHistoryColumnFactory)
    }
}

private let topSitesQuery = "SELECT cached_top_sites.*, page_metadata.provider_name FROM cached_top_sites LEFT OUTER JOIN page_metadata ON cached_top_sites.url = page_metadata.site_url ORDER BY frecencies DESC LIMIT (?)"

/**
 * The init for this will perform the heaviest part of the frecency query
 * and create a temporary table that can be queried quickly. Currently this accounts for
 * >75% of the query time.
 * The scope/lifetime of this object is important as the data is 'frozen' until a new instance is created.
 */
fileprivate struct SQLiteFrecentHistory: FrecentHistory {
    private let db: BrowserDB
    private let prefs: Prefs

    init(db: BrowserDB, prefs: Prefs) {
        self.db = db
        self.prefs = prefs

        let empty = "DELETE FROM \(MatViewAwesomebarBookmarksWithFavicons)"

        let insert = """
            INSERT INTO \(MatViewAwesomebarBookmarksWithFavicons)
            SELECT
                guid, url, title, description, visitDate,
                iconID, iconURL, iconDate, iconType, iconWidth
            FROM \(ViewAwesomebarBookmarksWithFavicons)
            """

        _ = db.transaction { connection in
            try connection.executeChange(empty)
            try connection.executeChange(insert)
        }
    }

    func getSites(matchingSearchQuery filter: String?, limit: Int) -> Deferred<Maybe<Cursor<Site>>> {
        let factory = SQLiteHistory.iconHistoryColumnFactory

        let params = FrecencyQueryParams.urlCompletion(whereURLContains: filter ?? "", groupClause: "GROUP BY historyID ")
        let (query, args) = getFrecencyQuery(limit: limit, params: params)

        return db.runQueryConcurrently(query, args: args, factory: factory)
    }

    fileprivate func updateTopSitesCacheQuery() -> (String, Args?) {
        let limit = Int(prefs.intForKey(PrefsKeys.KeyTopSitesCacheSize) ?? TopSiteCacheSize)
        let (topSitesQuery, args) = getTopSitesQuery(historyLimit: limit)

        let insertQuery = """
            WITH siteFrecency AS (\(topSitesQuery))
            INSERT INTO cached_top_sites
            SELECT
                historyID, url, title, guid, domain_id, domain,
                localVisitDate, remoteVisitDate, localVisitCount, remoteVisitCount,
                iconID, iconURL, iconDate, iconType, iconWidth, frecencies
            FROM siteFrecency LEFT JOIN view_favicons_widest ON
                siteFrecency.historyID = view_favicons_widest.siteID
            """

        return (insertQuery, args)
    }

    private func topSiteClauses() -> (String, String) {
        let whereData = "(domains.showOnTopSites IS 1) AND (domains.domain NOT LIKE 'r.%') AND (domains.domain NOT LIKE 'google.%') "
        let groupBy = "GROUP BY domain_id "
        return (whereData, groupBy)
    }

    enum FrecencyQueryParams {
        case urlCompletion(whereURLContains: String, groupClause: String)
        case topSites(groupClause: String, whereData: String)
    }

    private func getFrecencyQuery(limit: Int, params: FrecencyQueryParams) -> (String, Args?) {
        let groupClause: String
        let whereData: String?
        let urlFilter: String?

        switch params {
        case let .urlCompletion(filter, group):
            urlFilter = filter
            groupClause = group
            whereData = nil
        case let .topSites(group, whereArg):
            urlFilter = nil
            whereData = whereArg
            groupClause = group
        }

        let localFrecencySQL = getLocalFrecencySQL()
        let remoteFrecencySQL = getRemoteFrecencySQL()
        let sixMonthsInMicroseconds: UInt64 = 15_724_800_000_000      // 182 * 1000 * 1000 * 60 * 60 * 24
        let sixMonthsAgo = Date.nowMicroseconds() - sixMonthsInMicroseconds

        let args: Args
        let ftsWhereClause: String
        let whereFragment = (whereData == nil) ? "" : " AND (\(whereData!))"

        if let urlFilter = urlFilter?.trimmingCharacters(in: .whitespaces), !urlFilter.isEmpty {
            // No deleted item has a URL, so there is no need to explicitly add that here.
            ftsWhereClause = " WHERE (history_fts MATCH ?)\(whereFragment)"
            args = [escapeFTSSearchString(urlFilter)]
        } else {
            ftsWhereClause = " WHERE (history.is_deleted = 0)\(whereFragment)"
            args = []
        }

        // Innermost: grab history items and basic visit/domain metadata.
        let ungroupedSQL = """
            SELECT history.id AS historyID, history.url AS url,
                history.title AS title, history.guid AS guid, domain_id, domain,
                coalesce(max(CASE visits.is_local WHEN 1 THEN visits.date ELSE 0 END), 0) AS localVisitDate,
                coalesce(max(CASE visits.is_local WHEN 0 THEN visits.date ELSE 0 END), 0) AS remoteVisitDate,
                coalesce(sum(visits.is_local), 0) AS localVisitCount,
                coalesce(sum(CASE visits.is_local WHEN 1 THEN 0 ELSE 1 END), 0) AS remoteVisitCount
            FROM history
                INNER JOIN domains ON
                    domains.id = history.domain_id
                INNER JOIN visits ON
                    visits.siteID = history.id
                INNER JOIN history_fts ON
                    history_fts.rowid = history.rowid
            \(ftsWhereClause)
            GROUP BY historyID
            """

        // Next: limit to only those that have been visited at all within the last six months.
        // (Don't do that in the innermost: we want to get the full count, even if some visits are older.)
        // Discard all but the 1000 most frecent.
        // Compute and return the frecency for all 1000 URLs.
        let frecenciedSQL = """
            SELECT *, (\(localFrecencySQL) + \(remoteFrecencySQL)) AS frecency
            FROM (\(ungroupedSQL))
            WHERE (
                -- Eliminate dead rows from coalescing.
                ((localVisitCount > 0) OR (remoteVisitCount > 0)) AND
                -- Exclude really old items.
                ((localVisitDate > \(sixMonthsAgo)) OR (remoteVisitDate > \(sixMonthsAgo)))
            )
            ORDER BY frecency DESC
            -- Don't even look at a huge set. This avoids work.
            LIMIT 1000
            """

        // Next: merge by domain and select the URL with the max frecency of a domain, ordering by that sum frecency and reducing to a (typically much lower) limit.
        // NOTE: When using GROUP BY we need to be explicit about which URL to use when grouping. By using "max(frecency)" the result row
        //       for that domain will contain the projected URL corresponding to the history item with the max frecency, https://sqlite.org/lang_select.html#resultset
        //       This is the behavior we want in order to ensure that the most popular URL for a domain is used for the top sites tile.
        // TODO: make is_bookmarked here accurate by joining against ViewAllBookmarks.
        // TODO: ensure that the same URL doesn't appear twice in the list, either from duplicate
        //       bookmarks or from being in both bookmarks and history.
        let historySQL = """
            SELECT historyID, url, title, guid, domain_id, domain,
                max(localVisitDate) AS localVisitDate,
                max(remoteVisitDate) AS remoteVisitDate,
                sum(localVisitCount) AS localVisitCount,
                sum(remoteVisitCount) AS remoteVisitCount,
                max(frecency) AS maxFrecency,
                sum(frecency) AS frecencies,
                0 AS is_bookmarked
            FROM (\(frecenciedSQL))
            \(groupClause)
            ORDER BY frecencies DESC
            LIMIT \(limit)
            """

        let allSQL = """
            SELECT * FROM (\(historySQL)) AS hb
            LEFT OUTER JOIN view_favicons_widest ON view_favicons_widest.siteID = hb.historyID
            ORDER BY is_bookmarked DESC, frecencies DESC
            """
        return (allSQL, args)
    }

    private func getTopSitesQuery(historyLimit: Int) -> (String, Args?) {
        let localFrecencySQL = getLocalFrecencySQL()
        let remoteFrecencySQL = getRemoteFrecencySQL()

        // Innermost: grab history items and basic visit/domain metadata.
        let ungroupedSQL = """
            SELECT history.id AS historyID, history.url AS url,
                history.title AS title, history.guid AS guid, domain_id, domain,
                coalesce(max(CASE visits.is_local WHEN 1 THEN visits.date ELSE 0 END), 0) AS localVisitDate,
                coalesce(max(CASE visits.is_local WHEN 0 THEN visits.date ELSE 0 END), 0) AS remoteVisitDate,
                coalesce(sum(visits.is_local), 0) AS localVisitCount,
                coalesce(sum(CASE visits.is_local WHEN 1 THEN 0 ELSE 1 END), 0) AS remoteVisitCount
            FROM history
                INNER JOIN (
                    SELECT siteID FROM (
                        SELECT COUNT(rowid) AS visitCount, siteID
                        FROM visits
                        GROUP BY siteID
                        ORDER BY visitCount DESC
                        LIMIT 5000
                    )
                    UNION ALL
                    SELECT siteID FROM (
                        SELECT siteID
                        FROM visits
                        GROUP BY siteID
                        ORDER BY max(date) DESC
                        LIMIT 1000
                    )
                ) AS groupedVisits ON
                    groupedVisits.siteID = history.id
                INNER JOIN domains ON
                    domains.id = history.domain_id
                INNER JOIN visits ON
                    visits.siteID = history.id
            WHERE (history.is_deleted = 0) AND ((domains.showOnTopSites IS 1) AND (domains.domain NOT LIKE 'r.%') AND (domains.domain NOT LIKE 'google.%')) AND (history.url LIKE 'http%')
            GROUP BY historyID
            """

        let frecenciedSQL = """
            SELECT *, (\(localFrecencySQL) + \(remoteFrecencySQL)) AS frecency
            FROM (\(ungroupedSQL))
            """

        let historySQL = """
            SELECT historyID, url, title, guid, domain_id, domain,
                max(localVisitDate) AS localVisitDate,
                max(remoteVisitDate) AS remoteVisitDate,
                sum(localVisitCount) AS localVisitCount,
                sum(remoteVisitCount) AS remoteVisitCount,
                max(frecency) AS maxFrecency,
                sum(frecency) AS frecencies,
                0 AS is_bookmarked
            FROM (\(frecenciedSQL))
            GROUP BY domain_id
            ORDER BY frecencies DESC
            LIMIT \(historyLimit)
            """

        return (historySQL, nil)
    }
}

extension SQLiteHistory: BrowserHistory {
    public func removeSiteFromTopSites(_ site: Site) -> Success {
        if let host = (site.url as String).asURL?.normalizedHost {
            return self.removeHostFromTopSites(host)
        }
        return deferMaybe(DatabaseError(description: "Invalid url for site \(site.url)"))
    }

    public func removeFromPinnedTopSites(_ site: Site) -> Success {
        guard let host = (site.url as String).asURL?.normalizedHost else {
            return deferMaybe(DatabaseError(description: "Invalid url for site \(site.url)"))
        }

        //do a fuzzy delete so dupes can be removed
        let query: (String, Args?) = ("DELETE FROM pinned_top_sites where domain = ?", [host])
        return db.run([query]) >>== {
            return self.db.run([("UPDATE domains SET showOnTopSites = 1 WHERE domain = ?", [host])])
        }
    }

    public func isPinnedTopSite(_ url: String) -> Deferred<Maybe<Bool>> {
        let sql = """
        SELECT * FROM pinned_top_sites
        WHERE url = ?
        LIMIT 1
        """
        let args: Args = [url]
        return self.db.queryReturnsResults(sql, args: args)
    }

    public func getPinnedTopSites() -> Deferred<Maybe<Cursor<Site>>> {
        let sql = """
            SELECT * FROM pinned_top_sites LEFT OUTER JOIN view_favicons_widest ON
                historyID = view_favicons_widest.siteID
            ORDER BY pinDate DESC
            """
        return db.runQueryConcurrently(sql, args: [], factory: SQLiteHistory.iconHistoryMetadataColumnFactory)
    }

    public func addPinnedTopSite(_ site: Site) -> Success { // needs test
        let now = Date.now()
        guard let guid = site.guid, let host = (site.url as String).asURL?.normalizedHost else {
            return deferMaybe(DatabaseError(description: "Invalid site \(site.url)"))
        }

        let args: Args = [site.url, now, site.title, site.id, guid, host]
        let arglist = BrowserDB.varlist(args.count)
        // Prevent the pinned site from being used in topsite calculations
        // We dont have to worry about this when removing a pin because the assumption is that a user probably doesnt want it being recommended as a topsite either
        return self.removeHostFromTopSites(host) >>== {
            return self.db.run([("INSERT OR REPLACE INTO pinned_top_sites (url, pinDate, title, historyID, guid, domain) VALUES \(arglist)", args)])
        }
    }

    public func removeHostFromTopSites(_ host: String) -> Success {
        return db.run([("UPDATE domains SET showOnTopSites = 0 WHERE domain = ?", [host])])
    }

    public func removeHistoryForURL(_ url: String) -> Success {
        let visitArgs: Args = [url]
        let deleteVisits = "DELETE FROM visits WHERE siteID = (SELECT id FROM history WHERE url = ?)"

        let markArgs: Args = [Date.nowNumber(), url]
        let markDeleted = "UPDATE history SET url = NULL, is_deleted = 1, title = '', should_upload = 1, local_modified = ? WHERE url = ?"

        return db.run([
            (sql: deleteVisits, args: visitArgs),
            (sql: markDeleted, args: markArgs),
            favicons.getCleanupFaviconsQuery(),
            favicons.getCleanupFaviconSiteURLsQuery()
        ])
    }

    public func removeHistoryFromDate(_ date: Date) -> Success {
        let visitTimestamp = date.toMicrosecondTimestamp()

        let historyRemoval = """
            WITH deletionIds as (SELECT history.id from history INNER JOIN visits on history.id = visits.siteID WHERE visits.date > ?)
            UPDATE history SET url = NULL, is_deleted=1, title = '', should_upload = 1, local_modified = ?
            WHERE history.id in deletionIds
        """
        let historyRemovalArgs: Args = [visitTimestamp, Date.nowNumber()]

        let visitRemoval = "DELETE FROM visits WHERE visits.date > ?"
        let visitRemovalArgs: Args = [visitTimestamp]

        return db.run([
            (sql: historyRemoval, args: historyRemovalArgs),
            (sql: visitRemoval, args: visitRemovalArgs),
            favicons.getCleanupFaviconsQuery(),
            favicons.getCleanupFaviconSiteURLsQuery()
        ])
    }

    // Note: clearing history isn't really a sane concept in the presence of Sync.
    // This method should be split to do something else.
    // Bug 1162778.
    public func clearHistory() -> Success {
        return self.db.run([
            ("DELETE FROM visits", nil),
            ("DELETE FROM history", nil),
            ("DELETE FROM domains", nil),
            ("DELETE FROM page_metadata", nil),
            ("DELETE FROM favicon_site_urls", nil),
            ("DELETE FROM favicons", nil),
            ])
            // We've probably deleted a lot of stuff. Vacuum now to recover the space.
            >>> effect({ self.db.vacuum() })
    }

    func recordVisitedSite(_ site: Site) -> Success {
        // Don't store visits to sites with about: protocols
        if isIgnoredURL(site.url as String) {
            return deferMaybe(IgnoredSiteError())
        }

        return db.withConnection { conn -> Void in
            let now = Date.now()

            if self.updateSite(site, atTime: now, withConnection: conn) > 0 {
                return
            }

            // Insert instead.
            if self.insertSite(site, atTime: now, withConnection: conn) > 0 {
                return
            }

            let err = DatabaseError(description: "Unable to update or insert site; Invalid key returned")
            //log.error("recordVisitedSite encountered an error: \(err.localizedDescription)")
            throw err
        }
    }

    func updateSite(_ site: Site, atTime time: Timestamp, withConnection conn: SQLiteDBConnection) -> Int {
        // We know we're adding a new visit, so we'll need to upload this record.
        // If we ever switch to per-visit change flags, this should turn into a CASE statement like
        //   CASE WHEN title IS ? THEN max(should_upload, 1) ELSE should_upload END
        // so that we don't flag this as changed unless the title changed.
        //
        // Note that we will never match against a deleted item, because deleted items have no URL,
        // so we don't need to unset is_deleted here.
        guard let host = (site.url as String).asURL?.normalizedHost else {
            return 0
        }

        let update = "UPDATE history SET title = ?, local_modified = ?, should_upload = 1, domain_id = (SELECT id FROM domains where domain = ?) WHERE url = ?"
        let updateArgs: Args? = [site.title, time, host, site.url]

        do {
            try conn.executeChange(update, withArgs: updateArgs)
            return conn.numberOfRowsModified
        } catch let error as NSError {
            //log.warning("Update failed with error: \(error.localizedDescription)")
            return 0
        }
    }

    fileprivate func insertSite(_ site: Site, atTime time: Timestamp, withConnection conn: SQLiteDBConnection) -> Int {
        if let host = (site.url as String).asURL?.normalizedHost {
            do {
                try conn.executeChange("INSERT OR IGNORE INTO domains (domain) VALUES (?)", withArgs: [host])
            } catch let error as NSError {
                //log.warning("Domain insertion failed with \(error.localizedDescription)")
                return 0
            }

            let insert = """
                INSERT INTO history (
                    guid, url, title, local_modified, is_deleted, should_upload, domain_id
                )
                SELECT ?, ?, ?, ?, 0, 1, id FROM domains WHERE domain = ?
                """

            let insertArgs: Args? = [site.guid ?? Bytes.generateGUID(), site.url, site.title, time, host]
            do {
                try conn.executeChange(insert, withArgs: insertArgs)
            } catch let error as NSError {
                //log.warning("Site insertion failed with \(error.localizedDescription)")
                return 0
            }

            return 1
        }


        return 0
    }

    // TODO: thread siteID into this to avoid the need to do the lookup.
    func addLocalVisitForExistingSite(_ visit: SiteVisit) -> Success {
        return db.withConnection { conn -> Void in
            // INSERT OR IGNORE because we *might* have a clock error that causes a timestamp
            // collision with an existing visit, and it would really suck to error out for that reason.
            let insert = """
                INSERT OR IGNORE INTO visits (
                    siteID, date, type, is_local
                ) VALUES (
                    (SELECT id FROM history WHERE url = ?), ?, ?, 1
                )
                """

            let realDate = visit.date
            let insertArgs: Args? = [visit.site.url, realDate, visit.type.rawValue]

            try conn.executeChange(insert, withArgs: insertArgs)
        }
    }

    public func addLocalVisit(_ visit: SiteVisit) -> Success {
        return recordVisitedSite(visit.site)
         >>> { self.addLocalVisitForExistingSite(visit) }
    }

    public func getFrecentHistory() -> FrecentHistory {
        return SQLiteFrecentHistory(db: db, prefs: prefs)
    }

    public func getTopSitesWithLimit(_ limit: Int) -> Deferred<Maybe<Cursor<Site>>> {
        return self.db.runQueryConcurrently(topSitesQuery, args: [limit], factory: SQLiteHistory.iconHistoryMetadataColumnFactory)
    }

    public func setTopSitesNeedsInvalidation() {
        prefs.setBool(false, forKey: PrefsKeys.KeyTopSitesCacheIsValid)
    }

    public func setTopSitesCacheSize(_ size: Int32) {
        let oldValue = prefs.intForKey(PrefsKeys.KeyTopSitesCacheSize) ?? 0
        if oldValue != size {
            prefs.setInt(size, forKey: PrefsKeys.KeyTopSitesCacheSize)
            setTopSitesNeedsInvalidation()
        }
    }

    public func refreshTopSitesQuery() -> [(String, Args?)] {
        return [clearTopSitesQuery, getFrecentHistory().updateTopSitesCacheQuery()]
    }

    public func clearTopSitesCache() -> Success {
        return self.db.run([clearTopSitesQuery]) >>> {
            self.prefs.removeObjectForKey(PrefsKeys.KeyTopSitesCacheIsValid)
            return succeed()
        }
    }

    public func getSitesByLastVisit(limit: Int, offset: Int) -> Deferred<Maybe<Cursor<Site>>> {
        let sql = """
            SELECT
                history.id AS historyID, history.url, title, guid, domain_id, domain,
                coalesce(max(CASE visits.is_local WHEN 1 THEN visits.date ELSE 0 END), 0) AS localVisitDate,
                coalesce(max(CASE visits.is_local WHEN 0 THEN visits.date ELSE 0 END), 0) AS remoteVisitDate,
                coalesce(count(visits.is_local), 0) AS visitCount
                , iconID, iconURL, iconDate, iconType, iconWidth
            FROM history
                INNER JOIN (
                    SELECT siteID, max(date) AS latestVisitDate
                    FROM visits
                    GROUP BY siteID
                    ORDER BY latestVisitDate DESC
                    LIMIT \(limit)
                    OFFSET \(offset)
                ) AS latestVisits ON
                    latestVisits.siteID = history.id
                INNER JOIN domains ON domains.id = history.domain_id
                INNER JOIN visits ON visits.siteID = history.id
                LEFT OUTER JOIN view_favicons_widest ON view_favicons_widest.siteID = history.id
            WHERE (history.is_deleted = 0)
            GROUP BY history.id
            ORDER BY latestVisits.latestVisitDate DESC
            """

        return db.runQueryConcurrently(sql, args: nil, factory: SQLiteHistory.iconHistoryColumnFactory)
    }
}
