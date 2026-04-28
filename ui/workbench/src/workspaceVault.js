import { requestJson } from "./apiClient.js";

export function fetchWorkspaceVaultStatus() {
  return requestJson("/api/workspaces/status");
}

export function listWorkspaceSnapshots() {
  return requestJson("/api/workspaces");
}

export function loadWorkspaceSnapshot(snapshotId) {
  return requestJson(`/api/workspaces/${encodeURIComponent(snapshotId)}`);
}

export function saveWorkspaceSnapshot(payload) {
  return requestJson("/api/workspaces", {
    method: "POST",
    body: payload,
  });
}

export function deleteWorkspaceSnapshot(snapshotId) {
  return requestJson(`/api/workspaces/${encodeURIComponent(snapshotId)}`, {
    method: "DELETE",
  });
}
