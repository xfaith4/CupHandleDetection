import { requestJson } from "./apiClient.js";

export function fetchMarketFeedStatus() {
  return requestJson("/api/market/status");
}

export function fetchMarketSnapshot(ticker) {
  return requestJson(`/api/market/snapshot?ticker=${encodeURIComponent(ticker)}`);
}
