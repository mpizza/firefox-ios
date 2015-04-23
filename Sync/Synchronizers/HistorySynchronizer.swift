/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger

// TODO: same comment as for SyncAuthState.swift!
private let log = XCGLogger.defaultInstance()

public class MockSyncableHistory: SyncableHistory {
    public var sharedPlaces = [GUID: RemotePlace]()
    public var localPlaces = [GUID: LocalPlace]()
    public var remoteVisits = [GUID: [Visit]]()
    public var localVisits = [GUID: [Visit]]()

    public init() {
    }

    private func placesForGUID(guid: GUID) -> (RemotePlace?, LocalPlace?) {
        return (sharedPlaces[guid], localPlaces[guid])
    }

    private func placesForURL(url: String) -> (RemotePlace?, LocalPlace?) {
        func hasURL(place: Place) -> Bool {
            return place.url == url
        }
        return (findFirstValue(sharedPlaces, hasURL), findFirstValue(localPlaces, hasURL))
    }

    // TODO: consider comparing the timestamp to local visits, perhaps opting to
    // not delete the local place (and instead to give it a new GUID) if the visits
    // are newer than the deletion.
    // Obviously this'll behave badly during reconciling on other devices:
    // they might apply our new record first, renaming their local copy of
    // the old record with that URL, and thus bring all the old visits back to life.
    // Desktop just finds by GUID then deletes by URL.
    public func deleteByGUID(guid: GUID, deletedAt: Timestamp) -> Deferred<Result<()>> {
        self.remoteVisits.removeValueForKey(guid)
        self.localVisits.removeValueForKey(guid)
        self.sharedPlaces.removeValueForKey(guid)
        self.localPlaces.removeValueForKey(guid)

        return succeed()
    }

    /**
     * This assumes that the provided GUID doesn't already map to a different URL!
     */
    public func ensurePlaceWithURL(url: String, hasGUID guid: GUID) -> Deferred<Result<()>> {
        // Find by URL.
        let (shared, local) = self.placesForURL(url)
        if let shared = shared {
            if shared.guid != guid {
                let p = RemotePlace(guid: guid, url: url, title: shared.title, modified: shared.modified)
                self.sharedPlaces.removeValueForKey(shared.guid)
                self.sharedPlaces[guid] = p
            }
        }

        if let local = local {
            if local.guid != guid {
                let p = LocalPlace(guid: guid, url: url, title: local.title, modified: local.modified)
                self.localPlaces.removeValueForKey(local.guid)
                self.localPlaces[guid] = p
            }
        }

        return succeed()
    }

    /**
     * This assumes that the new GUID doesn't already exist!
     */
    public func changeGUID(old: GUID, new: GUID) -> Deferred<Result<()>> {
        if let shared = self.sharedPlaces[old] {
            let p = RemotePlace(guid: new, url: shared.url, title: shared.title, modified: shared.modified)
            self.sharedPlaces.removeValueForKey(old)
            self.sharedPlaces[new] = p
        }

        if let local = self.localPlaces[old] {
            let p = LocalPlace(guid: new, url: local.url, title: local.title, modified: local.modified)
            self.localPlaces.removeValueForKey(old)
            self.localPlaces[new] = p
        }

        return succeed()
    }


    public func insertOrReplaceRemoteVisits(visits: [Visit], forGUID guid: GUID) -> Deferred<Result<()>> {
        // TODO: strip out local visits.
        self.remoteVisits[guid] = visits
        return succeed()
    }

    public func insertOrUpdatePlace(place: RemotePlace) -> Deferred<Result<GUID>> {
        // Make sure that we collide with any matching URLs -- whether locally
        // modified or not. Then overwrite the upstream and merge any local changes.
        return self.ensurePlaceWithURL(place.url, hasGUID: place.guid)
           >>> {
            // For now, just throw away any local changes. TODO
            self.localPlaces.removeValueForKey(place.guid)
            self.sharedPlaces[place.guid] = place
            return deferResult(place.guid)
        }
    }
}

public class HistorySynchronizer: BaseSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, delegate: SyncDelegate, basePrefs: Prefs) {
        super.init(scratchpad: scratchpad, delegate: delegate, basePrefs: basePrefs, collection: "history")
    }

    private func applyIncomingToStorage(storage: SyncableHistory, response: StorageResponse<[Record<HistoryPayload>]>) -> Success {

        func applyRecord(rec: Record<HistoryPayload>) -> Success {
            let guid = rec.id
            let payload = rec.payload
            let modified = rec.modified

            log.debug("Record: \(guid): \(payload.title)")

            // We apply deletions immediately, obviously.
            if payload.deleted {
                return storage.deleteByGUID(guid, deletedAt: modified)
            }

            // It's safe to apply other remote records, too -- even if we re-download, we know
            // from our local cached server timestamp on each record that we've already seen it.
            // We have to reconcile on-the-fly: we're about to overwrite the server record, which
            // is our shared parent.
            let place = rec.payload.asPlaceWithModifiedTime(modified)
            return storage.insertOrUpdatePlace(place)
               >>> { storage.insertOrReplaceRemoteVisits(payload.visits, forGUID: guid) }
        }

        func allSucceed(arr: [Success]) -> Success {
            return all(arr).map {
                for x in $0 {
                    if x.isFailure {
                        return x
                    }
                }
                return Result(success: ())
            }
        }

        return allSucceed(response.value.map(applyRecord))
           >>> {
            self.lastFetched = response.metadata.lastModifiedMilliseconds!
            return succeed()
        }
    }

    public func synchronizeLocalHistory(history: SyncableHistory, withServer storageClient: Sync15StorageClient, info: InfoCollections) -> Success {
        let keys = self.scratchpad.keys?.value
        let encoder = RecordEncoder<HistoryPayload>(decode: { HistoryPayload($0) }, encode: { $0 })
        if let encrypter = keys?.encrypter(self.collection, encoder: encoder) {
            let historyClient = storageClient.clientForCollection(self.collection, encrypter: encrypter)

            let since: Timestamp = 0       // self.lastFetched

            // TODO: wipe if we're starting over.
            // TODO: buffer downloaded records. Do this by marking items as unprocessed?b

            return historyClient.getSince(since)
              >>== { self.applyIncomingToStorage(history, response: $0) }
        }

        log.error("Couldn't make history factory.")
        return deferResult(FatalError(message: "Couldn't make history factory."))
    }
}
