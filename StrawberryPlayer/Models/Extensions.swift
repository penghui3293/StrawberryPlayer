//
//  Extensions.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/4/6.
//

import Foundation

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
