/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Shared
import Foundation
import SwiftyJSON

public struct TokenServerToken {
    public let id: String
    public let key: String
    public let api_endpoint: String
    public let uid: UInt64
    public let hashedFxAUID: String
    public let durationInSeconds: UInt64
    // A healthy token server reports its timestamp.
    public let remoteTimestamp: Timestamp

    /**
     * Return true if this token points to the same place as the other token.
     */
    public func sameDestination(_ other: TokenServerToken) -> Bool {
        return self.uid == other.uid &&
               self.api_endpoint == other.api_endpoint
    }

    public static func fromJSON(_ json: JSON) -> TokenServerToken? {
        if let
            id = json["id"].string,
            let key = json["key"].string,
            let api_endpoint = json["api_endpoint"].string,
            let uid = json["uid"].int64,
            let hashedFxAUID = json["hashed_fxa_uid"].string,
            let durationInSeconds = json["duration"].int64,
            let remoteTimestamp = json["remoteTimestamp"].int64 {
                return TokenServerToken(id: id, key: key, api_endpoint: api_endpoint, uid: UInt64(uid),
                                        hashedFxAUID: hashedFxAUID, durationInSeconds: UInt64(durationInSeconds),
                                        remoteTimestamp: Timestamp(remoteTimestamp))
        }
        return nil
    }

    public func asJSON() -> JSON {
        let D: [String: AnyObject] = [
            "id": id as AnyObject,
            "key": key as AnyObject,
            "api_endpoint": api_endpoint as AnyObject,
            "uid": NSNumber(value: uid as UInt64),
            "hashed_fxa_uid": hashedFxAUID as AnyObject,
            "duration": NSNumber(value: durationInSeconds as UInt64),
            "remoteTimestamp": NSNumber(value: remoteTimestamp),
        ]
        return JSON(D as NSDictionary)
    }
}

