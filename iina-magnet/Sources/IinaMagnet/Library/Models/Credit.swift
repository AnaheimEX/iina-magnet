//
//  Credit.swift
//  IinaMagnet
//
//  A cast credit on a Title (Phase 2, Issue 07): a voice actor (声优) and the
//  character they play (角色), for the archive page's 演职员 row. Populated from
//  Bangumi's characters API; only present when the source has cast data.

import Foundation
import SwiftData

@Model
public final class Credit {

    public var actorName: String        // 声优
    public var characterName: String?   // 角色
    public var order: Int               // display order (source ordering)

    public var title: Title?

    public init(actorName: String, characterName: String? = nil, order: Int) {
        self.actorName = actorName
        self.characterName = characterName
        self.order = order
    }
}
