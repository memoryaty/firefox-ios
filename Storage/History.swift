/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared

open class IgnoredSiteError: MaybeErrorType {
    open var description: String {
        return "Ignored site."
    }
}

/**
 * The base history protocol for front-end code.
 *
 * Note that the implementation of these methods might be complicated if
 * the implementing class also implements SyncableHistory -- for example,
 * `clear` might or might not need to set a bunch of flags to upload deletions.
 */
public protocol BrowserHistory {
    @discardableResult func addLocalVisit(_ visit: SiteVisit) -> Success
    func clearHistory() -> Success
    @discardableResult func removeHistoryForURL(_ url: String) -> Success
    func removeHistoryFromDate(_ date: Date) -> Success
    func removeSiteFromTopSites(_ site: Site) -> Success
    func removeHostFromTopSites(_ host: String) -> Success
    func getFrecentHistory() -> FrecentHistory
    func getSitesByLastVisit(limit: Int, offset: Int) -> Deferred<Maybe<Cursor<Site>>>
    func getTopSitesWithLimit(_ limit: Int) -> Deferred<Maybe<Cursor<Site>>>
    func setTopSitesNeedsInvalidation()
    func setTopSitesCacheSize(_ size: Int32)
    func clearTopSitesCache() -> Success

    // Pinning top sites
    func removeFromPinnedTopSites(_ site: Site) -> Success
    func addPinnedTopSite(_ site: Site) -> Success
    func getPinnedTopSites() -> Deferred<Maybe<Cursor<Site>>>
    func isPinnedTopSite(_ url: String) -> Deferred<Maybe<Bool>>
}

/**
 * An interface for fast repeated frecency queries.
 */
public protocol FrecentHistory {
    func getSites(matchingSearchQuery filter: String?, limit: Int) -> Deferred<Maybe<Cursor<Site>>>
    func updateTopSitesCacheQuery() -> (String, Args?)
}

/**
 * An interface for accessing recommendation content from Storage
 */
public protocol HistoryRecommendations {
    func cleanupHistoryIfNeeded()
    func repopulate(invalidateTopSites shouldInvalidateTopSites: Bool) -> Success
}

// TODO: integrate Site with this.

//open class Place {
//    public let guid: GUID
//    public let url: String
//    public let title: String
//
//    public init(guid: GUID, url: String, title: String) {
//        self.guid = guid
//        self.url = url
//        self.title = title
//    }
//}
