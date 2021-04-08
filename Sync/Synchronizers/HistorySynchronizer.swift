/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage

import SwiftyJSON


private let HistoryTTLInSeconds = 5184000                   // 60 days.
let HistoryStorageVersion = 1

func makeHistoryRecord(_ place: Place, visits: [Visit]) -> Record<HistoryPayload> {
    let id = place.guid
    let modified: Timestamp = 0    // Ignored in upload serialization.
    let sortindex = 1              // TODO: frecency!
    let ttl = HistoryTTLInSeconds
    let json = JSON([
        "id": id,
        "visits": visits.map { $0.toJSON() },
        "histUri": place.url,
        "title": place.title,
        ])
    let payload = HistoryPayload(json)
    return Record<HistoryPayload>(id: id, payload: payload, modified: modified, sortindex: sortindex, ttl: ttl)
}

open class HistorySynchronizer: IndependentRecordSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, basePrefs: Prefs, why: SyncReason) {
        super.init(scratchpad: scratchpad, basePrefs: basePrefs, why: why, collection: "history")
    }

    override var storageVersion: Int {
        return HistoryStorageVersion
    }

    fileprivate let batchSize: Int = 1000  // A balance between number of requests and per-request size.

    fileprivate func mask(_ maxFailures: Int) -> (Maybe<()>) -> Success {
        var failures = 0
        return { result in
            if result.isSuccess {
                return Deferred(value: result)
            }

            failures += 1
            if failures > maxFailures {
                return Deferred(value: result)
            }

            //log.debug("Masking failure \(failures).")
            return succeed()
        }
    }

    // TODO: this function should establish a transaction at suitable points.
    // TODO: a much more efficient way to do this is to:
    // 1. Start a transaction.
    // 2. Try to update each place. Note failures.
    // 3. bulkInsert all failed updates in one go.
    // 4. Store all remote visits for all places in one go, constructing a single sequence of visits.
    func applyIncomingToStorage(_ storage: SyncableHistory, records: [Record<HistoryPayload>]) -> Success {
        // Skip over at most this many failing records before aborting the sync.
        let maskSomeFailures = self.mask(3)

        // TODO: it'd be nice to put this in an extension on SyncableHistory. Waiting for Swift 2.0...
        func applyRecord(_ rec: Record<HistoryPayload>) -> Success {
            let guid = rec.id
            let payload = rec.payload
            let modified = rec.modified

            // We apply deletions immediately. Yes, this will throw away local visits
            // that haven't yet been synced. That's how Sync works, alas.
            if payload.deleted {
                return storage.deleteByGUID(guid, deletedAt: modified).bind(maskSomeFailures)
            }

            // It's safe to apply other remote records, too -- even if we re-download, we know
            // from our local cached server timestamp on each record that we've already seen it.
            // We have to reconcile on-the-fly: we're about to overwrite the server record, which
            // is our shared parent.
            let place = rec.payload.asPlace()

            if isIgnoredURL(place.url) {
                //log.debug("Ignoring incoming record \(guid) because its URL is one we wish to ignore.")
                return succeed()
            }

            let placeThenVisits = storage.insertOrUpdatePlace(place, modified: modified)
                              >>> { storage.storeRemoteVisits(payload.visits, forGUID: guid) }
            return placeThenVisits.map({ result in
                if result.isFailure {
//                    let reason = result.failureValue?.description ?? "unknown reason"
                    //log.error("Record application failed: \(reason)")
                }
                return result
            }).bind(maskSomeFailures)
        }

        return self.applyIncomingRecords(records, apply: applyRecord)
    }


    /**
     * If the green light turns red, we don't want to continue to upload -- doing
     * so would cause us to fast-forward our last sync timestamp and skip whatever
     * we hadn't yet downloaded.
     */
    fileprivate func go(_ info: InfoCollections, downloader: BatchingDownloader<HistoryPayload>, history: SyncableHistory) -> SyncResult {

//        if !greenLight() {
            //log.info("Green light turned red. Stopping history download.")
            return deferMaybe(.partial(self.statsSession))
//        }

        func applyBatched() -> Success {
            return self.applyIncomingToStorage(history, records: downloader.retrieve())
               >>> effect(downloader.advance)
        }

        func onBatchResult(_ result: Maybe<DownloadEndState>) -> SyncResult {
            guard let end = result.successValue else {
                //log.warning("Got failure: \(result.failureValue!)")
                return deferMaybe(completedWithStats)
            }

            switch end {
            case .complete:
                //log.info("Done with batched mirroring.")
                return applyBatched()
                   >>> history.doneApplyingRecordsAfterDownload
                   >>> { deferMaybe(self.completedWithStats) }
            case .incomplete:
                //log.debug("Running another batch.")
                // This recursion is fine because Deferred always pushes callbacks onto a queue.
                return applyBatched()
                   >>> { self.go(info, downloader: downloader, history: history) }
            case .interrupted:
                //log.info("Interrupted. Aborting batching this time.")
                return deferMaybe(.partial(self.statsSession))
            case .noNewData:
                //log.info("No new data. No need to continue batching.")
                downloader.advance()
                return deferMaybe(completedWithStats)
            }
        }

        return downloader.go(info, limit: self.batchSize)
                         .bind(onBatchResult)
    }

}
