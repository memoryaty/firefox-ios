/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage

import SwiftyJSON


let ClientsStorageVersion = 1

// TODO
public protocol Command {
    static func fromName(_ command: String, args: [JSON]) -> Command?
    func run(_ synchronizer: ClientsSynchronizer) -> Success
    static func commandFromSyncCommand(_ syncCommand: SyncCommand) -> Command?
}

// Shit.
// We need a way to wipe or reset engines.
// We need a way to log out the account.
// So when we sync commands, we're gonna need a delegate of some kind.
open class WipeCommand: Command {

    public init?(command: String, args: [JSON]) {
        return nil
    }

    open class func fromName(_ command: String, args: [JSON]) -> Command? {
        return WipeCommand(command: command, args: args)
    }

    open func run(_ synchronizer: ClientsSynchronizer) -> Success {
        return succeed()
    }

    public static func commandFromSyncCommand(_ syncCommand: SyncCommand) -> Command? {
        let json = JSON(parseJSON: syncCommand.value)
        if let name = json["command"].string,
            let args = json["args"].array {
                return WipeCommand.fromName(name, args: args)
        }
        return nil
    }
}

open class DisplayURICommand: Command {
    let uri: URL
    let title: String
    let sender: String

    public init?(command: String, args: [JSON]) {
        if let uri = args[0].string?.asURL,
            let sender = args[1].string,
            let title = args[2].string {
            self.uri = uri
            self.sender = sender
            self.title = title
        } else {
            // Oh, Swift.
            self.uri = "http://localhost/".asURL!
            self.title = ""
            return nil
        }
    }

    open class func fromName(_ command: String, args: [JSON]) -> Command? {
        return DisplayURICommand(command: command, args: args)
    }

    open func run(_ synchronizer: ClientsSynchronizer) -> Success {
        func display(_ deviceName: String? = nil) -> Success {
            synchronizer.delegate.displaySentTab(for: uri, title: title, from: deviceName)
            return succeed()
        }

        guard let sender = synchronizer.localClients?.getClient(guid: sender) else {
            return display()
        }

        return sender >>== { client in
            return display(client?.name)
        }
    }

    public static func commandFromSyncCommand(_ syncCommand: SyncCommand) -> Command? {
        let json = JSON(parseJSON: syncCommand.value)
        if let name = json["command"].string,
            let args = json["args"].array {
                return DisplayURICommand.fromName(name, args: args)
        }
        return nil
    }
}

//let Commands: [String: (String, [JSON]) -> Command?] = [
//    "wipeAll": WipeCommand.fromName,
//    "wipeEngine": WipeCommand.fromName,
//    // resetEngine
//    // resetAll
//    // logout
//    "displayURI": DisplayURICommand.fromName,
//    // repairResponse
//]

open class ClientsSynchronizer: TimestampedSingleCollectionSynchronizer, Synchronizer {
    public required init(scratchpad: Scratchpad, delegate: SyncDelegate, basePrefs: Prefs, why: SyncReason) {
        super.init(scratchpad: scratchpad, delegate: delegate, basePrefs: basePrefs, why: why, collection: "clients")
    }

    var localClients: RemoteClientsAndTabs?

    override var storageVersion: Int {
        return ClientsStorageVersion
    }

    // Sync Object Format (Version 1) for Form Factors: http://docs.services.mozilla.com/sync/objectformats.html#id2
    fileprivate enum SyncFormFactorFormat: String {
        case phone = "phone"
        case tablet = "tablet"
    }


    fileprivate func formFactorString() -> String {
        let userInterfaceIdiom = UIDevice.current.userInterfaceIdiom
        var formfactor: String

        switch userInterfaceIdiom {
        case .phone:
            formfactor = SyncFormFactorFormat.phone.rawValue
        case .pad:
            formfactor = SyncFormFactorFormat.tablet.rawValue
        default:
            formfactor = SyncFormFactorFormat.phone.rawValue
        }

        return formfactor
    }

}
