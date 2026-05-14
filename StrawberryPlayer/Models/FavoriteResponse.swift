//
//  FavoriteResponse.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/2/26.
//

import Foundation

struct FavoriteResponse: Codable {
    let id: UUID
    let songIdentifier: String
    let songTitle: String
    let songArtist: String
    let createdAt: Date
}
