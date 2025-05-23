//
//  Connection.swift
//  r2-lcp-swift
//
//  Created by Mickaël Menu on 06.05.19.
//
//  Copyright 2019 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import SQLite

extension Connection {
    
    /// FIXME: Used to fix a crash with SQLite.swift pre Xcode 10.2.1.
    /// We can't use the version 0.11.6 before Xcode 10.2, but the version 0.11.5 crashes on Xcode 10.2 (ie. https://github.com/stephencelis/SQLite.swift/issues/888)
    func count(_ expressible: Expressible) throws -> Int64 {
        let sql = "SELECT COUNT(*) FROM (\(expressible)) AS countable;"
        return (try scalar(sql) as? Int64) ?? 0
    }
    
}
