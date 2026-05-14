//
//  LoginResponse.swift
//  StrawberryPlayer
//
//  Created by penghui zhang on 2026/2/26.
//

struct LoginResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
}
