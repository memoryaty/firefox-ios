/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared

enum InstallType: String, Codable {
    case fresh
    case upgrade
    case unknown
    
    // Helper methods
    static func get() -> InstallType {
        guard let rawValue = UserDefaults.standard.string(forKey: PrefsKeys.InstallType), let type = InstallType(rawValue: rawValue) else {
            return unknown
        }
        return type
    }
    
    static func set(type: InstallType) {
        UserDefaults.standard.set(type.rawValue, forKey: PrefsKeys.InstallType)
    }
    
    static func persistedCurrentVersion() -> String {
        guard let currentVersion = UserDefaults.standard.string(forKey: PrefsKeys.KeyCurrentInstallVersion) else {
            return ""
        }
        return currentVersion
    }
    
    static func updateCurrentVersion(version: String) {
        UserDefaults.standard.set(version, forKey: PrefsKeys.KeyCurrentInstallVersion)
    }
}
