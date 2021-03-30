/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// IMPORTANT!: Please take into consideration when adding new imports to
// this file that it is utilized by external components besides the core
// application (i.e. App Extensions). Introducing new dependencies here
// may have unintended negative consequences for App Extensions such as
// increased startup times which may lead to termination by the OS.
import Account
import Shared
import Storage
import Sync

import SwiftKeychainWrapper


// Import these dependencies ONLY for the main `Client` application target.
#if MOZ_TARGET_CLIENT
    import SwiftyJSON
#endif



public let ProfileRemoteTabsSyncDelay: TimeInterval = 0.1

public protocol SyncManager {

    func hasSyncedHistory() -> Deferred<Maybe<Bool>>
    func hasSyncedLogins() -> Deferred<Maybe<Bool>>

    func syncClients() -> SyncResult
    func syncClientsThenTabs() -> SyncResult
    func syncHistory() -> SyncResult
    func syncBookmarks() -> SyncResult

    func onNewProfile()
}

typealias SyncFunction = (SyncDelegate, Prefs, Ready, SyncReason) -> SyncResult

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

class CommandStoringSyncDelegate: SyncDelegate {
    let profile: Profile

    init(profile: Profile) {
        self.profile = profile
    }

    public func displaySentTab(for url: URL, title: String, from deviceName: String?) {
        let item = ShareItem(url: url.absoluteString, title: title, favicon: nil)
        _ = self.profile.queue.addToQueue(item)
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
    var history: BrowserHistory & SyncableHistory & ResettableSyncStorage { get }
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

    var rustFxA: RustFirefoxAccounts { get }

    func getClients() -> Deferred<Maybe<[RemoteClient]>>
    func getCachedClients()-> Deferred<Maybe<[RemoteClient]>>
    func getClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>>
    func getCachedClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>>

    func cleanupHistoryIfNeeded()

    @discardableResult func storeTabs(_ tabs: [RemoteTab]) -> Deferred<Maybe<Int>>

    func sendItem(_ item: ShareItem, toDevices devices: [RemoteDevice]) -> Success

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

    var syncDelegate: SyncDelegate?

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
    init(localName: String, syncDelegate: SyncDelegate? = nil, clear: Bool = false) {
        //log.debug("Initing profile \(localName) on thread \(Thread.current).")
        self.name = localName
        self.files = ProfileFileAccessor(localName: localName)
        self.keychain = KeychainWrapper.sharedAppContainerKeychain
        self.syncDelegate = syncDelegate

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
    fileprivate lazy var legacyPlaces: BrowserHistory & Favicons & SyncableHistory & ResettableSyncStorage & HistoryRecommendations  = {
        return SQLiteHistory(db: self.db, prefs: self.prefs)
    }()

    var favicons: Favicons {
        return self.legacyPlaces
    }

    var history: BrowserHistory & SyncableHistory & ResettableSyncStorage {
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

    lazy var remoteClientsAndTabs: RemoteClientsAndTabs & ResettableSyncStorage & RemoteDevices = {
        return SQLiteRemoteClientsAndTabs(db: self.db)
    }()

    lazy var certStore: CertStore = {
        return CertStore()
    }()

    lazy var recentlyClosedTabs: ClosedTabsStore = {
        return ClosedTabsStore(prefs: self.prefs)
    }()

    open func getSyncDelegate() -> SyncDelegate {
        return syncDelegate ?? CommandStoringSyncDelegate(profile: self)
    }

    public func getClients() -> Deferred<Maybe<[RemoteClient]>> {
        return self.syncManager.syncClients()
           >>> { self.remoteClientsAndTabs.getClients() }
    }

    public func getCachedClients()-> Deferred<Maybe<[RemoteClient]>> {
        return self.remoteClientsAndTabs.getClients()
    }

    public func getClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>> {
        return self.syncManager.syncClientsThenTabs()
           >>> { self.remoteClientsAndTabs.getClientsAndTabs() }
    }

    public func getCachedClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>> {
        return self.remoteClientsAndTabs.getClientsAndTabs()
    }

    public func cleanupHistoryIfNeeded() {
        recommendations.cleanupHistoryIfNeeded()
    }

    func storeTabs(_ tabs: [RemoteTab]) -> Deferred<Maybe<Int>> {
        return self.remoteClientsAndTabs.insertOrUpdateTabs(tabs)
    }

    public func sendItem(_ item: ShareItem, toDevices devices: [RemoteDevice]) -> Success {
        let deferred = Success()
        RustFirefoxAccounts.shared.accountManager.uponQueue(.main) { accountManager in
            guard let constellation = accountManager.deviceConstellation() else {
                deferred.fill(Maybe(failure: NoAccountError()))
                return
            }
            devices.forEach {
                if let id = $0.id {
                    constellation.sendEventToDevice(targetDeviceId: id, e: .sendTab(title: item.title ?? "", url: item.url))
                }
            }

            deferred.fill(Maybe(success: ()))
        }
        return deferred
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

    var rustFxA: RustFirefoxAccounts {
        return RustFirefoxAccounts.shared
    }

    class NoAccountError: MaybeErrorType {
        var description = "No account."
    }

    // Extends NSObject so we can use timers.
    public class BrowserSyncManager: NSObject, SyncManager, CollectionChangedNotifier {
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
            case "tabs":
                // Because clients and tabs share storage, and thus we wipe data for both if we reset either,
                // we reset the prefs for both at the same time.
                return TabsSynchronizer.resetClientsAndTabsWithStorage(self.profile.remoteClientsAndTabs, basePrefs: self.prefsForSync)

            case "history":
                return HistorySynchronizer.resetSynchronizerWithStorage(self.profile.history, basePrefs: self.prefsForSync, collection: "history")
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

        public func onNewProfile() {
            SyncStateMachine.clearStateFromPrefs(self.prefsForSync)
        }

//        public func onRemovedAccount() -> Success {
//            let profile = self.profile
//
//            // Run these in order, because they might write to the same DB!
//            let remove = [
//                profile.history.onRemovedAccount,
//                profile.remoteClientsAndTabs.onRemovedAccount,
//                profile.logins.reset,
//                profile.places.resetBookmarksMetadata,
//            ]
//
//            let clearPrefs: () -> Success = {
//                withExtendedLifetime(self) {
//                    // Clear prefs after we're done clearing everything else -- just in case
//                    // one of them needs the prefs and we race. Clear regardless of success
//                    // or failure.
//
//                    // This will remove keys from the Keychain if they exist, as well
//                    // as wiping the Sync prefs.
//                    SyncStateMachine.clearStateFromPrefs(self.prefsForSync)
//                }
//                return succeed()
//            }
//
//            return accumulate(remove) >>> clearPrefs
//        }

        fileprivate func syncClientsWithDelegate(_ delegate: SyncDelegate, prefs: Prefs, ready: Ready, why: SyncReason) -> SyncResult {
            //log.debug("Syncing clients to storage.")

            if constellationStateUpdate == nil {
                constellationStateUpdate = NotificationCenter.default.addObserver(forName: .constellationStateUpdate, object: nil, queue: .main) { [weak self] notification in
                    guard let accountManager = self?.profile.rustFxA.accountManager.peek(), let state = accountManager.deviceConstellation()?.state() else {
                        return
                    }
                    guard let self = self else { return }
                    let devices = state.remoteDevices.map { d -> RemoteDevice in
                        let t = "\(d.deviceType)"
                        return RemoteDevice(id: d.id, name: d.displayName, type: t, isCurrentDevice: d.isCurrentDevice, lastAccessTime: d.lastAccessTime, availableCommands: nil)
                    }
                    let _ = self.profile.remoteClientsAndTabs.replaceRemoteDevices(devices)
                }
            }

            let clientSynchronizer = ready.synchronizer(ClientsSynchronizer.self, delegate: delegate, prefs: prefs, why: why)
            return clientSynchronizer.synchronizeLocalClients(self.profile.remoteClientsAndTabs, withServer: ready.client, info: ready.info, notifier: self) >>== { result in
                guard case .completed = result, let accountManager = self.profile.rustFxA.accountManager.peek() else {
                    return deferMaybe(result)
                }
                //log.debug("Updating FxA devices list.")

                accountManager.deviceConstellation()?.refreshState()
                return deferMaybe(result)
            }
        }

        fileprivate func syncTabsWithDelegate(_ delegate: SyncDelegate, prefs: Prefs, ready: Ready, why: SyncReason) -> SyncResult {
            let storage = self.profile.remoteClientsAndTabs
            let tabSynchronizer = ready.synchronizer(TabsSynchronizer.self, delegate: delegate, prefs: prefs, why: why)
            return tabSynchronizer.synchronizeLocalTabs(storage, withServer: ready.client, info: ready.info)
        }

        fileprivate func syncHistoryWithDelegate(_ delegate: SyncDelegate, prefs: Prefs, ready: Ready, why: SyncReason) -> SyncResult {
            //log.debug("Syncing history to storage.")
            let historySynchronizer = ready.synchronizer(HistorySynchronizer.self, delegate: delegate, prefs: prefs, why: why)
            return historySynchronizer.synchronizeLocalHistory(self.profile.history, withServer: ready.client, info: ready.info)
        }

        public class ScopedKeyError: MaybeErrorType {
            public var description = "No key data found for scope."
        }
        
        public class SyncUnlockGetURLError: MaybeErrorType {
            public var description = "Failed to get token server endpoint url."
        }

        fileprivate func syncUnlockInfo() -> Deferred<Maybe<SyncUnlockInfo>> {
            let d = Deferred<Maybe<SyncUnlockInfo>>()
            profile.rustFxA.accountManager.uponQueue(.main) { accountManager in
                accountManager.getAccessToken(scope: OAuthScope.oldSync) { result in
                    guard let accessTokenInfo = try? result.get(), let key = accessTokenInfo.key else {
                        d.fill(Maybe(failure: ScopedKeyError()))
                        return
                    }

                    accountManager.getTokenServerEndpointURL() { result in
                        guard case .success(let tokenServerEndpointURL) = result else {
                            d.fill(Maybe(failure: SyncUnlockGetURLError()))
                            return
                        }

                        d.fill(Maybe(success: SyncUnlockInfo(kid: key.kid, fxaAccessToken: accessTokenInfo.token, syncKey: key.k, tokenserverURL: tokenServerEndpointURL.absoluteString)))
                    }
                }
            }
            return d
        }

        fileprivate func syncLoginsWithDelegate(_ delegate: SyncDelegate, prefs: Prefs, ready: Ready, why: SyncReason) -> SyncResult {
            //log.debug("Syncing logins to storage.")
            return syncUnlockInfo().bind({ result in
                guard let syncUnlockInfo = result.successValue else {
                    return deferMaybe(SyncStatus.notStarted(.unknown))
                }

                return self.profile.logins.sync(unlockInfo: syncUnlockInfo).bind({ result in
                    guard result.isSuccess else {
                        return deferMaybe(SyncStatus.notStarted(.unknown))
                    }

                    let syncEngineStatsSession = SyncEngineStatsSession(collection: "logins")
                    return deferMaybe(SyncStatus.completed(syncEngineStatsSession))
                })
            })
        }

        fileprivate func syncBookmarksWithDelegate(_ delegate: SyncDelegate, prefs: Prefs, ready: Ready, why: SyncReason) -> SyncResult {
            //log.debug("Syncing bookmarks to storage.")
            return syncUnlockInfo().bind({ result in
                guard let syncUnlockInfo = result.successValue else {
                    return deferMaybe(SyncStatus.notStarted(.unknown))
                }

                return self.profile.places.syncBookmarks(unlockInfo: syncUnlockInfo).bind({ result in
                    guard result.isSuccess else {
                        return deferMaybe(SyncStatus.notStarted(.unknown))
                    }

                    let syncEngineStatsSession = SyncEngineStatsSession(collection: "bookmarks")
                    return deferMaybe(SyncStatus.completed(syncEngineStatsSession))
                })
            })
        }

        func takeActionsOnEngineStateChanges<T: EngineStateChanges>(_ changes: T) -> Deferred<Maybe<T>> {
            var needReset = Set<String>(changes.collectionsThatNeedLocalReset())
            needReset.formUnion(changes.enginesDisabled())
            needReset.formUnion(changes.enginesEnabled())
            if needReset.isEmpty {
                //log.debug("No collections need reset. Moving on.")
                return deferMaybe(changes)
            }

            // needReset needs at most one of clients and tabs, because we reset them
            // both if either needs reset. This is strictly an optimization to avoid
            // doing duplicate work.
            if needReset.contains("clients") {
                if needReset.remove("tabs") != nil {
                    //log.debug("Already resetting clients (and tabs); not bothering to also reset tabs again.")
                }
            }

            return walk(Array(needReset), f: self.locallyResetCollection)
               >>> effect(changes.clearLocalCommands)
               >>> always(changes)
        }

        /**
         * Runs the single provided synchronization function and returns its status.
         */
        fileprivate func sync(_ label: EngineIdentifier, function: @escaping SyncFunction) -> SyncResult {
            return syncSeveral(why: .user, synchronizers: [(label, function)]) >>== { statuses in
                let status = statuses.find { label == $0.0 }?.1
                return deferMaybe(status ?? .notStarted(.unknown))
            }
        }

        /**
         * Convenience method for syncSeveral([(EngineIdentifier, SyncFunction)])
         */
        private func syncSeveral(why: SyncReason, synchronizers: (EngineIdentifier, SyncFunction)...) -> Deferred<Maybe<[(EngineIdentifier, SyncStatus)]>> {
            return syncSeveral(why: why, synchronizers: synchronizers)
        }

        /**
         * Runs each of the provided synchronization functions with the same inputs.
         * Returns an array of IDs and SyncStatuses at least length as the input.
         * The statuses returned will be a superset of the ones that are requested here.
         * While a sync is ongoing, each engine from successive calls to this method will only be called once.
         */
        fileprivate func syncSeveral(why: SyncReason, synchronizers: [(EngineIdentifier, SyncFunction)]) -> Deferred<Maybe<[(EngineIdentifier, SyncStatus)]>> {
            syncLock.lock()
            defer { syncLock.unlock() }
            
            return deferMaybe(NoAccountError())

            guard let fxa = RustFirefoxAccounts.shared.accountManager.peek(), let profile = fxa.accountProfile(), let deviceID = fxa.deviceConstellation()?.state()?.localDevice?.id else {
                return deferMaybe(NoAccountError())
            }

        }

        func engineEnablementChangesForAccount() -> [String: Bool]? {
            var enginesEnablements: [String: Bool] = [:]
            // We just created the account, the user went through the Choose What to Sync screen on FxA.
            if let declined = UserDefaults.standard.stringArray(forKey: "fxa.cwts.declinedSyncEngines") {
                declined.forEach { enginesEnablements[$0] = false }
                UserDefaults.standard.removeObject(forKey: "fxa.cwts.declinedSyncEngines")
            } else {
                // Bundle in authState the engines the user activated/disabled since the last sync.
                TogglableEngines.forEach { engine in
                    let stateChangedPref = "engine.\(engine).enabledStateChanged"
                    if let _ = self.prefsForSync.boolForKey(stateChangedPref),
                        let enabled = self.prefsForSync.boolForKey("engine.\(engine).enabled") {
                        enginesEnablements[engine] = enabled
                        self.prefsForSync.setObject(nil, forKey: stateChangedPref)
                    }
                }
            }
            return enginesEnablements
        }

        // This SHOULD NOT be called directly: use syncSeveral instead.
        fileprivate func syncWith(synchronizers: [(EngineIdentifier, SyncFunction)],
                                  statsSession: SyncOperationStatsSession, why: SyncReason) -> Deferred<Maybe<[(EngineIdentifier, SyncStatus)]>> {
            //log.info("Syncing \(synchronizers.map { $0.0 })")
            var authState = RustFirefoxAccounts.shared.syncAuthState
            let delegate = self.profile.getSyncDelegate()
            // TODO
            if let enginesEnablements = self.engineEnablementChangesForAccount(),
               !enginesEnablements.isEmpty {
                authState.enginesEnablements = enginesEnablements
                //log.debug("engines to enable: \(enginesEnablements.compactMap { $0.value ? $0.key : nil })")
                //log.debug("engines to disable: \(enginesEnablements.compactMap { !$0.value ? $0.key : nil })")
            }

            // TODO
//            authState?.clientName = account.deviceName

            let readyDeferred = SyncStateMachine(prefs: self.prefsForSync).toReady(authState)

            let function: (SyncDelegate, Prefs, Ready) -> Deferred<Maybe<[EngineStatus]>> = { delegate, syncPrefs, ready in
                let thunks = synchronizers.map { (i, f) in
                    return { () -> Deferred<Maybe<EngineStatus>> in
                        //log.debug("Syncing \(i)…")
                        return f(delegate, syncPrefs, ready, why) >>== { deferMaybe((i, $0)) }
                    }
                }
                return accumulate(thunks)
            }

            return readyDeferred.bind { readyResult in
                guard let success = readyResult.successValue else {
                    return deferMaybe(readyResult.failureValue!)
                }
                return self.takeActionsOnEngineStateChanges(success) >>== { ready in
                    let updateEnginePref: ((String, Bool) -> Void) = { engine, enabled in
                        self.prefsForSync.setBool(enabled, forKey: "engine.\(engine).enabled")
                    }
                    ready.engineConfiguration?.enabled.forEach { updateEnginePref($0, true) }
                    ready.engineConfiguration?.declined.forEach { updateEnginePref($0, false) }

                    statsSession.start()
                    return function(delegate, self.prefsForSync, ready)
                }
            }
        }

        public func hasSyncedHistory() -> Deferred<Maybe<Bool>> {
            return self.profile.history.hasSyncedHistory()
        }

        public func hasSyncedLogins() -> Deferred<Maybe<Bool>> {
            return self.profile.logins.hasSyncedLogins()
        }

        public func syncClients() -> SyncResult {
            // TODO: recognize .NotStarted.
            return self.sync("clients", function: syncClientsWithDelegate)
        }

        public func syncClientsThenTabs() -> SyncResult {
            return self.syncSeveral(
                why: .user,
                synchronizers:
                ("clients", self.syncClientsWithDelegate),
                ("tabs", self.syncTabsWithDelegate)) >>== { statuses in
                let status = statuses.find { "tabs" == $0.0 }
                return deferMaybe(status!.1)
            }
        }

        @discardableResult public func syncBookmarks() -> SyncResult {
            return self.sync("bookmarks", function: syncBookmarksWithDelegate)
        }

        @discardableResult public func syncLogins() -> SyncResult {
            return self.sync("logins", function: syncLoginsWithDelegate)
        }

        public func syncHistory() -> SyncResult {
            // TODO: recognize .NotStarted.
            return self.sync("history", function: syncHistoryWithDelegate)
        }

        public func notify(deviceIDs: [GUID], collectionsChanged collections: [String], reason: String) -> Success {
           return succeed()
        }

        public func notifyAll(collectionsChanged collections: [String], reason: String) -> Success {
            return succeed()
        }
    }
}
