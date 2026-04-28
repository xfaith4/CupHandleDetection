import express from "express";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const app = express();
const port = Number(process.env.PORT || 3001);
const docsUrl = "https://www.alphavantage.co/documentation/";
const vaultDir = path.join(__dirname, "data");
const workspaceVaultPath = path.join(vaultDir, "workspace-vault.json");

app.use(express.json({ limit: "2mb" }));

function sanitizeTicker(value) {
  return String(value || "")
    .toUpperCase()
    .replace(/[^A-Z0-9.-]/g, "")
    .slice(0, 16);
}

function jsonError(res, status, message, detail = "") {
  res.status(status).json({
    ok: false,
    provider: "Alpha Vantage",
    docsUrl,
    message,
    detail,
  });
}

function workspaceJsonError(res, status, message, detail = "") {
  res.status(status).json({
    ok: false,
    message,
    detail,
  });
}

function isObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function sanitizeWorkspaceName(value) {
  return String(value || "")
    .trim()
    .replace(/\s+/g, " ")
    .slice(0, 80);
}

function createId() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `ws-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

async function readWorkspaceVault() {
  try {
    const raw = await fsp.readFile(workspaceVaultPath, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed?.snapshots) ? parsed : { snapshots: [] };
  } catch (error) {
    if (error && typeof error === "object" && error.code === "ENOENT") {
      return { snapshots: [] };
    }
    throw error;
  }
}

async function writeWorkspaceVault(vault) {
  await fsp.mkdir(vaultDir, { recursive: true });
  await fsp.writeFile(workspaceVaultPath, JSON.stringify(vault, null, 2), "utf8");
}

function validateWorkspacePayload(workspace) {
  if (!isObject(workspace)) {
    return "Workspace payload is required.";
  }
  if (!Array.isArray(workspace.stocks) || workspace.stocks.length === 0) {
    return "Workspace must include at least one ticker.";
  }
  if (typeof workspace.selectedTicker !== "string" || !workspace.selectedTicker.trim()) {
    return "Workspace must include a selected ticker.";
  }
  return "";
}

function buildSnapshotMetadata(snapshot) {
  const workspace = isObject(snapshot?.workspace) ? snapshot.workspace : {};
  const historyByTicker = isObject(workspace.historyByTicker) ? workspace.historyByTicker : {};
  const liveMarketByTicker = isObject(workspace.liveMarketByTicker)
    ? workspace.liveMarketByTicker
    : {};

  const latestHistoryDate = Object.values(historyByTicker)
    .map((rows) => (Array.isArray(rows) ? rows[rows.length - 1]?.date || "" : ""))
    .filter(Boolean)
    .sort()
    .at(-1);

  return {
    id: snapshot.id,
    name: snapshot.name,
    createdAt: snapshot.createdAt,
    updatedAt: snapshot.updatedAt,
    selectedTicker: String(workspace.selectedTicker || ""),
    tickerCount: Array.isArray(workspace.stocks) ? workspace.stocks.length : 0,
    importedTickerCount: Object.values(historyByTicker).filter(
      (rows) => Array.isArray(rows) && rows.length > 0,
    ).length,
    liveTickerCount: Object.values(liveMarketByTicker).filter(
      (entry) => isObject(entry) && entry.sourceType === "live_market_feed",
    ).length,
    latestHistoryDate: latestHistoryDate || "",
  };
}

function getTimeSeriesKey(payload) {
  return Object.keys(payload).find((key) => key.toLowerCase().includes("time series"));
}

function toNumber(value) {
  const next = Number(value);
  return Number.isFinite(next) ? next : null;
}

async function fetchAlphaVantageJson(url) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "cup-n-handle-workbench/0.1",
    },
  });

  if (!response.ok) {
    throw new Error(`Alpha Vantage request failed with status ${response.status}`);
  }

  return response.json();
}

function parseSnapshot(ticker, quotePayload, historyPayload) {
  if (quotePayload.Note || historyPayload.Note) {
    throw new Error(
      quotePayload.Note ||
        historyPayload.Note ||
        "Alpha Vantage rate limit reached. Please retry shortly.",
    );
  }

  if (quotePayload.Information || historyPayload.Information) {
    throw new Error(quotePayload.Information || historyPayload.Information);
  }

  if (quotePayload["Error Message"] || historyPayload["Error Message"]) {
    throw new Error(quotePayload["Error Message"] || historyPayload["Error Message"]);
  }

  const quote = quotePayload["Global Quote"] || {};
  const timeSeriesKey = getTimeSeriesKey(historyPayload);
  const rawSeries = timeSeriesKey ? historyPayload[timeSeriesKey] : null;

  if (!rawSeries || typeof rawSeries !== "object") {
    throw new Error("Daily time series was missing from the market-data response.");
  }

  const rows = Object.entries(rawSeries)
    .map(([date, point], index) => ({
      index: index + 1,
      date,
      close: toNumber(point["4. close"]),
      open: toNumber(point["1. open"]),
      high: toNumber(point["2. high"]),
      low: toNumber(point["3. low"]),
      volume: toNumber(point["5. volume"]),
    }))
    .filter((row) => row.close && row.close > 0)
    .sort((left, right) => left.date.localeCompare(right.date));

  if (!rows.length) {
    throw new Error("No valid daily rows were returned for this ticker.");
  }

  const latestRow = rows[rows.length - 1];
  const currentPrice = toNumber(quote["05. price"]) ?? latestRow.close;
  const latestTradingDay = quote["07. latest trading day"] || latestRow.date;
  const peakPrice = Math.max(...rows.map((row) => row.close));

  return {
    ok: true,
    provider: "Alpha Vantage",
    docsUrl,
    symbol: ticker,
    fetchedAt: new Date().toISOString(),
    quote: {
      currentPrice,
      latestTradingDay,
      previousClose: toNumber(quote["08. previous close"]),
      changePercent: quote["10. change percent"] || "",
    },
    history: {
      rows: rows.map(({ index, date, close }) => ({ index, date, close })),
      peakPrice,
      startDate: rows[0].date,
      endDate: latestRow.date,
    },
  };
}

app.get("/api/market/status", (_req, res) => {
  res.json({
    ok: true,
    provider: "Alpha Vantage",
    docsUrl,
    configured: Boolean(process.env.ALPHA_VANTAGE_API_KEY),
    message: process.env.ALPHA_VANTAGE_API_KEY
      ? "Live market feed is configured."
      : "Set ALPHA_VANTAGE_API_KEY to enable live market sync for all tickers.",
  });
});

app.get("/api/market/snapshot", async (req, res) => {
  const ticker = sanitizeTicker(req.query.ticker);

  if (!ticker) {
    return jsonError(res, 400, "Ticker is required.", "Provide ?ticker=MSFT or another symbol.");
  }

  const configuredKey = process.env.ALPHA_VANTAGE_API_KEY;
  const apiKey = configuredKey || "";

  if (!apiKey) {
    return jsonError(
      res,
      503,
      "Live market feed is not configured.",
      "Set ALPHA_VANTAGE_API_KEY in your environment to enable provider-backed sync.",
    );
  }

  try {
    const quoteUrl = `https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=${encodeURIComponent(
      ticker,
    )}&apikey=${encodeURIComponent(apiKey)}`;
    const historyUrl = `https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=${encodeURIComponent(
      ticker,
    )}&outputsize=compact&apikey=${encodeURIComponent(apiKey)}`;

    const [quotePayload, historyPayload] = await Promise.all([
      fetchAlphaVantageJson(quoteUrl),
      fetchAlphaVantageJson(historyUrl),
    ]);

    return res.json(parseSnapshot(ticker, quotePayload, historyPayload));
  } catch (error) {
    return jsonError(
      res,
      502,
      `Market sync failed for ${ticker}.`,
      error instanceof Error ? error.message : "Unknown provider failure",
    );
  }
});

app.get("/api/workspaces/status", async (_req, res) => {
  try {
    const vault = await readWorkspaceVault();
    return res.json({
      ok: true,
      available: true,
      message: "Server-backed workspace vault is available.",
      storagePath: workspaceVaultPath,
      snapshotCount: vault.snapshots.length,
    });
  } catch (error) {
    return workspaceJsonError(
      res,
      500,
      "Workspace vault status could not be loaded.",
      error instanceof Error ? error.message : "Unknown workspace vault failure",
    );
  }
});

app.get("/api/workspaces", async (_req, res) => {
  try {
    const vault = await readWorkspaceVault();
    const snapshots = vault.snapshots
      .map((snapshot) => buildSnapshotMetadata(snapshot))
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));

    return res.json({
      ok: true,
      snapshots,
      snapshotCount: snapshots.length,
    });
  } catch (error) {
    return workspaceJsonError(
      res,
      500,
      "Workspace snapshots could not be loaded.",
      error instanceof Error ? error.message : "Unknown workspace vault failure",
    );
  }
});

app.get("/api/workspaces/:id", async (req, res) => {
  try {
    const vault = await readWorkspaceVault();
    const snapshot = vault.snapshots.find((entry) => entry.id === req.params.id);

    if (!snapshot) {
      return workspaceJsonError(
        res,
        404,
        "Workspace snapshot was not found.",
        "Refresh the vault list and try again.",
      );
    }

    return res.json({
      ok: true,
      snapshot: {
        ...buildSnapshotMetadata(snapshot),
        workspace: snapshot.workspace,
      },
    });
  } catch (error) {
    return workspaceJsonError(
      res,
      500,
      "Workspace snapshot could not be opened.",
      error instanceof Error ? error.message : "Unknown workspace vault failure",
    );
  }
});

app.post("/api/workspaces", async (req, res) => {
  const workspace = req.body?.workspace;
  const validationError = validateWorkspacePayload(workspace);
  const name = sanitizeWorkspaceName(req.body?.name);

  if (validationError) {
    return workspaceJsonError(res, 400, validationError);
  }
  if (!name) {
    return workspaceJsonError(res, 400, "Workspace name is required.");
  }

  try {
    const vault = await readWorkspaceVault();
    const now = new Date().toISOString();
    const existingIndex = vault.snapshots.findIndex((entry) => entry.id === req.body?.id);
    const existingSnapshot = existingIndex >= 0 ? vault.snapshots[existingIndex] : null;
    const snapshot = {
      id: existingSnapshot?.id || createId(),
      name,
      createdAt: existingSnapshot?.createdAt || now,
      updatedAt: now,
      workspace,
    };

    if (existingIndex >= 0) {
      vault.snapshots.splice(existingIndex, 1, snapshot);
    } else {
      vault.snapshots.push(snapshot);
    }

    await writeWorkspaceVault(vault);

    return res.json({
      ok: true,
      message:
        existingIndex >= 0
          ? `${name} was updated in the workspace vault.`
          : `${name} was saved to the workspace vault.`,
      snapshot: buildSnapshotMetadata(snapshot),
      snapshotCount: vault.snapshots.length,
    });
  } catch (error) {
    return workspaceJsonError(
      res,
      500,
      "Workspace snapshot could not be saved.",
      error instanceof Error ? error.message : "Unknown workspace vault failure",
    );
  }
});

app.delete("/api/workspaces/:id", async (req, res) => {
  try {
    const vault = await readWorkspaceVault();
    const snapshot = vault.snapshots.find((entry) => entry.id === req.params.id);

    if (!snapshot) {
      return workspaceJsonError(
        res,
        404,
        "Workspace snapshot was not found.",
        "Refresh the vault list and try again.",
      );
    }

    const nextVault = {
      snapshots: vault.snapshots.filter((entry) => entry.id !== req.params.id),
    };
    await writeWorkspaceVault(nextVault);

    return res.json({
      ok: true,
      message: `${snapshot.name} was removed from the workspace vault.`,
      snapshotCount: nextVault.snapshots.length,
    });
  } catch (error) {
    return workspaceJsonError(
      res,
      500,
      "Workspace snapshot could not be deleted.",
      error instanceof Error ? error.message : "Unknown workspace vault failure",
    );
  }
});

const distPath = path.join(__dirname, "dist");
if (fs.existsSync(path.join(distPath, "index.html"))) {
  app.use(express.static(distPath));
  app.get("/{*path}", (_req, res) => {
    res.sendFile(path.join(distPath, "index.html"));
  });
}

app.listen(port, () => {
  console.log(`Market data server listening on http://localhost:${port}`);
});
