import React, {
  Suspense,
  useDeferredValue,
  useEffect,
  useEffectEvent,
  lazy,
  useMemo,
  useState,
  startTransition,
} from "react";
import { fetchMarketFeedStatus, fetchMarketSnapshot } from "./marketData.js";
import {
  deleteWorkspaceSnapshot,
  fetchWorkspaceVaultStatus,
  listWorkspaceSnapshots,
  loadWorkspaceSnapshot,
  saveWorkspaceSnapshot,
} from "./workspaceVault.js";

const WorkbenchChart = lazy(() => import("./WorkbenchCharts.jsx"));

const STORAGE_KEY = "cup-handle-workbench:v1";
const MAX_HEALTH_EVENTS = 8;

const WEIGHTS = Object.freeze({
  decline_reason: 30,
  prior_uptrend: 15,
  decline_depth: 20,
  decline_shape: 10,
  volume_profile: 10,
  fundamentals: 10,
  sector_type: 5,
});

const DeclineReason = Object.freeze({
  MACRO_SENTIMENT: "macro_sentiment",
  FUNDAMENTAL: "fundamental",
  UNKNOWN: "unknown",
});

const DeclineShape = Object.freeze({
  GRADUAL_ROUNDED: "gradual_rounded",
  VERTICAL_CLIFF: "vertical_cliff",
  MIXED: "mixed",
});

const SectorType = Object.freeze({
  CYCLICAL: "cyclical",
  STRUCTURAL: "structural",
});

const CupStage = Object.freeze({
  LEFT_SIDE_EARLY: "left_side_early",
  LEFT_SIDE_LATE: "left_side_late",
  CUP_BOTTOM: "cup_bottom",
  RIGHT_SIDE: "right_side",
  HANDLE: "handle",
  BREAKOUT: "breakout",
  INDETERMINATE: "indeterminate",
});

const STAGE_META = {
  [CupStage.LEFT_SIDE_EARLY]: {
    label: "Left Side Early",
    tone: "neutral",
    multiplier: 0.18,
  },
  [CupStage.LEFT_SIDE_LATE]: {
    label: "Left Side Late",
    tone: "watch",
    multiplier: 0.28,
  },
  [CupStage.CUP_BOTTOM]: {
    label: "Cup Bottom",
    tone: "watch",
    multiplier: 0.44,
  },
  [CupStage.RIGHT_SIDE]: {
    label: "Right Side",
    tone: "good",
    multiplier: 0.66,
  },
  [CupStage.HANDLE]: {
    label: "Handle",
    tone: "good",
    multiplier: 0.86,
  },
  [CupStage.BREAKOUT]: {
    label: "Breakout",
    tone: "strong",
    multiplier: 1,
  },
  [CupStage.INDETERMINATE]: {
    label: "Indeterminate",
    tone: "warning",
    multiplier: 0.2,
  },
};

const SEVERITY_WEIGHT = {
  info: 1,
  warning: 2,
  error: 3,
};

const DEFAULT_HISTORY_INPUT = `date,close
2026-01-05,238
2026-01-12,232
2026-01-20,225
2026-01-27,219
2026-02-03,214
2026-02-10,210
2026-02-18,208
2026-02-25,209
2026-03-03,211
2026-03-10,214
2026-03-17,218
2026-03-24,221
2026-03-31,224`;

const DEFAULT_STOCKS = [
  {
    ticker: "AMZN",
    decline_reason: DeclineReason.MACRO_SENTIMENT,
    had_clear_prior_uptrend: true,
    peak_price: 245,
    current_price: 224,
    decline_shape: DeclineShape.GRADUAL_ROUNDED,
    volume_drying_up_at_bottom: true,
    volume_picking_up_on_right_side: true,
    fundamentals_score: 5,
    sector_type: SectorType.CYCLICAL,
    weeks_sideways_at_bottom: 4,
  },
  {
    ticker: "MSFT",
    decline_reason: DeclineReason.MACRO_SENTIMENT,
    had_clear_prior_uptrend: true,
    peak_price: 525,
    current_price: 381,
    decline_shape: DeclineShape.VERTICAL_CLIFF,
    volume_drying_up_at_bottom: false,
    volume_picking_up_on_right_side: false,
    fundamentals_score: 5,
    sector_type: SectorType.CYCLICAL,
    weeks_sideways_at_bottom: 1,
  },
  {
    ticker: "NVDA",
    decline_reason: DeclineReason.MACRO_SENTIMENT,
    had_clear_prior_uptrend: true,
    peak_price: 188,
    current_price: 168,
    decline_shape: DeclineShape.GRADUAL_ROUNDED,
    volume_drying_up_at_bottom: true,
    volume_picking_up_on_right_side: true,
    fundamentals_score: 5,
    sector_type: SectorType.CYCLICAL,
    weeks_sideways_at_bottom: 3,
  },
  {
    ticker: "JPM",
    decline_reason: DeclineReason.MACRO_SENTIMENT,
    had_clear_prior_uptrend: true,
    peak_price: 333,
    current_price: 304,
    decline_shape: DeclineShape.MIXED,
    volume_drying_up_at_bottom: null,
    volume_picking_up_on_right_side: null,
    fundamentals_score: 4,
    sector_type: SectorType.CYCLICAL,
    weeks_sideways_at_bottom: 2,
  },
  {
    ticker: "GOOGL",
    decline_reason: DeclineReason.MACRO_SENTIMENT,
    had_clear_prior_uptrend: true,
    peak_price: 344,
    current_price: 303,
    decline_shape: DeclineShape.VERTICAL_CLIFF,
    volume_drying_up_at_bottom: false,
    volume_picking_up_on_right_side: false,
    fundamentals_score: 5,
    sector_type: SectorType.CYCLICAL,
    weeks_sideways_at_bottom: 0,
  },
  {
    ticker: "WMT",
    decline_reason: DeclineReason.MACRO_SENTIMENT,
    had_clear_prior_uptrend: true,
    peak_price: 130,
    current_price: 124.5,
    decline_shape: DeclineShape.GRADUAL_ROUNDED,
    volume_drying_up_at_bottom: true,
    volume_picking_up_on_right_side: false,
    fundamentals_score: 4,
    sector_type: SectorType.CYCLICAL,
    weeks_sideways_at_bottom: 5,
  },
  {
    ticker: "INTC",
    decline_reason: DeclineReason.FUNDAMENTAL,
    had_clear_prior_uptrend: false,
    peak_price: 51,
    current_price: 19,
    decline_shape: DeclineShape.VERTICAL_CLIFF,
    volume_drying_up_at_bottom: false,
    volume_picking_up_on_right_side: false,
    fundamentals_score: 1,
    sector_type: SectorType.STRUCTURAL,
    weeks_sideways_at_bottom: 0,
  },
];

const DEMO_HISTORY = {
  AMZN: buildHistorySeries([
    ["2026-01-05", 238],
    ["2026-01-12", 232],
    ["2026-01-20", 225],
    ["2026-01-27", 219],
    ["2026-02-03", 214],
    ["2026-02-10", 210],
    ["2026-02-18", 208],
    ["2026-02-25", 209],
    ["2026-03-03", 211],
    ["2026-03-10", 214],
    ["2026-03-17", 218],
    ["2026-03-24", 221],
    ["2026-03-31", 224],
  ]),
  MSFT: buildHistorySeries([
    ["2026-01-05", 520],
    ["2026-01-12", 509],
    ["2026-01-20", 488],
    ["2026-01-27", 460],
    ["2026-02-03", 430],
    ["2026-02-10", 402],
    ["2026-02-18", 384],
    ["2026-02-25", 372],
    ["2026-03-03", 368],
    ["2026-03-10", 370],
    ["2026-03-17", 373],
    ["2026-03-24", 377],
    ["2026-03-31", 381],
  ]),
  NVDA: buildHistorySeries([
    ["2026-01-05", 188],
    ["2026-01-12", 176],
    ["2026-01-20", 165],
    ["2026-01-27", 154],
    ["2026-02-03", 147],
    ["2026-02-10", 140],
    ["2026-02-18", 136],
    ["2026-02-25", 137],
    ["2026-03-03", 141],
    ["2026-03-10", 148],
    ["2026-03-17", 156],
    ["2026-03-24", 162],
    ["2026-03-31", 168],
  ]),
  JPM: buildHistorySeries([
    ["2026-01-05", 330],
    ["2026-01-12", 325],
    ["2026-01-20", 318],
    ["2026-01-27", 308],
    ["2026-02-03", 301],
    ["2026-02-10", 295],
    ["2026-02-18", 291],
    ["2026-02-25", 292],
    ["2026-03-03", 294],
    ["2026-03-10", 297],
    ["2026-03-17", 299],
    ["2026-03-24", 301],
    ["2026-03-31", 304],
  ]),
  GOOGL: buildHistorySeries([
    ["2026-01-05", 340],
    ["2026-01-12", 334],
    ["2026-01-20", 325],
    ["2026-01-27", 313],
    ["2026-02-03", 302],
    ["2026-02-10", 294],
    ["2026-02-18", 289],
    ["2026-02-25", 288],
    ["2026-03-03", 290],
    ["2026-03-10", 293],
    ["2026-03-17", 296],
    ["2026-03-24", 300],
    ["2026-03-31", 303],
  ]),
  WMT: buildHistorySeries([
    ["2026-01-05", 129],
    ["2026-01-12", 128],
    ["2026-01-20", 126],
    ["2026-01-27", 124],
    ["2026-02-03", 123],
    ["2026-02-10", 121],
    ["2026-02-18", 120],
    ["2026-02-25", 120],
    ["2026-03-03", 121],
    ["2026-03-10", 122],
    ["2026-03-17", 123],
    ["2026-03-24", 124],
    ["2026-03-31", 124.5],
  ]),
  INTC: buildHistorySeries([
    ["2026-01-05", 29],
    ["2026-01-12", 27.5],
    ["2026-01-20", 26],
    ["2026-01-27", 24],
    ["2026-02-03", 22.5],
    ["2026-02-10", 21],
    ["2026-02-18", 20.5],
    ["2026-02-25", 20],
    ["2026-03-03", 19.5],
    ["2026-03-10", 19.2],
    ["2026-03-17", 18.8],
    ["2026-03-24", 18.9],
    ["2026-03-31", 19],
  ]),
};

function buildHistorySeries(points) {
  return points.map(([date, close], index) => ({
    index: index + 1,
    date,
    close,
  }));
}

function cloneDefaults() {
  return {
    stocks: DEFAULT_STOCKS.map((stock) => ({ ...stock })),
    selectedTicker: "AMZN",
    investmentAmount: 5000,
    historyInput: DEFAULT_HISTORY_INPUT,
    liveMarketByTicker: {},
    historyByTicker: Object.fromEntries(
      Object.entries(DEMO_HISTORY).map(([ticker, rows]) => [
        ticker,
        rows.map((row) => ({ ...row })),
      ]),
    ),
  };
}

function sanitizeTicker(value, fallback = "TICK") {
  const cleaned = String(value || "")
    .toUpperCase()
    .replace(/[^A-Z0-9.-]/g, "")
    .slice(0, 8);
  return cleaned || fallback;
}

function toFiniteNumber(value, fallback) {
  const next = Number(value);
  return Number.isFinite(next) ? next : fallback;
}

function normalizeTriState(value) {
  if (value === true || value === "true") return true;
  if (value === false || value === "false") return false;
  return null;
}

function sanitizeStock(input, index) {
  const defaults = DEFAULT_STOCKS[index % DEFAULT_STOCKS.length];
  return {
    ticker: sanitizeTicker(input?.ticker, defaults.ticker),
    decline_reason: Object.values(DeclineReason).includes(input?.decline_reason)
      ? input.decline_reason
      : defaults.decline_reason,
    had_clear_prior_uptrend:
      typeof input?.had_clear_prior_uptrend === "boolean"
        ? input.had_clear_prior_uptrend
        : defaults.had_clear_prior_uptrend,
    peak_price: Math.max(1, toFiniteNumber(input?.peak_price, defaults.peak_price)),
    current_price: Math.max(1, toFiniteNumber(input?.current_price, defaults.current_price)),
    decline_shape: Object.values(DeclineShape).includes(input?.decline_shape)
      ? input.decline_shape
      : defaults.decline_shape,
    volume_drying_up_at_bottom: normalizeTriState(input?.volume_drying_up_at_bottom),
    volume_picking_up_on_right_side: normalizeTriState(input?.volume_picking_up_on_right_side),
    fundamentals_score: Math.max(1, Math.min(5, toFiniteNumber(input?.fundamentals_score, defaults.fundamentals_score))),
    sector_type: Object.values(SectorType).includes(input?.sector_type)
      ? input.sector_type
      : defaults.sector_type,
    weeks_sideways_at_bottom: Math.max(0, Math.min(20, Math.round(toFiniteNumber(input?.weeks_sideways_at_bottom, defaults.weeks_sideways_at_bottom)))),
  };
}

function sanitizeHistoryRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows
    .map((row, index) => ({
      index: index + 1,
      date: String(row?.date || row?.Date || `Row ${index + 1}`),
      close: toFiniteNumber(row?.close ?? row?.Close ?? row?.price ?? row?.Price, Number.NaN),
    }))
    .filter((row) => Number.isFinite(row.close) && row.close > 0);
}

function sanitizeLiveMarketEntry(entry) {
  if (!entry || typeof entry !== "object") return null;
  return {
    provider: String(entry.provider || "Unknown provider"),
    docsUrl: String(entry.docsUrl || ""),
    fetchedAt: String(entry.fetchedAt || ""),
    latestTradingDay: String(entry.latestTradingDay || ""),
    sourceType: String(entry.sourceType || "workspace"),
    currentPrice: toFiniteNumber(entry.currentPrice, 0),
    changePercent: String(entry.changePercent || ""),
  };
}

function normalizeWorkspaceSnapshot(parsed, defaults, sourceLabel = "Saved workspace") {
  const issues = [];
  const stocks = Array.isArray(parsed?.stocks)
    ? parsed.stocks.map((stock, index) => sanitizeStock(stock, index))
    : defaults.stocks;

  if (!Array.isArray(parsed?.stocks) || stocks.length === 0) {
    issues.push({
      severity: "warning",
      source: "storage",
      message: `${sourceLabel} was incomplete. Default watchlist entries were restored.`,
    });
  }

  const historyByTicker = Object.fromEntries(
    Object.entries(parsed?.historyByTicker || {}).map(([ticker, rows]) => [
      sanitizeTicker(ticker, ticker),
      sanitizeHistoryRows(rows),
    ]),
  );
  const liveMarketByTicker = Object.fromEntries(
    Object.entries(parsed?.liveMarketByTicker || {})
      .map(([ticker, entry]) => [sanitizeTicker(ticker, ticker), sanitizeLiveMarketEntry(entry)])
      .filter(([, entry]) => Boolean(entry)),
  );

  const selectedTicker = stocks.some((stock) => stock.ticker === parsed?.selectedTicker)
    ? parsed.selectedTicker
    : stocks[0].ticker;

  const investmentAmount = Math.max(
    100,
    Math.min(5000000, toFiniteNumber(parsed?.investmentAmount, defaults.investmentAmount)),
  );

  return {
    stocks,
    selectedTicker,
    investmentAmount,
    historyInput:
      typeof parsed?.historyInput === "string" && parsed.historyInput.trim()
        ? parsed.historyInput
        : rowsToCsv(historyByTicker[selectedTicker] || defaults.historyByTicker[selectedTicker]),
    liveMarketByTicker,
    historyByTicker: { ...defaults.historyByTicker, ...historyByTicker },
    issues,
  };
}

function loadPersistedWorkspace() {
  const defaults = cloneDefaults();
  if (typeof window === "undefined") {
    return { ...defaults, issues: [] };
  }

  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      return { ...defaults, issues: [] };
    }

    return normalizeWorkspaceSnapshot(JSON.parse(raw), defaults, "Browser storage");
  } catch (error) {
    return {
      ...defaults,
      issues: [
        {
          severity: "warning",
          source: "storage",
          message: "Saved workspace could not be parsed. Default market presets were restored.",
          detail: error instanceof Error ? error.message : "Unknown storage failure",
        },
      ],
    };
  }
}

function createDefaultWorkspaceName(ticker = "") {
  const stamp = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
  }).format(new Date());
  return ticker ? `${ticker} review ${stamp}` : `Market review ${stamp}`;
}

function rowsToCsv(rows) {
  if (!rows?.length) return "date,close";
  return ["date,close", ...rows.map((row) => `${row.date},${row.close}`)].join("\n");
}

function createHealthEvent(input) {
  return {
    id:
      typeof crypto !== "undefined" && crypto.randomUUID
        ? crypto.randomUUID()
        : `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    severity: input.severity || "info",
    source: input.source || "app",
    message: input.message || "Unknown event",
    detail: input.detail || "",
    timestamp: new Date().toISOString(),
  };
}

function useRuntimeHealth(initialIssues) {
  const [events, setEvents] = useState(() =>
    (initialIssues || []).map((issue) => createHealthEvent(issue)),
  );

  const append = (severity, source, message, detail = "") => {
    startTransition(() => {
      setEvents((current) =>
        [createHealthEvent({ severity, source, message, detail }), ...current].slice(
          0,
          MAX_HEALTH_EVENTS,
        ),
      );
    });
  };

  const handleRuntimeFailure = useEffectEvent((payload) => {
    setEvents((current) =>
      [createHealthEvent(payload), ...current].slice(0, MAX_HEALTH_EVENTS),
    );
  });

  useEffect(() => {
    function onError(event) {
      handleRuntimeFailure({
        severity: "error",
        source: "runtime",
        message: event.message || "Uncaught runtime error",
        detail:
          event.error instanceof Error
            ? event.error.stack || event.error.message
            : `${event.filename || "unknown file"}:${event.lineno || 0}`,
      });
    }

    function onRejection(event) {
      const reason = event.reason;
      handleRuntimeFailure({
        severity: "error",
        source: "promise",
        message:
          reason instanceof Error
            ? reason.message
            : "Unhandled async rejection surfaced by the browser",
        detail:
          reason instanceof Error
            ? reason.stack || reason.message
            : typeof reason === "string"
              ? reason
              : JSON.stringify(reason, null, 2),
      });
    }

    window.addEventListener("error", onError);
    window.addEventListener("unhandledrejection", onRejection);
    return () => {
      window.removeEventListener("error", onError);
      window.removeEventListener("unhandledrejection", onRejection);
    };
  }, []);

  return {
    events,
    append,
    clear: () => setEvents([]),
  };
}

function scoreDeclineReason(reason) {
  return {
    [DeclineReason.MACRO_SENTIMENT]: 1,
    [DeclineReason.UNKNOWN]: 0.4,
    [DeclineReason.FUNDAMENTAL]: 0,
  }[reason];
}

function scorePriorUptrend(hadUptrend) {
  return hadUptrend ? 1 : 0;
}

function scoreDeclineDepth(peak, current) {
  if (peak <= 0 || current <= 0 || current >= peak) {
    return { score: 0.5, depth_pct: 0 };
  }

  const depth_pct = ((peak - current) / peak) * 100;
  let score = 0;
  if (depth_pct <= 20) score = 1;
  else if (depth_pct <= 30) score = 0.9;
  else if (depth_pct <= 35) score = 0.75;
  else if (depth_pct <= 45) score = 0.5;
  else if (depth_pct <= 55) score = 0.25;

  return { score, depth_pct };
}

function scoreDeclineShape(shape) {
  return {
    [DeclineShape.GRADUAL_ROUNDED]: 1,
    [DeclineShape.MIXED]: 0.5,
    [DeclineShape.VERTICAL_CLIFF]: 0,
  }[shape];
}

function scoreVolumeProfile(drying, pickingUp) {
  if (drying === null && pickingUp === null) return 0.5;

  const signals = [];
  if (drying !== null) signals.push(drying ? 1 : 0);
  if (pickingUp !== null) signals.push(pickingUp ? 1 : 0);

  return signals.reduce((sum, value) => sum + value, 0) / signals.length;
}

function scoreFundamentals(score) {
  return (Math.max(1, Math.min(5, Number(score || 3))) - 1) / 4;
}

function scoreSector(sector) {
  return {
    [SectorType.CYCLICAL]: 1,
    [SectorType.STRUCTURAL]: 0,
  }[sector];
}

function detectStage(stock, depth_pct) {
  if (stock.current_price >= stock.peak_price) return CupStage.BREAKOUT;
  if (depth_pct < 10 && stock.volume_picking_up_on_right_side === true) return CupStage.HANDLE;
  if (stock.volume_picking_up_on_right_side === true && depth_pct < 40) return CupStage.RIGHT_SIDE;
  if (
    stock.volume_drying_up_at_bottom === true ||
    Number(stock.weeks_sideways_at_bottom) >= 3
  ) {
    return CupStage.CUP_BOTTOM;
  }
  if (
    stock.decline_shape !== DeclineShape.VERTICAL_CLIFF &&
    depth_pct >= 20 &&
    depth_pct <= 45
  ) {
    return CupStage.LEFT_SIDE_LATE;
  }
  if (depth_pct < 20 || stock.decline_shape === DeclineShape.VERTICAL_CLIFF) {
    return CupStage.LEFT_SIDE_EARLY;
  }
  return CupStage.INDETERMINATE;
}

function generateAlert(stage, probability, ticker) {
  const alerts = {
    [CupStage.LEFT_SIDE_EARLY]: `${ticker} is still absorbing selling pressure. Wait for downside velocity to cool.`,
    [CupStage.LEFT_SIDE_LATE]: `${ticker} is nearing a possible base. Watch for quieter weekly closes and tighter ranges.`,
    [CupStage.CUP_BOTTOM]: `${ticker} is stabilizing at the bottom. A right-side push with volume would improve the setup.`,
    [CupStage.RIGHT_SIDE]: `${ticker} is rebuilding momentum on the right side. Focus on confirming participation from buyers.`,
    [CupStage.HANDLE]: `${ticker} is in a handle-quality zone. A tight pause above the midpoint can set up a clean trigger.`,
    [CupStage.BREAKOUT]: `${ticker} has reclaimed the prior high zone. Follow-through volume now matters more than theory.`,
    [CupStage.INDETERMINATE]: `${ticker} needs better price and volume evidence before this pattern deserves conviction.`,
  };

  return `${alerts[stage]} Estimated cup probability: ${Math.round(probability)}%.`;
}

function getQualityFlags(stock, historyRows) {
  const flags = [];

  if (stock.current_price > stock.peak_price) {
    flags.push("Current price is above the saved peak. Confirm the peak anchor.");
  }
  if (!stock.had_clear_prior_uptrend) {
    flags.push("No clear prior uptrend recorded.");
  }
  if (stock.volume_drying_up_at_bottom === null || stock.volume_picking_up_on_right_side === null) {
    flags.push("Volume signals are partial. Probability is less trustworthy.");
  }
  if (!historyRows?.length) {
    flags.push("No imported price history is attached to this ticker.");
  }

  return flags;
}

function evaluateStock(stock, investmentAmount, historyRows) {
  if (stock.decline_reason === DeclineReason.FUNDAMENTAL) {
    return {
      probability: 0,
      stage: CupStage.LEFT_SIDE_EARLY,
      alert: `${stock.ticker} is disqualified because the decline looks fundamental rather than cyclical.`,
      depth_pct: 0,
      component_scores: {},
      disqualified: true,
      disqualify_reason: "Fundamental deterioration overrides the pattern.",
      quality_flags: getQualityFlags(stock, historyRows),
      suggested_position_dollars: 0,
      suggested_shares: 0,
      estimated_risk: "High",
    };
  }

  if (stock.sector_type === SectorType.STRUCTURAL && Number(stock.fundamentals_score) <= 2) {
    return {
      probability: 0,
      stage: CupStage.LEFT_SIDE_EARLY,
      alert: `${stock.ticker} is disqualified because the sector is structurally weak and the fundamentals are poor.`,
      depth_pct: 0,
      component_scores: {},
      disqualified: true,
      disqualify_reason: "Structural decline with weak fundamentals.",
      quality_flags: getQualityFlags(stock, historyRows),
      suggested_position_dollars: 0,
      suggested_shares: 0,
      estimated_risk: "High",
    };
  }

  const { score: depthScore, depth_pct } = scoreDeclineDepth(
    Number(stock.peak_price),
    Number(stock.current_price),
  );

  const component_scores = {
    decline_reason: scoreDeclineReason(stock.decline_reason),
    prior_uptrend: scorePriorUptrend(stock.had_clear_prior_uptrend),
    decline_depth: depthScore,
    decline_shape: scoreDeclineShape(stock.decline_shape),
    volume_profile: scoreVolumeProfile(
      stock.volume_drying_up_at_bottom,
      stock.volume_picking_up_on_right_side,
    ),
    fundamentals: scoreFundamentals(stock.fundamentals_score),
    sector_type: scoreSector(stock.sector_type),
  };

  const weightedScore = Object.keys(component_scores).reduce(
    (sum, key) => sum + component_scores[key] * WEIGHTS[key],
    0,
  );

  const probability = Math.max(0, Math.min(100, Number(weightedScore.toFixed(1))));
  const stage = detectStage(stock, depth_pct);
  const conviction = STAGE_META[stage]?.multiplier || 0.2;
  const suggested_position_dollars = Math.max(
    0,
    Math.round(investmentAmount * (probability / 100) * conviction * 0.22),
  );
  const suggested_shares = Math.floor(
    suggested_position_dollars / Math.max(1, stock.current_price),
  );
  const estimated_risk =
    probability >= 75 ? "Moderate" : probability >= 55 ? "Moderate-High" : "High";

  return {
    probability,
    stage,
    alert: generateAlert(stage, probability, stock.ticker),
    depth_pct: Number(depth_pct.toFixed(1)),
    component_scores,
    disqualified: false,
    disqualify_reason: "",
    quality_flags: getQualityFlags(stock, historyRows),
    suggested_position_dollars,
    suggested_shares,
    estimated_risk,
  };
}

function parseHistoryText(text) {
  const raw = String(text || "").trim();
  if (!raw) {
    return { rows: [], error: "Paste CSV or JSON history data before importing." };
  }

  if (raw.startsWith("[")) {
    try {
      return { rows: sanitizeHistoryRows(JSON.parse(raw)), error: "" };
    } catch (error) {
      return {
        rows: [],
        error: error instanceof Error ? error.message : "JSON parsing failed.",
      };
    }
  }

  const lines = raw.split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) {
    return { rows: [], error: "CSV requires a header row and at least one data row." };
  }

  const headers = lines[0].split(",").map((header) => header.trim().toLowerCase());
  const dateIndex = headers.findIndex((header) => header === "date");
  const closeIndex = headers.findIndex(
    (header) => header === "close" || header === "adj close" || header === "price",
  );

  if (dateIndex === -1 || closeIndex === -1) {
    return {
      rows: [],
      error: 'CSV must contain "date" and "close" columns.',
    };
  }

  const rows = lines.slice(1).map((line, index) => {
    const columns = line.split(",");
    return {
      index: index + 1,
      date: String(columns[dateIndex] || `Row ${index + 1}`).trim(),
      close: Number(columns[closeIndex]),
    };
  });

  const cleanedRows = rows.filter((row) => Number.isFinite(row.close) && row.close > 0);

  if (!cleanedRows.length) {
    return {
      rows: [],
      error: "No valid close values were found in the imported rows.",
    };
  }

  return { rows: cleanedRows, error: "" };
}

function formatCurrency(value) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: value >= 100 ? 0 : 2,
  }).format(value || 0);
}

function formatPercent(value) {
  return `${Number(value || 0).toFixed(1)}%`;
}

function formatDateTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "Unknown time"
    : date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function formatDateTimeLong(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "Unknown time"
    : date.toLocaleString([], {
        month: "short",
        day: "numeric",
        year: "numeric",
        hour: "numeric",
        minute: "2-digit",
      });
}

function isSameHistory(leftRows = [], rightRows = []) {
  if (leftRows.length !== rightRows.length) return false;
  return leftRows.every((row, index) => {
    const other = rightRows[index];
    return row?.date === other?.date && Number(row?.close) === Number(other?.close);
  });
}

function getResearchLinks(ticker) {
  const symbol = encodeURIComponent(sanitizeTicker(ticker, ticker));
  return [
    {
      label: "Yahoo Finance",
      href: `https://finance.yahoo.com/quote/${symbol}`,
    },
    {
      label: "Finviz",
      href: `https://finviz.com/quote.ashx?t=${symbol}`,
    },
    {
      label: "SEC Filings",
      href: `https://www.sec.gov/edgar/search/#/q=${symbol}`,
    },
  ];
}

function formatBooleanLabel(value, trueLabel, falseLabel) {
  return value ? trueLabel : falseLabel;
}

function formatTriStateLabel(value) {
  if (value === true) return "Yes";
  if (value === false) return "No";
  return "Unknown";
}

function scoreTone(value) {
  if (value >= 75) return "strong";
  if (value >= 55) return "good";
  if (value >= 35) return "watch";
  return "warning";
}

function Field({ label, children, helper }) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
      {helper ? <div className="field-help">{helper}</div> : null}
    </label>
  );
}

function StatCard({ label, value, tone = "neutral", detail }) {
  return (
    <div className={`stat-card tone-${tone}`}>
      <span className="stat-label">{label}</span>
      <strong className="stat-value">{value}</strong>
      {detail ? <span className="stat-detail">{detail}</span> : null}
    </div>
  );
}

function StatusPill({ tone, children }) {
  return <span className={`status-pill tone-${tone}`}>{children}</span>;
}

export default function CupHandleWorkbench() {
  const [bootSnapshot] = useState(() => loadPersistedWorkspace());
  const runtimeHealth = useRuntimeHealth(bootSnapshot.issues);
  const [stocks, setStocks] = useState(bootSnapshot.stocks);
  const [selectedTicker, setSelectedTicker] = useState(bootSnapshot.selectedTicker);
  const [investmentAmount, setInvestmentAmount] = useState(bootSnapshot.investmentAmount);
  const [historyByTicker, setHistoryByTicker] = useState(bootSnapshot.historyByTicker);
  const [liveMarketByTicker, setLiveMarketByTicker] = useState(bootSnapshot.liveMarketByTicker);
  const [historyInput, setHistoryInput] = useState(bootSnapshot.historyInput);
  const [controlsView, setControlsView] = useState("setup");
  const [workspaceDraftName, setWorkspaceDraftName] = useState(() =>
    createDefaultWorkspaceName(bootSnapshot.selectedTicker),
  );
  const [activeWorkspaceSnapshotId, setActiveWorkspaceSnapshotId] = useState("");
  const [marketFeedStatus, setMarketFeedStatus] = useState({
    provider: "Alpha Vantage",
    docsUrl: "https://www.alphavantage.co/documentation/",
    configured: false,
    message: "Checking market feed configuration...",
    ok: true,
  });
  const [marketSyncState, setMarketSyncState] = useState({
    status: "idle",
    message: "",
  });
  const [workspaceVaultStatus, setWorkspaceVaultStatus] = useState({
    available: false,
    message: "Checking server workspace vault...",
    snapshotCount: 0,
    storagePath: "",
    checked: false,
    ok: true,
  });
  const [workspaceSnapshots, setWorkspaceSnapshots] = useState([]);
  const [workspaceVaultAction, setWorkspaceVaultAction] = useState({
    status: "idle",
    message: "",
  });
  const [storageState, setStorageState] = useState(
    bootSnapshot.issues.length
      ? {
          status: "warning",
          message: "Recovered with fallbacks after storage validation.",
        }
      : {
          status: "ready",
          message: "Workspace is synced to browser storage.",
        },
  );

  const refreshWorkspaceVault = useEffectEvent(async (reportErrors = false) => {
    try {
      const [status, list] = await Promise.all([
        fetchWorkspaceVaultStatus(),
        listWorkspaceSnapshots(),
      ]);
      setWorkspaceVaultStatus({ ...status, checked: true });
      setWorkspaceSnapshots(list.snapshots || []);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Workspace vault status could not be loaded.";
      const detail =
        error instanceof Error && "detail" in error ? String(error.detail || "") : "";

      setWorkspaceVaultStatus({
        available: false,
        message,
        snapshotCount: 0,
        storagePath: "",
        checked: true,
        ok: false,
      });
      setWorkspaceSnapshots([]);

      if (reportErrors) {
        runtimeHealth.append(
          "warning",
          "workspace-vault",
          "Workspace vault could not be reached.",
          detail || message,
        );
      }
    }
  });

  useEffect(() => {
    if (!stocks.some((stock) => stock.ticker === selectedTicker)) {
      setSelectedTicker(stocks[0]?.ticker || "");
    }
  }, [stocks, selectedTicker]);

  useEffect(() => {
    const selectedHistory = historyByTicker[selectedTicker];
    setHistoryInput(rowsToCsv(selectedHistory?.length ? selectedHistory : DEMO_HISTORY[selectedTicker] || []));
  }, [selectedTicker, historyByTicker]);

  useEffect(() => {
    if (!workspaceDraftName.trim()) {
      setWorkspaceDraftName(createDefaultWorkspaceName(selectedTicker));
    }
  }, [selectedTicker, workspaceDraftName]);

  useEffect(() => {
    let cancelled = false;

    fetchMarketFeedStatus()
      .then((status) => {
        if (cancelled) return;
        setMarketFeedStatus(status);
      })
      .catch((error) => {
        if (cancelled) return;
        setMarketFeedStatus({
          provider: "Alpha Vantage",
          docsUrl: "https://www.alphavantage.co/documentation/",
          configured: false,
          message: error instanceof Error ? error.message : "Market feed status could not be loaded.",
          ok: false,
        });
      });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    refreshWorkspaceVault(true);
  }, [refreshWorkspaceVault]);

  const persistedWorkspace = useMemo(
    () => ({
      stocks,
      selectedTicker,
      investmentAmount,
      historyInput,
      liveMarketByTicker,
      historyByTicker,
    }),
    [stocks, selectedTicker, investmentAmount, historyInput, liveMarketByTicker, historyByTicker],
  );

  useEffect(() => {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(persistedWorkspace));
      setStorageState({
        status: "ready",
        message: `Workspace synced at ${new Date().toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
        })}.`,
      });
    } catch (error) {
      const detail = error instanceof Error ? error.message : "Unknown storage error";
      setStorageState({
        status: "error",
        message: "Workspace could not be saved locally.",
      });
      runtimeHealth.append("error", "storage", "Workspace persistence failed.", detail);
    }
  }, [persistedWorkspace]);

  const deferredHistoryInput = useDeferredValue(historyInput);
  const historyPreview = useMemo(
    () => parseHistoryText(deferredHistoryInput),
    [deferredHistoryInput],
  );

  const results = useMemo(() => {
    return stocks
      .map((stock) => ({
        input: stock,
        result: evaluateStock(stock, investmentAmount, historyByTicker[stock.ticker] || []),
      }))
      .sort((left, right) => right.result.probability - left.result.probability);
  }, [stocks, investmentAmount, historyByTicker]);

  const selectedStock = stocks.find((stock) => stock.ticker === selectedTicker) || stocks[0];
  const selectedResult =
    results.find((entry) => entry.input.ticker === selectedTicker) || results[0];
  const selectedHistory = historyByTicker[selectedTicker] || [];
  const selectedLiveMarket = liveMarketByTicker[selectedTicker] || null;
  const selectedResearchLinks = useMemo(
    () => getResearchLinks(selectedTicker || selectedStock?.ticker || ""),
    [selectedTicker, selectedStock],
  );

  const selectedHistoryStats = useMemo(() => {
    if (!selectedHistory.length) {
      return {
        peakPoint: null,
        bottomPoint: null,
        latestPoint: null,
        reboundPct: 0,
      };
    }

    const peakPoint = selectedHistory.reduce((best, row) =>
      !best || row.close > best.close ? row : best,
    );
    const bottomPoint = selectedHistory.reduce((best, row) =>
      !best || row.close < best.close ? row : best,
    );
    const latestPoint = selectedHistory[selectedHistory.length - 1];
    const reboundPct =
      bottomPoint && latestPoint
        ? ((latestPoint.close - bottomPoint.close) / bottomPoint.close) * 100
        : 0;

    return {
      peakPoint,
      bottomPoint,
      latestPoint,
      reboundPct,
    };
  }, [selectedHistory]);

  const currentPriceTimestampLabel = selectedLiveMarket?.latestTradingDay
    ? `as of ${selectedLiveMarket.latestTradingDay}`
    : selectedHistoryStats.latestPoint?.date
    ? `as of ${selectedHistoryStats.latestPoint.date}`
    : "local input";
  const storageCardTone =
    storageState.status === "error"
      ? "error"
      : storageState.status === "warning" ||
          (workspaceVaultStatus.checked && !workspaceVaultStatus.available)
        ? "warning"
        : "good";
  const storageCardValue =
    storageState.status === "error"
      ? "Local issue"
      : !workspaceVaultStatus.checked
        ? "Checking"
        : workspaceVaultStatus.available
        ? "Local + vault"
        : "Browser only";
  const storageCardDetail = !workspaceVaultStatus.checked
    ? `${storageState.message} Server workspace vault is being checked.`
    : workspaceVaultStatus.available
    ? `${storageState.message} ${workspaceVaultStatus.snapshotCount} server snapshot(s) available.`
    : `${storageState.message} Server workspace vault is unavailable.`;
  const vaultStatusTone = !workspaceVaultStatus.checked
    ? "neutral"
    : workspaceVaultStatus.available
      ? "good"
      : "warning";
  const vaultActionTone =
    workspaceVaultAction.status === "error"
      ? "error"
      : workspaceVaultAction.status === "success"
        ? "good"
        : "neutral";

  const selectedProvenance = useMemo(() => {
    if (!selectedStock) {
      return {
        label: "No active source",
        tone: "warning",
        detail: "No ticker is selected, so there is no visible dataset to audit.",
      };
    }

    const defaultHistory = DEMO_HISTORY[selectedStock.ticker] || [];
    const hasHistory = selectedHistory.length > 0;
    const matchesDefaultHistory =
      defaultHistory.length > 0 && isSameHistory(selectedHistory, defaultHistory);
    const isPresetTicker = DEFAULT_STOCKS.some((stock) => stock.ticker === selectedStock.ticker);

    if (selectedLiveMarket?.sourceType === "live_market_feed") {
      return {
        label: `${selectedLiveMarket.provider} sync`,
        tone: "good",
        detail: `Live market data was last synchronized ${formatDateTimeLong(
          selectedLiveMarket.fetchedAt,
        )}. Latest trading day reported: ${selectedLiveMarket.latestTradingDay || "unknown"}.`,
      };
    }

    if (hasHistory && !matchesDefaultHistory) {
      return {
        label: "Imported history",
        tone: "good",
        detail:
          "Price rows were loaded into this workspace through CSV or JSON import. Review the original export or data vendor before making investment decisions.",
      };
    }

    if (isPresetTicker && matchesDefaultHistory) {
      return {
        label: "Local preset dataset",
        tone: "neutral",
        detail:
          "This ticker is currently using the starter reference dataset bundled with the application. It is not a live market feed and should be verified externally.",
      };
    }

    if (!hasHistory) {
      return {
        label: "Local scenario only",
        tone: "warning",
        detail:
          "This ticker has no attached history rows. The visible values are local scenario inputs inside the app until you import supporting price history.",
      };
    }

    return {
      label: "Workspace-adjusted data",
      tone: "warning",
      detail:
        "The active values differ from the default starter dataset. Treat them as locally adjusted workspace inputs until you confirm them against an external source.",
    };
  }, [selectedHistory, selectedStock, selectedLiveMarket]);

  const leaderboardData = useMemo(
    () =>
      results.slice(0, 5).map(({ input, result }) => ({
        ticker: input.ticker,
        probability: result.probability,
        depth: result.depth_pct,
        price: input.current_price,
      })),
    [results],
  );

  const scoreBreakdownData = useMemo(() => {
    if (!selectedResult?.result.component_scores) return [];
    return Object.entries(selectedResult.result.component_scores).map(([key, value]) => ({
      label: key.replaceAll("_", " "),
      score: Number((value * 100).toFixed(0)),
    }));
  }, [selectedResult]);

  const overallSeverity = useMemo(() => {
    const eventSeverity = runtimeHealth.events.reduce(
      (max, event) => Math.max(max, SEVERITY_WEIGHT[event.severity] || 0),
      0,
    );

    if (storageState.status === "error" || historyPreview.error) {
      return "error";
    }
    if (
      eventSeverity >= SEVERITY_WEIGHT.warning ||
      storageState.status === "warning" ||
      (workspaceVaultStatus.checked && !workspaceVaultStatus.available)
    ) {
      return "warning";
    }
    return "ready";
  }, [
    runtimeHealth.events,
    storageState.status,
    historyPreview.error,
    workspaceVaultStatus.available,
    workspaceVaultStatus.checked,
  ]);

  const dropdownGuidance = useMemo(() => {
    if (!selectedStock) return [];

    return [
      {
        label: "Decline reason",
        current:
          selectedStock.decline_reason === DeclineReason.MACRO_SENTIMENT
            ? "Macro or sentiment"
            : selectedStock.decline_reason === DeclineReason.FUNDAMENTAL
              ? "Fundamental deterioration"
              : "Unknown",
        impact:
          selectedStock.decline_reason === DeclineReason.MACRO_SENTIMENT
            ? "This is the most favorable setting. The model assumes the decline may be temporary and keeps the setup eligible."
            : selectedStock.decline_reason === DeclineReason.FUNDAMENTAL
              ? "This is effectively a veto. The model disqualifies the setup because a cup-and-handle works best after non-structural damage."
              : "This keeps the setup alive, but with lower confidence because the reason for the decline is not clear.",
      },
      {
        label: "Decline shape",
        current:
          selectedStock.decline_shape === DeclineShape.GRADUAL_ROUNDED
            ? "Gradual rounded"
            : selectedStock.decline_shape === DeclineShape.VERTICAL_CLIFF
              ? "Vertical cliff"
              : "Mixed",
        impact:
          selectedStock.decline_shape === DeclineShape.GRADUAL_ROUNDED
            ? "Rounded declines score best because they look more like a base forming than a panic unwind."
            : selectedStock.decline_shape === DeclineShape.VERTICAL_CLIFF
              ? "Sharp vertical drops reduce the score and usually keep the stock in an early-stage classification."
              : "Mixed action is acceptable, but it signals a less orderly base and lowers conviction.",
      },
      {
        label: "Prior uptrend",
        current: formatBooleanLabel(
          selectedStock.had_clear_prior_uptrend,
          "Clear prior uptrend",
          "No prior uptrend",
        ),
        impact: selectedStock.had_clear_prior_uptrend
          ? "This supports the pattern. Cup-and-handle setups are stronger when they occur after a meaningful advance."
          : "This removes an important prerequisite, because a base without a prior run often behaves like a weak range instead of a continuation pattern.",
      },
      {
        label: "Volume drying at bottom",
        current: formatTriStateLabel(selectedStock.volume_drying_up_at_bottom),
        impact:
          selectedStock.volume_drying_up_at_bottom === true
            ? "This improves the score because selling pressure appears to be fading near the low."
            : selectedStock.volume_drying_up_at_bottom === false
              ? "This weakens the score because persistent volume at the lows suggests unfinished distribution."
              : "Unknown keeps the model neutral. It avoids a penalty, but it also limits conviction.",
      },
      {
        label: "Volume picking up",
        current: formatTriStateLabel(selectedStock.volume_picking_up_on_right_side),
        impact:
          selectedStock.volume_picking_up_on_right_side === true
            ? "This pushes the setup toward right-side or handle stages because buyers are showing up during the recovery."
            : selectedStock.volume_picking_up_on_right_side === false
              ? "This delays stage progression because the rebound is not being confirmed by stronger participation."
              : "Unknown keeps the model from overcommitting when the right-side volume evidence is incomplete.",
      },
      {
        label: "Sector regime",
        current:
          selectedStock.sector_type === SectorType.CYCLICAL
            ? "Cyclical recovery"
            : "Structural decline",
        impact:
          selectedStock.sector_type === SectorType.CYCLICAL
            ? "This is supportive. The model assumes the group can recover if company-specific damage is limited."
            : "This is restrictive. If fundamentals are also weak, the setup is disqualified because the decline may be secular.",
      },
    ];
  }, [selectedStock]);

  function updateSelectedStock(field, value) {
    setStocks((current) =>
      current.map((stock) =>
        stock.ticker === selectedTicker ? { ...stock, [field]: value } : stock,
      ),
    );
  }

  function applyWorkspaceState(nextWorkspace) {
    startTransition(() => {
      setStocks(nextWorkspace.stocks);
      setSelectedTicker(nextWorkspace.selectedTicker);
      setInvestmentAmount(nextWorkspace.investmentAmount);
      setHistoryByTicker(nextWorkspace.historyByTicker);
      setLiveMarketByTicker(nextWorkspace.liveMarketByTicker);
      setHistoryInput(nextWorkspace.historyInput);
    });
  }

  function addStock() {
    const nextTickerBase = `NEW${stocks.length + 1}`;
    const nextTicker = sanitizeTicker(nextTickerBase);

    const draft = {
      ticker: nextTicker,
      decline_reason: DeclineReason.UNKNOWN,
      had_clear_prior_uptrend: true,
      peak_price: 100,
      current_price: 82,
      decline_shape: DeclineShape.MIXED,
      volume_drying_up_at_bottom: null,
      volume_picking_up_on_right_side: null,
      fundamentals_score: 3,
      sector_type: SectorType.CYCLICAL,
      weeks_sideways_at_bottom: 2,
    };

    startTransition(() => {
      setStocks((current) => [...current, draft]);
      setHistoryByTicker((current) => ({
        ...current,
        [nextTicker]: [],
      }));
      setSelectedTicker(nextTicker);
      runtimeHealth.append("info", "watchlist", `Added ${nextTicker} to the workspace.`);
    });
  }

  function removeSelectedStock() {
    if (stocks.length === 1) {
      runtimeHealth.append("warning", "watchlist", "At least one ticker must remain.");
      return;
    }

    startTransition(() => {
      setStocks((current) => current.filter((stock) => stock.ticker !== selectedTicker));
      setHistoryByTicker((current) => {
        const next = { ...current };
        delete next[selectedTicker];
        return next;
      });
      const fallbackTicker = stocks.find((stock) => stock.ticker !== selectedTicker)?.ticker;
      setSelectedTicker(fallbackTicker || stocks[0].ticker);
      runtimeHealth.append("info", "watchlist", `${selectedTicker} was removed from the workspace.`);
    });
  }

  function applyImportedHistory() {
    if (historyPreview.error || !historyPreview.rows.length || !selectedStock) {
      runtimeHealth.append(
        "error",
        "history",
        "History import was blocked.",
        historyPreview.error || "No valid rows were parsed.",
      );
      return;
    }

    const importedRows = historyPreview.rows;
    const derivedPeak = Math.max(...importedRows.map((row) => row.close));
    const latestClose = importedRows[importedRows.length - 1]?.close || selectedStock.current_price;

    startTransition(() => {
      setHistoryByTicker((current) => ({
        ...current,
        [selectedTicker]: importedRows,
      }));
      setLiveMarketByTicker((current) => {
        const next = { ...current };
        delete next[selectedTicker];
        return next;
      });
      setStocks((current) =>
        current.map((stock) =>
          stock.ticker === selectedTicker
            ? {
                ...stock,
                peak_price: Number(derivedPeak.toFixed(2)),
                current_price: Number(latestClose.toFixed(2)),
              }
            : stock,
        ),
      );
      runtimeHealth.append(
        "info",
        "history",
        `Imported ${importedRows.length} rows for ${selectedTicker}.`,
      );
    });
  }

  function resetWorkspace() {
    const defaults = cloneDefaults();
    applyWorkspaceState(defaults);
    setActiveWorkspaceSnapshotId("");
    setWorkspaceDraftName(createDefaultWorkspaceName(defaults.selectedTicker));
    runtimeHealth.clear();
    runtimeHealth.append(
      "info",
      "workspace",
      "Workspace restored to the default market presets.",
    );
  }

  async function syncSelectedTickerWithMarketFeed() {
    if (!selectedTicker) return;

    setMarketSyncState({
      status: "syncing",
      message: `Syncing ${selectedTicker} from ${marketFeedStatus.provider}...`,
    });

    try {
      const snapshot = await fetchMarketSnapshot(selectedTicker);
      const providerRows = snapshot.history.rows.map((row, index) => ({
        index: index + 1,
        date: row.date,
        close: row.close,
      }));

      startTransition(() => {
        setHistoryByTicker((current) => ({
          ...current,
          [selectedTicker]: providerRows,
        }));
        setLiveMarketByTicker((current) => ({
          ...current,
          [selectedTicker]: {
            provider: snapshot.provider,
            docsUrl: snapshot.docsUrl,
            fetchedAt: snapshot.fetchedAt,
            latestTradingDay: snapshot.quote.latestTradingDay,
            sourceType: "live_market_feed",
            currentPrice: snapshot.quote.currentPrice,
            changePercent: snapshot.quote.changePercent,
          },
        }));
        setStocks((current) =>
          current.map((stock) =>
            stock.ticker === selectedTicker
              ? {
                  ...stock,
                  peak_price: Number(snapshot.history.peakPrice.toFixed(2)),
                  current_price: Number(snapshot.quote.currentPrice.toFixed(2)),
                }
              : stock,
          ),
        );
        setHistoryInput(rowsToCsv(providerRows));
      });

      setMarketSyncState({
        status: "success",
        message: `${selectedTicker} synced from ${snapshot.provider} at ${formatDateTimeLong(
          snapshot.fetchedAt,
        )}.`,
      });
      runtimeHealth.append(
        "info",
        "market-feed",
        `${selectedTicker} synced from ${snapshot.provider}.`,
        `Latest trading day ${snapshot.quote.latestTradingDay}`,
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : "Market sync failed.";
      const detail =
        error instanceof Error && "detail" in error ? String(error.detail || "") : "";

      setMarketSyncState({
        status: "error",
        message,
      });
      runtimeHealth.append("warning", "market-feed", message, detail);
    }
  }

  async function saveCurrentWorkspaceToVault(snapshotId = "") {
    const snapshotName = workspaceDraftName.trim() || createDefaultWorkspaceName(selectedTicker);
    setWorkspaceVaultAction({
      status: "saving",
      message: snapshotId
        ? `Updating ${snapshotName} in the workspace vault...`
        : `Saving ${snapshotName} to the workspace vault...`,
    });

    try {
      const response = await saveWorkspaceSnapshot({
        id: snapshotId || undefined,
        name: snapshotName,
        workspace: persistedWorkspace,
      });

      setActiveWorkspaceSnapshotId(response.snapshot.id);
      setWorkspaceDraftName(response.snapshot.name);
      setWorkspaceVaultAction({
        status: "success",
        message: `${response.snapshot.name} saved at ${formatDateTimeLong(
          response.snapshot.updatedAt,
        )}.`,
      });
      runtimeHealth.append(
        "info",
        "workspace-vault",
        `${response.snapshot.name} saved to the workspace vault.`,
      );
      await refreshWorkspaceVault();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Workspace could not be saved to the vault.";
      const detail =
        error instanceof Error && "detail" in error ? String(error.detail || "") : "";

      setWorkspaceVaultAction({
        status: "error",
        message,
      });
      runtimeHealth.append("warning", "workspace-vault", message, detail);
    }
  }

  async function loadWorkspaceFromVault(snapshotId) {
    setWorkspaceVaultAction({
      status: "saving",
      message: "Loading workspace snapshot...",
    });

    try {
      const response = await loadWorkspaceSnapshot(snapshotId);
      const nextWorkspace = normalizeWorkspaceSnapshot(
        response.snapshot.workspace,
        cloneDefaults(),
        `Saved workspace "${response.snapshot.name}"`,
      );

      applyWorkspaceState(nextWorkspace);
      setActiveWorkspaceSnapshotId(response.snapshot.id);
      setWorkspaceDraftName(response.snapshot.name);
      setWorkspaceVaultAction({
        status: "success",
        message: `${response.snapshot.name} loaded from the workspace vault.`,
      });

      nextWorkspace.issues.forEach((issue) => {
        runtimeHealth.append(
          issue.severity,
          issue.source,
          issue.message,
          issue.detail || "",
        );
      });
      runtimeHealth.append(
        "info",
        "workspace-vault",
        `${response.snapshot.name} loaded from the workspace vault.`,
      );
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Workspace snapshot could not be loaded.";
      const detail =
        error instanceof Error && "detail" in error ? String(error.detail || "") : "";

      setWorkspaceVaultAction({
        status: "error",
        message,
      });
      runtimeHealth.append("warning", "workspace-vault", message, detail);
    }
  }

  async function removeWorkspaceFromVault(snapshotId, snapshotName) {
    setWorkspaceVaultAction({
      status: "saving",
      message: `Removing ${snapshotName} from the workspace vault...`,
    });

    try {
      await deleteWorkspaceSnapshot(snapshotId);
      if (snapshotId === activeWorkspaceSnapshotId) {
        setActiveWorkspaceSnapshotId("");
      }
      setWorkspaceVaultAction({
        status: "success",
        message: `${snapshotName} removed from the workspace vault.`,
      });
      runtimeHealth.append(
        "info",
        "workspace-vault",
        `${snapshotName} removed from the workspace vault.`,
      );
      await refreshWorkspaceVault();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Workspace snapshot could not be removed.";
      const detail =
        error instanceof Error && "detail" in error ? String(error.detail || "") : "";

      setWorkspaceVaultAction({
        status: "error",
        message,
      });
      runtimeHealth.append("warning", "workspace-vault", message, detail);
    }
  }

  return (
    <div className="app-shell">
      <header className="hero">
        <div>
          <p className="eyebrow">Cup-and-Handle Workbench</p>
          <h1>Reliable pattern screening with visible runtime health.</h1>
          <p className="hero-copy">
            Screen recovery setups, validate price-history imports, and manage pattern risk
            with a resilient workspace built for daily market review.
          </p>
        </div>
        <div className="hero-status">
          <StatusPill tone={overallSeverity === "ready" ? "good" : overallSeverity}>
            {overallSeverity === "ready" ? "Runtime healthy" : `Runtime ${overallSeverity}`}
          </StatusPill>
          <StatusPill tone={scoreTone(selectedResult?.result.probability || 0)}>
            {selectedResult?.input.ticker}: {Math.round(selectedResult?.result.probability || 0)}%
          </StatusPill>
          <StatusPill tone={STAGE_META[selectedResult?.result.stage]?.tone || "neutral"}>
            {STAGE_META[selectedResult?.result.stage]?.label || "Unknown stage"}
          </StatusPill>
        </div>
      </header>

      <section className="status-grid">
        <StatCard
          label="Runtime"
          value={overallSeverity === "ready" ? "Healthy" : overallSeverity.toUpperCase()}
          tone={overallSeverity === "ready" ? "good" : overallSeverity}
          detail={`Global listeners active. ${runtimeHealth.events.length} recent event(s).`}
        />
        <StatCard
          label="Storage"
          value={storageCardValue}
          tone={storageCardTone}
          detail={storageCardDetail}
        />
        <StatCard
          label="Import Parser"
          value={historyPreview.error ? "Blocked" : `${historyPreview.rows.length} rows ready`}
          tone={historyPreview.error ? "error" : "good"}
          detail={
            historyPreview.error ||
            `Data will update ${selectedTicker} peak and current price when applied.`
          }
        />
        <StatCard
          label="Portfolio Budget"
          value={formatCurrency(investmentAmount)}
          tone="neutral"
          detail={`${results.filter((entry) => !entry.result.disqualified).length} active candidates`}
        />
      </section>

      <main className="dashboard-grid">
        <section className="panel watchlist-panel">
          <div className="panel-header">
            <div>
              <p className="panel-kicker">Watchlist</p>
              <h2>Ranked setups</h2>
            </div>
            <button type="button" className="secondary-button" onClick={addStock}>
              Add ticker
            </button>
          </div>

          <div className="watchlist">
            {results.map(({ input, result }) => (
              <button
                key={input.ticker}
                type="button"
                className={`watchlist-item ${input.ticker === selectedTicker ? "is-active" : ""}`}
                onClick={() => setSelectedTicker(input.ticker)}
              >
                <div>
                  <strong>{input.ticker}</strong>
                  <span>{STAGE_META[result.stage]?.label || "Unknown stage"}</span>
                </div>
                <div className="watchlist-meta">
                  <span className={`mini-pill tone-${scoreTone(result.probability)}`}>
                    {Math.round(result.probability)}%
                  </span>
                  {result.disqualified ? (
                    <span className="mini-pill tone-error">Skip</span>
                  ) : null}
                </div>
              </button>
            ))}
          </div>

          <div className="panel-divider" />

          <Suspense
            fallback={
              <div className="chart-shell tall-chart">
                <div className="empty-state">Loading watchlist chart…</div>
              </div>
            }
          >
            <WorkbenchChart variant="leaderboard" leaderboardData={leaderboardData} />
          </Suspense>
        </section>

        <section className="panel analysis-panel">
          <div className="panel-header">
            <div>
              <p className="panel-kicker">Selected Analysis</p>
              <h2>{selectedStock?.ticker || "No ticker selected"}</h2>
            </div>
            <div className="header-actions">
              <button type="button" className="secondary-button" onClick={removeSelectedStock}>
                Remove
              </button>
              <button type="button" className="secondary-button" onClick={resetWorkspace}>
                Restore defaults
              </button>
            </div>
          </div>

          {selectedResult ? (
            <>
              <section className="summary-grid">
                <StatCard
                  label="Probability"
                  value={`${Math.round(selectedResult.result.probability)}%`}
                  tone={scoreTone(selectedResult.result.probability)}
                  detail={selectedResult.result.disqualified ? "Disqualified setup" : "Weighted model score"}
                />
                <StatCard
                  label="Depth"
                  value={formatPercent(selectedResult.result.depth_pct)}
                  tone={selectedResult.result.depth_pct <= 35 ? "good" : "warning"}
                  detail="Percentage below prior peak"
                />
                <StatCard
                  label="Position"
                  value={formatCurrency(selectedResult.result.suggested_position_dollars)}
                  tone="neutral"
                  detail={`${selectedResult.result.suggested_shares} suggested shares`}
                />
                <StatCard
                  label="Risk"
                  value={selectedResult.result.estimated_risk}
                  tone={selectedResult.result.estimated_risk === "Moderate" ? "good" : "warning"}
                  detail={STAGE_META[selectedResult.result.stage]?.label || "Unknown stage"}
                />
              </section>

              <div className="alert-card">
                <StatusPill tone={STAGE_META[selectedResult.result.stage]?.tone || "neutral"}>
                  {STAGE_META[selectedResult.result.stage]?.label || "Unknown stage"}
                </StatusPill>
                <p>{selectedResult.result.alert}</p>
              </div>

              <section className="provenance-panel">
                <div className="provenance-header">
                  <div>
                    <p className="panel-kicker">Data Transparency</p>
                    <h3>Source and verification</h3>
                  </div>
                  <StatusPill tone={selectedProvenance.tone}>
                    {selectedProvenance.label}
                  </StatusPill>
                </div>
                <p className="provenance-copy">{selectedProvenance.detail}</p>
                <div className="provenance-grid">
                  <div className="provenance-item">
                    <span>Ticker</span>
                    <strong>{selectedTicker}</strong>
                  </div>
                  <div className="provenance-item">
                    <span>History rows</span>
                    <strong>{selectedHistory.length || 0}</strong>
                  </div>
                  <div className="provenance-item">
                    <span>Latest visible row</span>
                    <strong>
                      {selectedHistory[selectedHistory.length - 1]?.date || "No history attached"}
                    </strong>
                  </div>
                  <div className="provenance-item">
                    <span>Workspace note</span>
                    <strong>Model values can be edited locally</strong>
                  </div>
                </div>
                <div className="provenance-links">
                  <button
                    type="button"
                    className="primary-button"
                    onClick={syncSelectedTickerWithMarketFeed}
                    disabled={marketSyncState.status === "syncing"}
                  >
                    {marketSyncState.status === "syncing"
                      ? `Syncing ${selectedTicker}...`
                      : `Sync ${selectedTicker} with market feed`}
                  </button>
                  <a
                    className="source-link"
                    href={marketFeedStatus.docsUrl}
                    target="_blank"
                    rel="noreferrer"
                  >
                    Provider docs
                  </a>
                  {selectedResearchLinks.map((link) => (
                    <a
                      key={link.label}
                      className="source-link"
                      href={link.href}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {link.label}
                    </a>
                  ))}
                </div>
                <div className="feed-status-bar">
                  <div className="feed-status-copy">
                    <span>Feed status</span>
                    <strong>
                      {marketFeedStatus.provider}
                      {marketFeedStatus.configured ? " configured" : " not configured"}
                    </strong>
                  </div>
                  <div className="feed-status-copy">
                    <span>Sync note</span>
                    <strong>{marketSyncState.message || marketFeedStatus.message}</strong>
                  </div>
                </div>
              </section>

              <div className="chart-grid">
                <div className="chart-card">
                  <div className="chart-card-header">
                    <h3>Price recovery map</h3>
                    <span>{selectedHistory.length ? `${selectedHistory.length} data points` : "No history"}</span>
                  </div>
                  <Suspense
                    fallback={
                      <div className="chart-shell">
                        <div className="empty-state">Loading history chart…</div>
                      </div>
                    }
                  >
                    <WorkbenchChart
                      variant="history"
                      historyData={selectedHistory}
                      selectedStock={selectedStock}
                      selectedHistoryStats={selectedHistoryStats}
                      currentPriceLabel={currentPriceTimestampLabel}
                    />
                  </Suspense>
                  <div className="chart-footnote">
                    {selectedHistoryStats.bottomPoint ? (
                      <span>
                        Rebound from low: {formatPercent(selectedHistoryStats.reboundPct)} since{" "}
                        {selectedHistoryStats.bottomPoint.date}
                      </span>
                    ) : (
                      <span>Import CSV or JSON history to activate this view.</span>
                    )}
                  </div>
                </div>

                <div className="chart-card">
                  <div className="chart-card-header">
                    <h3>Component score mix</h3>
                    <span>Weighted inputs behind the headline score</span>
                  </div>
                  <Suspense
                    fallback={
                      <div className="chart-shell">
                        <div className="empty-state">Loading score chart…</div>
                      </div>
                    }
                  >
                    <WorkbenchChart
                      variant="breakdown"
                      scoreBreakdownData={scoreBreakdownData}
                    />
                  </Suspense>
                </div>
              </div>

              <section className="insight-grid">
                <div className="subpanel">
                  <h3>Quality checks</h3>
                  {selectedResult.result.quality_flags.length ? (
                    <ul className="insight-list">
                      {selectedResult.result.quality_flags.map((flag) => (
                        <li key={flag}>{flag}</li>
                      ))}
                    </ul>
                  ) : (
                    <p className="insight-empty">No quality warnings for this setup.</p>
                  )}
                </div>

                <div className="subpanel">
                  <h3>Recent runtime events</h3>
                  {runtimeHealth.events.length ? (
                    <ul className="health-feed">
                      {runtimeHealth.events.map((event) => (
                        <li key={event.id}>
                          <div>
                            <StatusPill tone={event.severity === "info" ? "neutral" : event.severity}>
                              {event.source}
                            </StatusPill>
                            <span>{event.message}</span>
                          </div>
                          <small>{formatDateTime(event.timestamp)}</small>
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="insight-empty">No warnings or runtime failures have been captured.</p>
                  )}
                </div>
              </section>
            </>
          ) : (
            <div className="empty-state">The workspace has no selected ticker.</div>
          )}
        </section>

        <section className="panel controls-panel">
          <div className="panel-header">
            <div>
              <p className="panel-kicker">Control Center</p>
              <h2>Setup and data</h2>
            </div>
          </div>

          {selectedStock ? (
            <>
              <div className="controls-overview">
                <div className="controls-overview-copy">
                  <strong>{selectedTicker}</strong>
                  <span>
                    {STAGE_META[selectedResult?.result.stage]?.label || "Unknown stage"} setup
                  </span>
                </div>
                <div className="controls-overview-meta">
                  <StatusPill tone={scoreTone(selectedResult?.result.probability || 0)}>
                    {Math.round(selectedResult?.result.probability || 0)}% score
                  </StatusPill>
                  <StatusPill tone={historyPreview.error ? "error" : "neutral"}>
                    {historyPreview.error ? "Import blocked" : `${historyPreview.rows.length} rows ready`}
                  </StatusPill>
                  <StatusPill tone={vaultStatusTone}>
                    {!workspaceVaultStatus.checked
                      ? "Vault checking"
                      : workspaceVaultStatus.available
                      ? `${workspaceVaultStatus.snapshotCount} vault snapshot(s)`
                      : "Vault unavailable"}
                  </StatusPill>
                </div>
              </div>

              <div className="controls-nav" role="tablist" aria-label="Control center views">
                <button
                  type="button"
                  className={`control-tab ${controlsView === "setup" ? "is-active" : ""}`}
                  onClick={() => setControlsView("setup")}
                >
                  Setup
                </button>
                <button
                  type="button"
                  className={`control-tab ${controlsView === "guide" ? "is-active" : ""}`}
                  onClick={() => setControlsView("guide")}
                >
                  Logic guide
                </button>
                <button
                  type="button"
                  className={`control-tab ${controlsView === "history" ? "is-active" : ""}`}
                  onClick={() => setControlsView("history")}
                >
                  History import
                </button>
                <button
                  type="button"
                  className={`control-tab ${controlsView === "vault" ? "is-active" : ""}`}
                  onClick={() => setControlsView("vault")}
                >
                  Vault
                </button>
              </div>

              {controlsView === "setup" ? (
                <div className="section-stack">
                  <div className="subpanel rail-panel">
                    <div className="section-intro">
                      <h3>Price and capital</h3>
                      <p>
                        Define the current trading context before adjusting pattern-specific
                        signals.
                      </p>
                    </div>
                    <div className="rail-form">
                      <Field
                        label="Ticker"
                        helper={
                          <span className="field-helper">
                            Identifier for the active setup. Use the watchlist on the left to
                            switch names.
                          </span>
                        }
                      >
                        <input type="text" value={selectedStock.ticker} disabled />
                      </Field>
                      <Field
                        label="Portfolio budget"
                        helper={
                          <>
                            <span className="field-helper">
                              Sets the capital base used for the suggested position size. It does
                              not change the pattern score.
                            </span>
                            <span className="field-impact">
                              Current effect: position sizing is based on{" "}
                              {formatCurrency(investmentAmount)}.
                            </span>
                          </>
                        }
                      >
                        <input
                          type="number"
                          min="100"
                          step="100"
                          value={investmentAmount}
                          onChange={(event) =>
                            setInvestmentAmount(Math.max(100, Number(event.target.value) || 100))
                          }
                        />
                      </Field>
                      <Field
                        label="Peak price"
                        helper={
                          <>
                            <span className="field-helper">
                              The reference high before the decline started. The model uses this
                              with current price to measure drawdown depth.
                            </span>
                            <span className="field-impact">
                              Current effect: depth is measured from{" "}
                              {formatCurrency(selectedStock.peak_price)}.
                            </span>
                          </>
                        }
                      >
                        <input
                          type="number"
                          min="1"
                          step="0.01"
                          value={selectedStock.peak_price}
                          onChange={(event) =>
                            updateSelectedStock(
                              "peak_price",
                              Math.max(1, Number(event.target.value) || 1),
                            )
                          }
                        />
                      </Field>
                      <Field
                        label={`Current price (${currentPriceTimestampLabel})`}
                        helper={
                          <>
                            <span className="field-helper">
                              The latest price in the setup. Together with peak price, it drives
                              decline depth and stage detection.
                            </span>
                            <span className="field-impact">
                              Current effect: the model reads the setup at{" "}
                              {formatCurrency(selectedStock.current_price)} {currentPriceTimestampLabel}.
                            </span>
                          </>
                        }
                      >
                        <input
                          type="number"
                          min="1"
                          step="0.01"
                          value={selectedStock.current_price}
                          onChange={(event) =>
                            updateSelectedStock(
                              "current_price",
                              Math.max(1, Number(event.target.value) || 1),
                            )
                          }
                        />
                      </Field>
                    </div>
                  </div>

                  <div className="subpanel rail-panel">
                    <div className="section-intro">
                      <h3>Pattern and confirmation signals</h3>
                      <p>
                        These controls drive weighted scoring, stage progression, and
                        disqualification logic.
                      </p>
                    </div>
                    <div className="rail-form">
                      <Field
                        label="Decline reason"
                        helper={
                          <>
                            <span className="field-helper">
                              Tells the model why the stock sold off. Cyclical pullbacks can form
                              constructive bases, while fundamental damage usually breaks the
                              pattern.
                            </span>
                            <span className="field-impact">
                              Current effect: {dropdownGuidance[0]?.impact}
                            </span>
                          </>
                        }
                      >
                        <select
                          value={selectedStock.decline_reason}
                          onChange={(event) =>
                            updateSelectedStock("decline_reason", event.target.value)
                          }
                        >
                          <option value={DeclineReason.MACRO_SENTIMENT}>Macro or sentiment</option>
                          <option value={DeclineReason.UNKNOWN}>Unknown</option>
                          <option value={DeclineReason.FUNDAMENTAL}>
                            Fundamental deterioration
                          </option>
                        </select>
                      </Field>
                      <Field
                        label="Decline shape"
                        helper={
                          <>
                            <span className="field-helper">
                              Describes how the selloff looked on the chart. Smooth, rounded
                              damage is more constructive than abrupt vertical breaks.
                            </span>
                            <span className="field-impact">
                              Current effect: {dropdownGuidance[1]?.impact}
                            </span>
                          </>
                        }
                      >
                        <select
                          value={selectedStock.decline_shape}
                          onChange={(event) =>
                            updateSelectedStock("decline_shape", event.target.value)
                          }
                        >
                          <option value={DeclineShape.GRADUAL_ROUNDED}>Gradual rounded</option>
                          <option value={DeclineShape.MIXED}>Mixed</option>
                          <option value={DeclineShape.VERTICAL_CLIFF}>Vertical cliff</option>
                        </select>
                      </Field>
                      <Field
                        label="Fundamentals score"
                        helper={
                          <>
                            <span className="field-helper">
                              Rates business quality from 1 to 5. Stronger fundamentals support
                              recovery and improve the weighted score.
                            </span>
                            <span className="field-impact">
                              Current effect: {selectedStock.fundamentals_score}/5 is feeding the
                              fundamentals component.
                            </span>
                          </>
                        }
                      >
                        <input
                          type="range"
                          min="1"
                          max="5"
                          step="1"
                          value={selectedStock.fundamentals_score}
                          onChange={(event) =>
                            updateSelectedStock("fundamentals_score", Number(event.target.value))
                          }
                        />
                      </Field>
                      <Field
                        label="Sideways weeks"
                        helper={
                          <>
                            <span className="field-helper">
                              Estimates how long the stock has spent stabilizing near the lows.
                              More time at the bottom supports a base-forming interpretation.
                            </span>
                            <span className="field-impact">
                              Current effect: {selectedStock.weeks_sideways_at_bottom} week(s) are
                              helping stage detection.
                            </span>
                          </>
                        }
                      >
                        <input
                          type="number"
                          min="0"
                          max="20"
                          step="1"
                          value={selectedStock.weeks_sideways_at_bottom}
                          onChange={(event) =>
                            updateSelectedStock(
                              "weeks_sideways_at_bottom",
                              Math.max(0, Math.min(20, Number(event.target.value) || 0)),
                            )
                          }
                        />
                      </Field>
                      <Field
                        label="Prior uptrend"
                        helper={
                          <>
                            <span className="field-helper">
                              Indicates whether the stock had a meaningful advance before the
                              pullback. A cup-and-handle is usually a continuation pattern.
                            </span>
                            <span className="field-impact">
                              Current effect: {dropdownGuidance[2]?.impact}
                            </span>
                          </>
                        }
                      >
                        <select
                          value={String(selectedStock.had_clear_prior_uptrend)}
                          onChange={(event) =>
                            updateSelectedStock(
                              "had_clear_prior_uptrend",
                              event.target.value === "true",
                            )
                          }
                        >
                          <option value="true">Clear prior uptrend</option>
                          <option value="false">No prior uptrend</option>
                        </select>
                      </Field>
                      <Field
                        label="Volume drying at bottom"
                        helper={
                          <>
                            <span className="field-helper">
                              Use this to reflect whether selling volume cooled off near the low.
                              Drying volume often signals that supply is being absorbed.
                            </span>
                            <span className="field-impact">
                              Current effect: {dropdownGuidance[3]?.impact}
                            </span>
                          </>
                        }
                      >
                        <select
                          value={String(selectedStock.volume_drying_up_at_bottom)}
                          onChange={(event) =>
                            updateSelectedStock(
                              "volume_drying_up_at_bottom",
                              normalizeTriState(event.target.value),
                            )
                          }
                        >
                          <option value="true">Yes</option>
                          <option value="false">No</option>
                          <option value="null">Unknown</option>
                        </select>
                      </Field>
                      <Field
                        label="Volume picking up"
                        helper={
                          <>
                            <span className="field-helper">
                              Reflects whether buying activity is strengthening on the right side
                              of the cup. Rising participation helps confirm a real recovery.
                            </span>
                            <span className="field-impact">
                              Current effect: {dropdownGuidance[4]?.impact}
                            </span>
                          </>
                        }
                      >
                        <select
                          value={String(selectedStock.volume_picking_up_on_right_side)}
                          onChange={(event) =>
                            updateSelectedStock(
                              "volume_picking_up_on_right_side",
                              normalizeTriState(event.target.value),
                            )
                          }
                        >
                          <option value="true">Yes</option>
                          <option value="false">No</option>
                          <option value="null">Unknown</option>
                        </select>
                      </Field>
                      <Field
                        label="Sector regime"
                        helper={
                          <>
                            <span className="field-helper">
                              Tells the model whether the broader group is likely in a temporary
                              cycle or a longer structural decline.
                            </span>
                            <span className="field-impact">
                              Current effect: {dropdownGuidance[5]?.impact}
                            </span>
                          </>
                        }
                      >
                        <select
                          value={selectedStock.sector_type}
                          onChange={(event) =>
                            updateSelectedStock("sector_type", event.target.value)
                          }
                        >
                          <option value={SectorType.CYCLICAL}>Cyclical recovery</option>
                          <option value={SectorType.STRUCTURAL}>Structural decline</option>
                        </select>
                      </Field>
                    </div>
                  </div>
                </div>
              ) : null}

              {controlsView === "guide" ? (
                <div className="section-stack">
                  <div className="subpanel rail-panel input-guide-panel">
                    <div className="section-intro">
                      <h3>Why the dropdowns matter</h3>
                      <p>
                        These controls are not cosmetic. Each one changes either the weighted
                        score, the stage classification, or whether the setup is disqualified.
                      </p>
                    </div>
                    <ul className="guide-list">
                      {dropdownGuidance.map((item) => (
                        <li key={item.label}>
                          <strong>{item.label}: </strong>
                          <span className="guide-current">{item.current}. </span>
                          <span>{item.impact}</span>
                        </li>
                      ))}
                    </ul>
                  </div>

                  <div className="subpanel rail-panel">
                    <div className="section-intro">
                      <h3>How to use the model</h3>
                      <p>
                        Think of this view as a disciplined checklist, not a prediction engine.
                      </p>
                    </div>
                    <ul className="guide-list">
                      <li>Start with price anchors and make sure the drawdown depth is realistic.</li>
                      <li>Use the dropdowns to encode market context that the chart alone cannot express.</li>
                      <li>Prefer `Unknown` over guessing when volume evidence is incomplete.</li>
                      <li>Use history import when you want the peak and current price to update from actual rows instead of manual estimates.</li>
                    </ul>
                  </div>
                </div>
              ) : null}

              {controlsView === "history" ? (
                <div className="section-stack">
                  <div className="subpanel rail-panel history-editor">
                    <div className="section-intro">
                      <h3>History import</h3>
                      <p>
                        Paste a CSV or JSON array to refresh the selected ticker from actual price
                        rows.
                      </p>
                    </div>
                    <textarea
                      value={historyInput}
                      onChange={(event) => setHistoryInput(event.target.value)}
                      rows={14}
                      spellCheck="false"
                    />
                    <div className="import-status">
                      <StatusPill tone={historyPreview.error ? "error" : "good"}>
                        {historyPreview.error
                          ? "Import blocked"
                          : `${historyPreview.rows.length} rows parsed`}
                      </StatusPill>
                      <span>
                        {historyPreview.error ||
                          `Latest imported close: ${formatCurrency(
                            historyPreview.rows[historyPreview.rows.length - 1]?.close || 0,
                          )}`}
                      </span>
                    </div>
                    <div className="button-row">
                      <button
                        type="button"
                        className="primary-button"
                        onClick={applyImportedHistory}
                      >
                        Apply history to {selectedTicker}
                      </button>
                      <button
                        type="button"
                        className="secondary-button"
                        onClick={() =>
                          setHistoryInput(
                            rowsToCsv(
                              historyByTicker[selectedTicker] ||
                                DEMO_HISTORY[selectedTicker] ||
                                [],
                            ),
                          )
                        }
                      >
                        Reload saved history
                      </button>
                    </div>
                  </div>
                </div>
              ) : null}

              {controlsView === "vault" ? (
                <div className="section-stack">
                  <div className="subpanel rail-panel vault-panel">
                    <div className="section-intro">
                      <h3>Workspace vault</h3>
                      <p>
                        Save named server-side snapshots so the watchlist, imported history, and
                        live-feed context can be recovered outside this browser session.
                      </p>
                    </div>

                    <div className="vault-status-grid">
                      <div className="feed-status-copy">
                        <span>Vault status</span>
                        <strong>
                          {!workspaceVaultStatus.checked
                            ? "Checking"
                            : workspaceVaultStatus.available
                              ? "Available"
                              : "Unavailable"}
                        </strong>
                      </div>
                      <div className="feed-status-copy">
                        <span>Storage path</span>
                        <strong>
                          {workspaceVaultStatus.storagePath || "Server path not reported"}
                        </strong>
                      </div>
                    </div>

                    <Field
                      label="Snapshot name"
                      helper="Use a descriptive name so this market view can be reopened later."
                    >
                      <input
                        type="text"
                        value={workspaceDraftName}
                        onChange={(event) => setWorkspaceDraftName(event.target.value)}
                        placeholder={createDefaultWorkspaceName(selectedTicker)}
                      />
                    </Field>

                    <div className="button-row">
                      <button
                        type="button"
                        className="primary-button"
                        onClick={() => saveCurrentWorkspaceToVault("")}
                        disabled={!workspaceVaultStatus.available || workspaceVaultAction.status === "saving"}
                      >
                        Save new snapshot
                      </button>
                      <button
                        type="button"
                        className="secondary-button"
                        onClick={() => saveCurrentWorkspaceToVault(activeWorkspaceSnapshotId)}
                        disabled={
                          !workspaceVaultStatus.available ||
                          !activeWorkspaceSnapshotId ||
                          workspaceVaultAction.status === "saving"
                        }
                      >
                        Update loaded snapshot
                      </button>
                    </div>

                    <div className="import-status vault-message">
                      <StatusPill tone={vaultActionTone}>
                        {workspaceVaultAction.status === "saving"
                          ? "Working"
                          : workspaceVaultAction.status === "success"
                            ? "Saved"
                            : workspaceVaultAction.status === "error"
                              ? "Action blocked"
                              : "Ready"}
                      </StatusPill>
                      <span>
                        {workspaceVaultAction.message || workspaceVaultStatus.message}
                      </span>
                    </div>
                  </div>

                  <div className="subpanel rail-panel vault-panel">
                    <div className="section-intro">
                      <h3>Saved snapshots</h3>
                      <p>
                        Load or remove named snapshots from the server vault. The active browser
                        workspace will sync after a load.
                      </p>
                    </div>

                    {workspaceSnapshots.length ? (
                      <div className="snapshot-list">
                        {workspaceSnapshots.map((snapshot) => (
                          <div
                            key={snapshot.id}
                            className={`snapshot-item ${
                              snapshot.id === activeWorkspaceSnapshotId ? "is-active" : ""
                            }`}
                          >
                            <div className="snapshot-copy">
                              <div className="snapshot-title-row">
                                <strong>{snapshot.name}</strong>
                                {snapshot.id === activeWorkspaceSnapshotId ? (
                                  <StatusPill tone="good">Loaded</StatusPill>
                                ) : null}
                              </div>
                              <div className="snapshot-meta">
                                <span>{snapshot.tickerCount} ticker(s)</span>
                                <span>{snapshot.selectedTicker} selected</span>
                                <span>{snapshot.liveTickerCount} live feed sync(s)</span>
                                <span>
                                  Updated {formatDateTimeLong(snapshot.updatedAt)}
                                </span>
                              </div>
                            </div>
                            <div className="snapshot-actions">
                              <button
                                type="button"
                                className="secondary-button"
                                onClick={() => loadWorkspaceFromVault(snapshot.id)}
                                disabled={workspaceVaultAction.status === "saving"}
                              >
                                Load
                              </button>
                              <button
                                type="button"
                                className="secondary-button danger-button"
                                onClick={() =>
                                  removeWorkspaceFromVault(snapshot.id, snapshot.name)
                                }
                                disabled={workspaceVaultAction.status === "saving"}
                              >
                                Delete
                              </button>
                            </div>
                          </div>
                        ))}
                      </div>
                    ) : (
                      <div className="empty-state">
                        No server snapshots exist yet. Save the current workspace to create one.
                      </div>
                    )}
                  </div>
                </div>
              ) : null}
            </>
          ) : (
            <div className="empty-state">Select a ticker to edit its inputs.</div>
          )}
        </section>
      </main>
    </div>
  );
}
