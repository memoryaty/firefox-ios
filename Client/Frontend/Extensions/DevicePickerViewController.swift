
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Shared
import Storage
import SnapKit
import Account


public enum ClientType: String {
    case Desktop = "deviceTypeDesktop"
    case Mobile = "deviceTypeMobile"
    case Tablet = "deviceTypeTablet"
    case VR = "deviceTypeVR"
    case TV = "deviceTypeTV"

    static func fromFxAType(_ type: String?) -> ClientType {
        switch type {
        case "desktop":
            return ClientType.Desktop
        case "mobile":
            return ClientType.Mobile
        case "tablet":
            return ClientType.Tablet
        case "vr":
            return ClientType.VR
        case "tv":
            return ClientType.TV
        default:
            return ClientType.Mobile
        }
    }
}
