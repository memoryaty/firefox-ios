/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage

/**
 * We sometimes want to make a synchronizer start from scratch: to throw away any
 * metadata and reset storage to match, allowing us to respond to significant server
 * changes.
 *
 * But instantiating a Synchronizer is a lot of work if we simply want to change some
 * persistent state. This protocol describes a static func that fits most synchronizers.
 *
 * When the returned `Deferred` is filled with a success value, the supplied prefs and
 * storage are ready to sync from scratch.
 *
 * Persisted long-term/local data is kept, and will later be reconciled as appropriate.
 */
public protocol ResettableSynchronizer {
    static func resetSynchronizerWithStorage(_ storage: ResettableSyncStorage, basePrefs: Prefs, collection: String) -> Success
}

/**
 * This is a delegate that allows synchronizers to notify other devices in the Sync account
 * that a collection changed.
 */
public protocol CollectionChangedNotifier {
    func notify(deviceIDs: [GUID], collectionsChanged collections: [String], reason: String) -> Success
    func notifyAll(collectionsChanged collections: [String], reason: String) -> Success
}

// TODO: return values?
/**
 * A Synchronizer is (unavoidably) entirely in charge of what it does within a sync.
 * For example, it might make incremental progress in building a local cache of remote records, never actually performing an upload or modifying local storage.
 * It might only upload data. Etc.
 *
 * Eventually I envision an intent-like approach, or additional methods, to specify preferences and constraints
 * (e.g., "do what you can in a few seconds", or "do a full sync, no matter how long it takes"), but that'll come in time.
 *
 * A Synchronizer is a two-stage beast. It needs to support synchronization, of course; that
 * needs a completely configured client, which can only be obtained from Ready. But it also
 * needs to be able to do certain things beforehand:
 *
 * * Wipe its collections from the server (presumably via a delegate from the state machine).
 * * Prepare to sync from scratch ("reset") in response to a changed set of keys, syncID, or node assignment.
 * * Wipe local storage ("wipeClient").
 *
 * Those imply that some kind of 'Synchronizer' exists throughout the state machine. We *could*
 * pickle instructions for eventual delivery next time one is made and synchronized…
 */
public protocol Synchronizer {
    init(scratchpad: Scratchpad, basePrefs: Prefs, why: SyncReason)

}

/**
 * We sometimes wish to return something more nuanced than simple success or failure.
 * For example, refusing to sync because the engine was disabled isn't success (nothing was transferred!)
 * but it also isn't an error.
 *
 * To do this we model real failures -- something went wrong -- as failures in the Result, and
 * everything else in this status enum. This will grow as we return more details from a sync to allow
 * for batch scheduling, success-case backoff and so on.
 */
public enum SyncStatus {
    case completed(SyncEngineStatsSession)
    case notStarted(SyncNotStartedReason)
    case partial(SyncEngineStatsSession)

    public var description: String {
        switch self {
        case .completed:
            return "Completed"
        case let .notStarted(reason):
            return "Not started: \(reason.description)"
        case .partial:
            return "Partial"
        }
    }
}

public typealias DeferredTimestamp = Deferred<Maybe<Timestamp>>
public typealias SyncResult = Deferred<Maybe<SyncStatus>>
//public typealias EngineIdentifier = String
//public typealias EngineStatus = (EngineIdentifier, SyncStatus)
//public typealias EngineResults = [EngineStatus]
//public typealias SyncOperationResult = (engineResults: Maybe<EngineResults>, stats: SyncOperationStatsSession?)

public enum SyncNotStartedReason {
    case noAccount
    case offline
    case backoff(remainingSeconds: Int)
    case engineRemotelyNotEnabled(collection: String)
    case engineFormatOutdated(needs: Int)
    case engineFormatTooNew(expected: Int)   // This'll disappear eventually; we'll wipe the server and upload m/g.
    case storageFormatOutdated(needs: Int)
    case storageFormatTooNew(expected: Int)  // This'll disappear eventually; we'll wipe the server and upload m/g.
    case stateMachineNotReady                // Because we're not done implementing.
    case redLight
    case unknown                             // Likely a programming error.

    var telemetryId: String {
        switch self {
        case .noAccount:
            return "sync.not_started.reason.no_account"
        case .offline:
            return "sync.not_started.reason.offline"
        case .backoff(_):
            return "sync.not_started.reason.backoff"
        case .engineRemotelyNotEnabled(_):
            return "sync.not_started.reason.remotely_not_enabled"
        case .engineFormatOutdated(_):
            return "sync.not_started.reason.format_outdated"
        case .engineFormatTooNew(_):   // This'll disappear eventually; we'll wipe the server and upload m/g.
            return "sync.not_started.reason.format_too_new"
        case .storageFormatOutdated(_):
            return "sync.not_started.reason.storage_format_outdated"
        case .storageFormatTooNew(_):  // This'll disappear eventually; we'll wipe the server and upload m/g.
            return "sync.not_started.reason.storage_format_too_new"
        case .stateMachineNotReady:                // Because we're not done implementing.
            return "sync.not_started.reason.state_machine_not_ready"
        case .redLight:
            return "sync.not_started.reason.red_light"
        case .unknown:                             // Likely a programming error
            return "sync.not_started.reason.unknown"
        }
    }

    var description: String {
        switch self {
        case .noAccount:
            return "no account"
        case let .backoff(remaining):
            return "in backoff: \(remaining) seconds remaining"
        default:
            return "undescribed reason"
        }
    }
}

open class FatalError: SyncError {
    let message: String
    init(message: String) {
        self.message = message
    }

    open var description: String {
        return self.message
    }
}

public protocol SingleCollectionSynchronizer {
    func remoteHasChanges(_ info: InfoCollections) -> Bool
}

open class BaseCollectionSynchronizer {
    let collection: String

    let scratchpad: Scratchpad
    let basePrefs: Prefs
    let prefs: Prefs
    let why: SyncReason

    var statsSession: SyncEngineStatsSession

    static func prefsForCollection(_ collection: String, withBasePrefs basePrefs: Prefs) -> Prefs {
        let branchName = "synchronizer." + collection + "."
        return basePrefs.branch(branchName)
    }

    init(scratchpad: Scratchpad, basePrefs: Prefs, why: SyncReason, collection: String) {
        self.scratchpad = scratchpad
        self.collection = collection
        self.basePrefs = basePrefs
        self.prefs = BaseCollectionSynchronizer.prefsForCollection(collection, withBasePrefs: basePrefs)
        self.statsSession = SyncEngineStatsSession(collection: collection)
        self.why = why

        //log.info("Synchronizer configured with prefs '\(self.prefs.getBranchPrefix()).'")
    }

    var storageVersion: Int {
        assert(false, "Override me!")
        return 0
    }

    // Short-hand for returning .Complete status + recorded stats
    var completedWithStats: SyncStatus {
        return .completed(statsSession.end())
    }

    func encrypter<T>(_ encoder: RecordEncoder<T>) -> RecordEncrypter<T>? {
        return self.scratchpad.keys?.value.encrypter(self.collection, encoder: encoder)
    }

    func collectionClient<T>(_ encoder: RecordEncoder<T>, storageClient: Sync15StorageClient) -> Sync15CollectionClient<T>? {
        if let encrypter = self.encrypter(encoder) {
            return storageClient.clientForCollection(self.collection, encrypter: encrypter)
        }
        return nil
    }
}

/**
 * Tracks a lastFetched timestamp, uses it to decide if there are any
 * remote changes, and exposes a method to fast-forward after upload.
 */
open class TimestampedSingleCollectionSynchronizer: BaseCollectionSynchronizer, SingleCollectionSynchronizer {

    var lastFetched: Timestamp {
        set(value) {
            self.prefs.setLong(value, forKey: "lastFetched")
        }

        get {
            return self.prefs.unsignedLongForKey("lastFetched") ?? 0
        }
    }

    func setTimestamp(_ timestamp: Timestamp) {
        //log.debug("Setting post-upload lastFetched to \(timestamp).")
        self.lastFetched = timestamp
    }

    open func remoteHasChanges(_ info: InfoCollections) -> Bool {
        return info.modified(self.collection) ?? 0 > self.lastFetched
    }
}

extension BaseCollectionSynchronizer: ResettableSynchronizer {
    public static func resetSynchronizerWithStorage(_ storage: ResettableSyncStorage, basePrefs: Prefs, collection: String) -> Success {
        let synchronizerPrefs = BaseCollectionSynchronizer.prefsForCollection(collection, withBasePrefs: basePrefs)
        synchronizerPrefs.removeObjectForKey("lastFetched")

        // Not all synchronizers use a batching downloader, but it's
        // convenient to just always reset it here.
        return storage.resetClient()
           >>> effect({ BatchingDownloader.resetDownloaderWithPrefs(synchronizerPrefs, collection: collection) })
    }
}
