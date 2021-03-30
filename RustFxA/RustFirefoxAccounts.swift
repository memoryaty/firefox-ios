/* This Source Code Form is subject to the terms of the Mozilla Public
* License, v. 2.0. If a copy of the MPL was not distributed with this
* file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import MozillaAppServices
import SwiftKeychainWrapper

//let PendingAccountDisconnectedKey = "PendingAccountDisconnect"

// Used to ignore unknown classes when de-archiving
final class Unknown: NSObject, NSCoding {
    func encode(with coder: NSCoder) {}
    init(coder aDecoder: NSCoder) {
        super.init()
    }
}

/**
 A singleton that wraps the Rust FxA library.
 The singleton design is poor for testability through dependency injection and may need to be changed in future.
 */
// TODO: renamed FirefoxAccounts.swift once the old code is removed fully.
open class RustFirefoxAccounts {
    public static let prefKeyLastDeviceName = "prefKeyLastDeviceName"
//    private static let clientID = "1b1a3e44c54fbb58"
//    public static let redirectURL = "urn:ietf:wg:oauth:2.0:oob:oauth-redirect-webchannel"
    public static var shared = RustFirefoxAccounts()
    public var accountManager = Deferred<FxAccountManager>()
//    private static var isInitializingAccountManager = false
//    public let syncAuthState: SyncAuthState
    fileprivate static var prefs: Prefs?
//    public let pushNotifications = PushNotificationSetup()

    // This is used so that if a migration failed, show a UI indicator for the user to manually log in to their account.
    public var accountMigrationFailed: Bool {
        get {
            return UserDefaults.standard.bool(forKey: "fxaccount-migration-failed")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "fxaccount-migration-failed")
        }
    }

    /** Must be called before this class is fully usable. Until this function is complete,
     all methods in this class will behave as if there is no Fx account.
     It will be called on app startup, and extensions must call this before using the class.
     If it is possible code could access `shared` before initialize() is complete, these callers should also
     hook into notifications like `.accountProfileUpdate` to refresh once initialize() is complete.
     Or they can wait on the accountManager deferred to fill.
     */

    private static let prefKeySyncAuthStateUniqueID = "PrefKeySyncAuthStateUniqueID"
    private static func syncAuthStateUniqueId(prefs: Prefs?) -> String {
        let id: String
        let key = RustFirefoxAccounts.prefKeySyncAuthStateUniqueID
        if let _id = prefs?.stringForKey(key) {
            id = _id
        } else {
            id = UUID().uuidString
            prefs?.setString(id, forKey: key)
        }
        return id
    }

    private init() {
        // Set-up Rust network stack. Note that this has to be called
        // before any Application Services component gets used.
        Viaduct.shared.useReqwestBackend()

        let prefs = RustFirefoxAccounts.prefs

//        syncAuthState = FirefoxAccountSyncAuthState(
//            cache: KeychainCache.fromBranch("rustAccounts.syncAuthState",
//                                            withLabel: RustFirefoxAccounts.syncAuthStateUniqueId(prefs: prefs),
//                factory: syncAuthStateCachefromJSON))

        // Called when account is logged in for the first time, on every app start when the account is found (even if offline), and when migration of an account is completed.
        NotificationCenter.default.addObserver(forName: .accountAuthenticated, object: nil, queue: .main) { [weak self] notification in
            // Handle account migration completed successfully. Need to clear the old stored apnsToken and re-register push.
            if let type = notification.userInfo?["authType"] as? FxaAuthType, case .migrated = type {
//                KeychainWrapper.sharedAppContainerKeychain.removeObject(forKey: KeychainKey.apnsToken, withAccessibility: .afterFirstUnlock)
//                NotificationCenter.default.post(name: .RegisterForPushNotifications, object: nil)
            }

            self?.update()
        }
        
        NotificationCenter.default.addObserver(forName: .accountProfileUpdate, object: nil, queue: .main) { [weak self] notification in
            self?.update()
        }

        NotificationCenter.default.addObserver(forName: .accountMigrationFailed, object: nil, queue: .main) { [weak self] notification in
            var info = ""
            if let error = notification.userInfo?["error"] as? Error {
                info = error.localizedDescription
            }
            //Sentry.shared.send(message: "RustFxa failed account migration", tag: .rustLog, severity: .error, description: info)
            self?.accountMigrationFailed = true
            NotificationCenter.default.post(name: .FirefoxAccountStateChange, object: nil)
        }
    }

    /// When migrating to new rust FxA, grab the old session tokens and try to re-use them.
    private class func migrationTokens() -> (session: String, ksync: String, kxcs: String)? {
        // Keychain forKey("profile.account"), return dictionary, from there
        // forKey("account.state.<guid>"), guid is dictionary["stateKeyLabel"]
        // that returns JSON string.
        let keychain = KeychainWrapper.sharedAppContainerKeychain
        let key = "profile.account"
        keychain.ensureObjectItemAccessibility(.afterFirstUnlock, forKey: key)

        // Ignore this class when de-archiving, it isn't needed.
        NSKeyedUnarchiver.setClass(Unknown.self, forClassName: "Account.FxADeviceRegistration")

        guard let dict = keychain.object(forKey: key) as? [String: AnyObject], let guid = dict["stateKeyLabel"] else {
            return nil
        }

        let key2 = "account.state.\(guid)"
        keychain.ensureObjectItemAccessibility(.afterFirstUnlock, forKey: key2)
        guard let jsonData = keychain.data(forKey: key2) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: jsonData, options: .allowFragments) as? [String: Any] else {
            return nil
        }

        guard let sessionToken = json["sessionToken"] as? String, let ksync = json["kSync"] as? String, let kxcs = json["kXCS"] as? String else {
            return nil
        }

        return (session: sessionToken, ksync: ksync, kxcs: kxcs)
    }

    /// Rust FxA notification handlers can call this to update caches and the UI.
    private func update() {

        NotificationCenter.default.post(name: .FirefoxAccountProfileChanged, object: self)
        NotificationCenter.default.post(name: .FirefoxAccountStateChange, object: self)
    }
}

