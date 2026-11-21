import Foundation

extension ToolExecutor {
    /// Reads or sets the NUEDIT project this editor project registers footage under.
    func towerLink(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["projectId", "clear"], path: "tower_link")
        let clear = args["clear"] as? Bool ?? false
        let projectId = args.string("projectId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(clear && projectId?.isEmpty == false) else {
            throw ToolError("tower_link: pass projectId or clear, not both.")
        }
        if let projectId, projectId.isEmpty {
            throw ToolError("tower_link: projectId must not be empty. Pass clear: true to unlink.")
        }

        var changed = false
        if clear {
            changed = editor.towerProjectId != nil
            editor.towerProjectId = nil
        } else if let projectId {
            changed = editor.towerProjectId != projectId
            editor.towerProjectId = projectId
        }
        if changed { editor.onProjectCheckpointRequired?() }
        // Linking is the retry, even to the same project: anything interrupted or prepared offline goes now.
        if projectId != nil, editor.towerProjectId != nil { editor.ingest.registerPendingFootage() }

        let backend = await NUEDITBackendClient.shared.currentSettings()
        var payload: [String: Any] = [
            "linked": editor.towerProjectId != nil,
            "changed": changed,
            "backendConfigured": backend.isConfigured,
            "agentKeyConfigured": backend.agentKey != nil,
            "footage": ingestSummary(editor),
            "originals": archiveSummary(editor),
        ]
        if let id = editor.towerProjectId { payload["projectId"] = id }
        if let baseURL = backend.baseURL { payload["backendURL"] = baseURL.absoluteString }
        if editor.towerProjectId == nil {
            payload["note"] = "Not linked — footage is identified and proxied locally but nothing is sent."
        } else if !backend.isConfigured {
            payload["note"] = "Linked, but no tower address is configured on this Mac, so nothing can be sent yet."
        } else if backend.agentKey == nil {
            payload["note"] = "Linked, but this Mac has no agent key for the tower, so registration will fail. Add one in Settings → Tower."
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    /// Whether each registered camera original has a verified copy in the tower's S3 archive.
    private func archiveSummary(_ editor: EditorViewModel) -> [String: Any] {
        var archived = 0, inFlight = 0, failed = 0, waiting = 0
        var issues: [[String: Any]] = []
        let outcomes = editor.ingest.archiveOutcomes
        for asset in editor.mediaAssets where IngestCoordinator.isEligible(asset) && asset.footageId != nil {
            let outcome = outcomes[asset.id]
            if editor.ingest.isArchiving(assetId: asset.id) {
                inFlight += 1
                continue
            }
            if asset.originalArchiveURI != nil || outcome == .alreadyArchived {
                archived += 1
                continue
            }
            switch outcome {
            case .failed(let reason):
                failed += 1
                issues.append(["assetId": asset.id, "name": asset.name, "state": "failed", "reason": reason])
            case .skipped(let reason):
                waiting += 1
                issues.append(["assetId": asset.id, "name": asset.name, "state": "waiting", "reason": reason])
            case .archived, .alreadyArchived, nil:
                waiting += 1
            }
        }
        return [
            "archived": archived,
            "inFlight": inFlight,
            "waiting": waiting,
            "failed": failed,
            "issues": issues,
        ]
    }

    /// How far the library has got through ingest — the honest counterpart to a bare "linked: true".
    private func ingestSummary(_ editor: EditorViewModel) -> [String: Any] {
        var identified = 0, registered = 0, failed = 0, pending = 0
        for asset in editor.mediaAssets where IngestCoordinator.isEligible(asset) {
            if asset.footageIdentity != nil { identified += 1 }
            switch asset.ingestStatus {
            case .registered: registered += 1
            case .failed: failed += 1
            case .queued, .identifying, .proxying, .uploading: pending += 1
            case .none, .local: break
            }
        }
        return [
            "eligible": editor.mediaAssets.filter(IngestCoordinator.isEligible).count,
            "identified": identified,
            "registered": registered,
            "inFlight": pending,
            "failed": failed,
        ]
    }
}
