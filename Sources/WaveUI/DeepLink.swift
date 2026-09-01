// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Deep links (`wave-native://<otype>/<oid>`): resource-style URLs that open the
// referenced object — raise its workspace's window, select its tab, focus the
// pane. The URL names a RESOURCE, never an action ("open" is the dereference,
// like any web URL), and carries only the object id: block→tab→workspace
// containment is resolved at open time, so a link survives the pane being
// dragged to another tab or the tab to another workspace.

import Foundation
import WaveCore

public enum DeepLink: Equatable, Sendable {
    case block(String)
    case tab(String)
    case workspace(String)

    /// Registered by the app bundle (`scripts/bundle-app.sh` CFBundleURLTypes).
    public static let scheme = "wave-native"

    /// Canonical URL string for this resource (the copy-link / share format).
    public var urlString: String {
        switch self {
        case .block(let id): return "\(Self.scheme)://\(OType.block)/\(id)"
        case .tab(let id): return "\(Self.scheme)://\(OType.tab)/\(id)"
        case .workspace(let id): return "\(Self.scheme)://\(OType.workspace)/\(id)"
        }
    }

    /// Parse `wave-native://block/<id>`, `…://tab/<id>`, `…://workspace/<id>`.
    /// The resource kind rides in the URL host, the id as the single path
    /// component. Returns nil for any other scheme, kind, or shape.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        switch url.host?.lowercased() {
        case OType.block: return .block(id)
        case OType.tab: return .tab(id)
        case OType.workspace: return .workspace(id)
        default: return nil
        }
    }
}

/// A deep link resolved to its containing UI location. `tabId`/`blockId` are nil
/// for links to the coarser resources (a workspace link has neither).
public struct DeepLinkLocation: Equatable, Sendable {
    public let workspaceId: String
    public let tabId: String?
    public let blockId: String?

    public init(workspaceId: String, tabId: String?, blockId: String?) {
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.blockId = blockId
    }
}

/// Resolves a deep link to its containing location at open time — the URL
/// carries only the object id, so a link keeps working after the pane or tab
/// moves. Shared by the open path (AppCoordinator) and the tasks pane's
/// pasted-link mentions. Returns nil when the target no longer exists.
@MainActor
struct DeepLinkResolver {
    let store: ObjectStoreProtocol
    let service: ServiceClient

    func resolve(_ link: DeepLink) async -> DeepLinkLocation? {
        switch link {
        case .workspace(let wsId):
            guard let list = try? await service.listWorkspaces(),
                  list.contains(where: { $0.workspaceid == wsId }) else { return nil }
            return DeepLinkLocation(workspaceId: wsId, tabId: nil, blockId: nil)
        case .tab(let tabId):
            guard let wsId = await owningWorkspaceId(ofTab: tabId) else { return nil }
            return DeepLinkLocation(workspaceId: wsId, tabId: tabId, blockId: nil)
        case .block(let blockId):
            guard let tabId = await owningTabId(ofBlock: blockId),
                  let wsId = await owningWorkspaceId(ofTab: tabId) else { return nil }
            return DeepLinkLocation(workspaceId: wsId, tabId: tabId, blockId: blockId)
        }
    }

    /// Sub-blocks parent to their owner block, so walk `parentoref` up (bounded)
    /// to the owning tab. Always re-fetches: a cached block of another window's
    /// tab may hold a stale parent from before a cross-tab pane move.
    func owningTabId(ofBlock blockId: String) async -> String? {
        var oref = ORef.block(blockId)
        for _ in 0..<8 {
            let obj = (try? await store.loadMany([oref]))?.first ?? store.get(oref)
            guard let block = obj?.asBlock,
                  let parent = ORef(string: block.parentoref ?? "") else { return nil }
            if parent.otype == OType.tab { return parent.oid }
            guard parent.otype == OType.block else { return nil }
            oref = parent
        }
        return nil
    }

    /// Workspace whose `tabids` holds `tabId`. Re-fetches every workspace object
    /// (the count is small, and cached copies of other windows' workspaces go
    /// stale) rather than trusting the store cache.
    func owningWorkspaceId(ofTab tabId: String) async -> String? {
        guard let list = try? await service.listWorkspaces(), !list.isEmpty else { return nil }
        let orefs = list.map { ORef.workspace($0.workspaceid) }
        guard let objs = try? await store.loadMany(orefs) else { return nil }
        return objs.compactMap { $0.asWorkspace }
            .first { $0.tabids.contains(tabId) }?.oid
    }
}
