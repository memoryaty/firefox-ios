/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// IMPORTANT!: Please take into consideration when adding new imports to
// this file that it is utilized by external components besides the core
// application (i.e. App Extensions). Introducing new dependencies here
// may have unintended negative consequences for App Extensions such as
// increased startup times which may lead to termination by the OS.
//import Account
import Shared
import Storage
//import Sync

import SwiftKeychainWrapper


// Import these dependencies ONLY for the main `Client` application target.
#if MOZ_TARGET_CLIENT
    import SwiftyJSON
#endif



public let ProfileRemoteTabsSyncDelay: TimeInterval = 0.1

public protocol SyncManager {

    func hasSyncedLogins() -> Deferred<Maybe<Bool>>

}

class ProfileFileAccessor: FileAccessor {
    convenience init(profile: Profile) {
        self.init(localName: profile.localName())
    }

    init(localName: String) {
        let profileDirName = "profile.\(localName)"

        // Bug 1147262: First option is for device, second is for simulator.
        var rootPath: String
        let sharedContainerIdentifier = AppInfo.sharedContainerIdentifier
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier) {
            rootPath = url.path
        } else {
            //log.error("Unable to find the shared container. Defaulting profile location to ~/Documents instead.")
            rootPath = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
        }

        super.init(rootPath: URL(fileURLWithPath: rootPath).appendingPathComponent(profileDirName).path)
    }
}

/**
 * A Profile manages access to the user's data.
 */
protocol Profile: AnyObject {
    var places: RustPlaces { get }
    var prefs: Prefs { get }
    var queue: TabQueue { get }
    var searchEngines: SearchEngines { get }
    var files: FileAccessor { get }
    var history: BrowserHistory { get }
    var metadata: Metadata { get }
    var recommendations: HistoryRecommendations { get }
    var favicons: Favicons { get }
    var logins: RustLogins { get }
    var certStore: CertStore { get }
    var recentlyClosedTabs: ClosedTabsStore { get }
    var panelDataObservers: PanelDataObservers { get }

    #if !MOZ_TARGET_NOTIFICATIONSERVICE
        var readingList: ReadingList { get }
    #endif

    var isShutdown: Bool { get }

    /// WARNING: Only to be called as part of the app lifecycle from the AppDelegate
    /// or from App Extension code.
    func _shutdown()

    /// WARNING: Only to be called as part of the app lifecycle from the AppDelegate
    /// or from App Extension code.
    func _reopen()

    // I got really weird EXC_BAD_ACCESS errors on a non-null reference when I made this a getter.
    // Similar to <http://stackoverflow.com/questions/26029317/exc-bad-access-when-indirectly-accessing-inherited-member-in-swift>.
    func localName() -> String

    func cleanupHistoryIfNeeded()

    var syncManager: SyncManager! { get }
}

fileprivate let PrefKeyClientID = "PrefKeyClientID"
extension Profile {
    var clientID: String {
        let clientID: String
        if let id = prefs.stringForKey(PrefKeyClientID) {
            clientID = id
        } else {
            clientID = UUID().uuidString
            prefs.setString(clientID, forKey: PrefKeyClientID)
        }
        return clientID
    }
}

open class BrowserProfile: Profile {
    fileprivate let name: String
    fileprivate let keychain: KeychainWrapper
    var isShutdown = false

    internal let files: FileAccessor

    let db: BrowserDB
    let readingListDB: BrowserDB
    var syncManager: SyncManager!

    private let loginsSaltKeychainKey = "sqlcipher.key.logins.salt"
    private let loginsUnlockKeychainKey = "sqlcipher.key.logins.db"
    private lazy var loginsKey: String = {
        if let secret = keychain.string(forKey: loginsUnlockKeychainKey) {
            return secret
        }

        let Length: UInt = 256
        let secret = Bytes.generateRandomBytes(Length).base64EncodedString
        keychain.set(secret, forKey: loginsUnlockKeychainKey, withAccessibility: .afterFirstUnlock)
        return secret
    }()

    /**
     * N.B., BrowserProfile is used from our extensions, often via a pattern like
     *
     *   BrowserProfile(…).foo.saveSomething(…)
     *
     * This can break if BrowserProfile's initializer does async work that
     * subsequently — and asynchronously — expects the profile to stick around:
     * see Bug 1218833. Be sure to only perform synchronous actions here.
     *
     * A SyncDelegate can be provided in this initializer, or once the profile is initialized.
     * However, if we provide it here, it's assumed that we're initializing it from the application.
     */
    init(localName: String, clear: Bool = false) {
        //log.debug("Initing profile \(localName) on thread \(Thread.current).")
        self.name = localName
        self.files = ProfileFileAccessor(localName: localName)
        self.keychain = KeychainWrapper.sharedAppContainerKeychain

        if clear {
            do {
                // Remove the contents of the directory…
                try self.files.removeFilesInDirectory()
                // …then remove the directory itself.
                try self.files.remove("")
            } catch {
                //log.info("Cannot clear profile: \(error)")
            }
        }

        // If the profile dir doesn't exist yet, this is first run (for this profile). The check is made here
        // since the DB handles will create new DBs under the new profile folder.
        let isNewProfile = !files.exists("")

        // Set up our database handles.
        self.db = BrowserDB(filename: "browser.db", schema: BrowserSchema(), files: files)
        self.readingListDB = BrowserDB(filename: "ReadingList.db", schema: ReadingListSchema(), files: files)

        if isNewProfile {
            //log.info("New profile. Removing old Keychain/Prefs data.")
            KeychainWrapper.wipeKeychain()
            prefs.clearAll()
        }


        // This has to happen prior to the databases being opened, because opening them can trigger
        // events to which the SyncManager listens.
        self.syncManager = BrowserSyncManager(profile: self)

        let notificationCenter = NotificationCenter.default

        notificationCenter.addObserver(self, selector: #selector(onLocationChange), name: .OnLocationChange, object: nil)
        notificationCenter.addObserver(self, selector: #selector(onPageMetadataFetched), name: .OnPageMetadataFetched, object: nil)

        // Always start by needing invalidation.
        // This is the same as self.history.setTopSitesNeedsInvalidation, but without the
        // side-effect of instantiating SQLiteHistory (and thus BrowserDB) on the main thread.
        prefs.setBool(false, forKey: PrefsKeys.KeyTopSitesCacheIsValid)

        if AppInfo.isChinaEdition {

            // Set the default homepage.
            prefs.setString(PrefsDefaults.ChineseHomePageURL, forKey: PrefsKeys.KeyDefaultHomePageURL)

            if prefs.stringForKey(PrefsKeys.KeyNewTab) == nil {
                prefs.setString(PrefsDefaults.ChineseHomePageURL, forKey: PrefsKeys.NewTabCustomUrlPrefKey)
                prefs.setString(PrefsDefaults.ChineseNewTabDefault, forKey: PrefsKeys.KeyNewTab)
            }

            if prefs.stringForKey(PrefsKeys.HomePageTab) == nil {
                prefs.setString(PrefsDefaults.ChineseHomePageURL, forKey: PrefsKeys.HomeButtonHomePageURL)
                prefs.setString(PrefsDefaults.ChineseNewTabDefault, forKey: PrefsKeys.HomePageTab)
            }
        } else {
            // Remove the default homepage. This does not change the user's preference,
            // just the behaviour when there is no homepage.
            prefs.removeObjectForKey(PrefsKeys.KeyDefaultHomePageURL)
        }

        // Hide the "__leanplum.sqlite" file in the documents directory.
        if var leanplumFile = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("__leanplum.sqlite"), FileManager.default.fileExists(atPath: leanplumFile.path) {
            let isHidden = (try? leanplumFile.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
            if !isHidden {
                var resourceValues = URLResourceValues()
                resourceValues.isHidden = true
                try? leanplumFile.setResourceValues(resourceValues)
            }
        }

        // Create the "Downloads" folder in the documents directory.
        if let downloadsPath = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Downloads").path {
            try? FileManager.default.createDirectory(atPath: downloadsPath, withIntermediateDirectories: true, attributes: nil)
        }
    }

    func _reopen() {
        //log.debug("Reopening profile.")
        isShutdown = false

        if !places.isOpen {
            places.migrateBookmarksIfNeeded(fromBrowserDB: db)
        }

        db.reopenIfClosed()
        _ = logins.reopenIfClosed()
        _ = places.reopenIfClosed()
    }

    func _shutdown() {
        //log.debug("Shutting down profile.")
        isShutdown = true

        db.forceClose()
        _ = logins.forceClose()
        _ = places.forceClose()
    }

    @objc
    func onLocationChange(notification: NSNotification) {
        if let v = notification.userInfo!["visitType"] as? Int,
           let visitType = VisitType(rawValue: v),
           let url = notification.userInfo!["url"] as? URL, !isIgnoredURL(url),
           let title = notification.userInfo!["title"] as? NSString {
            // Only record local vists if the change notification originated from a non-private tab
            if !(notification.userInfo!["isPrivate"] as? Bool ?? false) {
                // We don't record a visit if no type was specified -- that means "ignore me".
                let site = Site(url: url.absoluteString, title: title as String)
                let visit = SiteVisit(site: site, date: Date.nowMicroseconds(), type: visitType)
                history.addLocalVisit(visit)
            }

            history.setTopSitesNeedsInvalidation()
        } else {
            //log.debug("Ignoring navigation.")
        }
    }

    @objc
    func onPageMetadataFetched(notification: NSNotification) {
        let isPrivate = notification.userInfo?["isPrivate"] as? Bool ?? true
        guard !isPrivate else {
            //log.debug("Private mode - Ignoring page metadata.")
            return
        }
        guard let pageURL = notification.userInfo?["tabURL"] as? URL,
              let pageMetadata = notification.userInfo?["pageMetadata"] as? PageMetadata else {
            //log.debug("Metadata notification doesn't contain any metadata!")
            return
        }
        let defaultMetadataTTL: UInt64 = 3 * 24 * 60 * 60 * 1000 // 3 days for the metadata to live
        self.metadata.storeMetadata(pageMetadata, forPageURL: pageURL, expireAt: defaultMetadataTTL + Date.now())
    }



    func localName() -> String {
        return name
    }

    lazy var queue: TabQueue = {
        withExtendedLifetime(self.history) {
            return SQLiteQueue(db: self.db)
        }
    }()

    /**
     * Favicons, history, and tabs are all stored in one intermeshed
     * collection of tables.
     *
     * Any other class that needs to access any one of these should ensure
     * that this is initialized first.
     */
    fileprivate lazy var legacyPlaces: BrowserHistory & Favicons & HistoryRecommendations  = {
        return SQLiteHistory(db: self.db, prefs: self.prefs)
    }()

    var favicons: Favicons {
        return self.legacyPlaces
    }

    var history: BrowserHistory {
        return self.legacyPlaces
    }

    lazy var panelDataObservers: PanelDataObservers = {
        return PanelDataObservers(profile: self)
    }()

    lazy var metadata: Metadata = {
        return SQLiteMetadata(db: self.db)
    }()

    var recommendations: HistoryRecommendations {
        return self.legacyPlaces
    }

    lazy var placesDbPath = URL(fileURLWithPath: (try! files.getAndEnsureDirectory()), isDirectory: true).appendingPathComponent("places.db").path

    lazy var places = RustPlaces(databasePath: placesDbPath)

    lazy var searchEngines: SearchEngines = {
        return SearchEngines(prefs: self.prefs, files: self.files)
    }()

    func makePrefs() -> Prefs {
        return NSUserDefaultsPrefs(prefix: self.localName())
    }

    lazy var prefs: Prefs = {
        return self.makePrefs()
    }()

    lazy var readingList: ReadingList = {
        return SQLiteReadingList(db: self.readingListDB)
    }()

    lazy var certStore: CertStore = {
        return CertStore()
    }()

    lazy var recentlyClosedTabs: ClosedTabsStore = {
        return ClosedTabsStore(prefs: self.prefs)
    }()

    public func cleanupHistoryIfNeeded() {
        recommendations.cleanupHistoryIfNeeded()
    }

    lazy var logins: RustLogins = {
        let databasePath = URL(fileURLWithPath: (try! files.getAndEnsureDirectory()), isDirectory: true).appendingPathComponent("logins.db").path

        let salt: String
        if let val = keychain.string(forKey: loginsSaltKeychainKey) {
            salt = val
        } else {
            salt = RustLogins.setupPlaintextHeaderAndGetSalt(databasePath: databasePath, encryptionKey: loginsKey)
            keychain.set(salt, forKey: loginsSaltKeychainKey, withAccessibility: .afterFirstUnlock)
        }

        return RustLogins(databasePath: databasePath, encryptionKey: loginsKey, salt: salt)
    }()

    class NoAccountError: MaybeErrorType {
        var description = "No account."
    }

    // Extends NSObject so we can use timers.
    public class BrowserSyncManager: NSObject, SyncManager {
        // We shouldn't live beyond our containing BrowserProfile, either in the main app or in
        // an extension.
        // But it's possible that we'll finish a side-effect sync after we've ditched the profile
        // as a whole, so we hold on to our Prefs, potentially for a little while longer. This is
        // safe as a strong reference, because there's no cycle.
        unowned fileprivate let profile: BrowserProfile
        fileprivate let prefs: Prefs
        fileprivate var constellationStateUpdate: Any?

        let OneMinute = TimeInterval(60)

        deinit {
            if let c = constellationStateUpdate {
                NotificationCenter.default.removeObserver(c)
            }
        }

        /**
         * Locking is managed by syncSeveral. Make sure you take and release these
         * whenever you do anything Sync-ey.
         */
        fileprivate let syncLock = NSRecursiveLock()

        // The dispatch queue for coordinating syncing and resetting the database.
        fileprivate let syncQueue = DispatchQueue(label: "com.mozilla.firefox.sync")

        init(profile: BrowserProfile) {
            self.profile = profile
            self.prefs = profile.prefs

            super.init()

            let center = NotificationCenter.default

            center.addObserver(self, selector: #selector(onDatabaseWasRecreated), name: .DatabaseWasRecreated, object: nil)

        }

        // TODO: Do we still need this/do we need to do this for our new DB too?
        private func handleRecreationOfDatabaseNamed(name: String?) -> Success {
            let browserCollections = ["history", "tabs"]
            let dbName = name ?? "<all>"
            switch dbName {
            case "<all>", "browser.db":
                return self.locallyResetCollections(browserCollections)
            default:
                //log.debug("Unknown database \(dbName).")
                return succeed()
            }
        }

        func doInBackgroundAfter(_ millis: Int64, _ block: @escaping () -> Void) {
            let queue = DispatchQueue.global(qos: DispatchQoS.background.qosClass)
            //Pretty ambiguous here. I'm thinking .now was DispatchTime.now() and not Date.now()
            queue.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(millis)), execute: block)
        }

        @objc
        func onDatabaseWasRecreated(notification: NSNotification) {
            //log.debug("Database was recreated.")
            let name = notification.object as? String
            //log.debug("Database was \(name ?? "nil").")

            // We run this in the background after a few hundred milliseconds;
            // it doesn't really matter when it runs, so long as it doesn't
            // happen in the middle of a sync.

            let resetDatabase = {
                return self.handleRecreationOfDatabaseNamed(name: name) >>== {
                    //log.debug("Reset of \(name ?? "nil") done")
                }
            }

            self.doInBackgroundAfter(300) {
                self.syncLock.lock()
                defer { self.syncLock.unlock() }
                
                    // Otherwise, reset the database on the sync queue now
                    // Sync can't start while this is still going on.
                    self.syncQueue.async(execute: resetDatabase)
            }
        }

        var prefsForSync: Prefs {
            return self.prefs.branch("sync")
        }

        func locallyResetCollections(_ collections: [String]) -> Success {
            return walk(collections, f: self.locallyResetCollection)
        }

        func locallyResetCollection(_ collection: String) -> Success {
            switch collection {
            case "bookmarks":
                return self.profile.places.resetBookmarksMetadata()
            case "clients":
                fallthrough
            case "passwords":
                return self.profile.logins.reset()
            case "forms":
                //log.debug("Requested reset for forms, but this client doesn't sync them yet.")
                return succeed()
            case "addons":
                //log.debug("Requested reset for addons, but this client doesn't sync them.")
                return succeed()
            case "prefs":
                //log.debug("Requested reset for prefs, but this client doesn't sync them.")
                return succeed()
            default:
                //log.warning("Asked to reset collection \(collection), which we don't know about.")
                return succeed()
            }
        }

        public func hasSyncedLogins() -> Deferred<Maybe<Bool>> {
            return self.profile.logins.hasSyncedLogins()
        }
    }
}
