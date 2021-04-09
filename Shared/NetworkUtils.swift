/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Network
import SwiftyJSON

public func makeURLSession(userAgent: String, configuration: URLSessionConfiguration, timeout: TimeInterval? = nil) -> URLSession {
    configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
    if let t = timeout {
        configuration.timeoutIntervalForRequest = t
    }
    return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
}

// Used to help replace Alamofire's response.validate()
public func validatedHTTPResponse(_ response: URLResponse?, contentType: String? = nil, statusCode: Range<Int>?  = nil) -> HTTPURLResponse? {
    if let response = response as? HTTPURLResponse {
        if let range = statusCode {
            return range.contains(response.statusCode) ? response : nil
        }
        if let type = contentType {
            if let responseType = response.allHeaderFields["Content-Type"] as? String {
                return responseType.contains(type) ? response : nil
            }
            return nil
        }
        return response
    }
    return nil
}

