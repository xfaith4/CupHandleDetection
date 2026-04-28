import React, { useMemo, useState } from "react";

export default function CupHandleModelUI() {
  const WEIGHTS = {
    decline_reason: 30,
    prior_uptrend: 15,
    decline_depth: 20,
    decline_shape: 10,
    volume_profile: 10,
    fundamentals: 10,
    sector_type: 5,
  };

  const DeclineReason = {
    MACRO_SENTIMENT: "macro_sentiment",
    FUNDAMENTAL: "fundamental",
    UNKNOWN: "unknown",
  };

  const DeclineShape = {
    GRADUAL_ROUNDED: "gradual_rounded",
    VERTICAL_CLIFF: "vertical_cliff",
    MIXED: "mixed",
  };

  const SectorType = {
    CYCLICAL: "cyclical",
    STRUCTURAL: "structural",
  };

  const CupStage = {
    LEFT_SIDE_EARLY: "left_side_early",
    LEFT_SIDE_LATE: "left_side_late",
    CUP_BOTTOM: "cup_bottom",
    RIGHT_SIDE: "right_side",
    HANDLE: "handle",
    BREAKOUT: "breakout",
    INDETERMINATE: "indeterminate",
  };

  const defaultStocks = [
    {
      ticker: "MSFT",
      decline_reason: DeclineReason.MACRO_SENTIMENT,
      had_clear_prior_uptrend: true,
      peak_price: 525,
      current_price: 369,
      decline_shape: DeclineShape.VERTICAL_CLIFF,
      volume_drying_up_at_bottom: false,
      volume_picking_up_on_right_side: false,
      fundamentals_score: 5,
      sector_type: SectorType.CYCLICAL,
      weeks_sideways_at_bottom: 0,
    },
    {
      ticker: "AMZN",
      decline_reason: DeclineReason.MACRO_SENTIMENT,
      had_clear_prior_uptrend: true,
      peak_price: 245,
      current_price: 210,
      decline_shape: DeclineShape.GRADUAL_ROUNDED,
      volume_drying_up_at_bottom: true,
      volume_picking_up_on_right_side: false,
      fundamentals_score: 5,
      sector_type: SectorType.CYCLICAL,
      weeks_sideways_at_bottom: 4,
    },
    {
      ticker: "JPM",
      decline_reason: DeclineReason.MACRO_SENTIMENT,
      had_clear_prior_uptrend: true,
      peak_price: 333,
      current_price: 292,
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
      current_price: 290,
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
      current_price: 122,
      decline_shape: DeclineShape.GRADUAL_ROUNDED,
      volume_drying_up_at_bottom: true,
      volume_picking_up_on_right_side: true,
      fundamentals_score: 4,
      sector_type: SectorType.CYCLICAL,
      weeks_sideways_at_bottom: 6,
    },
  ];

  const [stocks, setStocks] = useState(defaultStocks);
  const [selectedIndex, setSelectedIndex] = useState(0);

  function scoreDeclineReason(reason) {
    return {
      [DeclineReason.MACRO_SENTIMENT]: 1.0,
      [DeclineReason.UNKNOWN]: 0.4,
      [DeclineReason.FUNDAMENTAL]: 0.0,
    }[reason];
  }

  function scorePriorUptrend(hadUptrend) {
    return hadUptrend ? 1.0 : 0.0;
  }

  function scoreDeclineDepth(peak, current) {
    if (peak <= 0 || current <= 0 || current >= peak) {
      return { score: 0.5, depth_pct: 0.0 };
    }
    const depth_pct = ((peak - current) / peak) * 100;
    let score = 0.0;
    if (depth_pct <= 20) score = 1.0;
    else if (depth_pct <= 30) score = 0.9;
    else if (depth_pct <= 35) score = 0.75;
    else if (depth_pct <= 45) score = 0.5;
    else if (depth_pct <= 55) score = 0.25;
    else score = 0.0;
    return { score, depth_pct };
  }

  function scoreDeclineShape(shape) {
    return {
      [DeclineShape.GRADUAL_ROUNDED]: 1.0,
      [DeclineShape.MIXED]: 0.5,
      [DeclineShape.VERTICAL_CLIFF]: 0.0,
    }[shape];
  }

  function scoreVolumeProfile(drying, pickingUp) {
    if (drying === null && pickingUp === null) return 0.5;
    const signals = [];
    if (drying !== null) signals.push(drying ? 1.0 : 0.0);
    if (pickingUp !== null) signals.push(pickingUp ? 1.0 : 0.0);
    return signals.reduce((a, b) => a + b, 0) / signals.length;
  }

  function scoreFundamentals(score) {
    const clamped = Math.max(1, Math.min(5, Number(score || 3)));
    return (clamped - 1) / 4;
  }

  function scoreSector(sector) {
    return {
      [SectorType.CYCLICAL]: 1.0,
      [SectorType.STRUCTURAL]: 0.0,
    }[sector];
  }

  function detectStage(s, depth_pct) {
    if (s.current_price >= s.peak_price) return CupStage.BREAKOUT;
    if (depth_pct < 10 && s.volume_picking_up_on_right_side === true) return CupStage.HANDLE;
    if (s.volume_picking_up_on_right_side === true && depth_pct < 40) return CupStage.RIGHT_SIDE;
    if (s.volume_drying_up_at_bottom === true || Number(s.weeks_sideways_at_bottom) >= 3) return CupStage.CUP_BOTTOM;
    if (s.decline_shape !== DeclineShape.VERTICAL_CLIFF && depth_pct >= 20 && depth_pct <= 45) return CupStage.LEFT_SIDE_LATE;
    if (depth_pct < 20 || s.decline_shape === DeclineShape.VERTICAL_CLIFF) return CupStage.LEFT_SIDE_EARLY;
    return CupStage.INDETERMINATE;
  }

  function generateAlert(stage, probability, ticker) {
    const alerts = {
      [CupStage.LEFT_SIDE_EARLY]: `[WATCH] ${ticker}: Still in early decline. No action — wait for selling to slow.`,
      [CupStage.LEFT_SIDE_LATE]: `[WATCH] ${ticker}: Approaching potential bottom. Begin monitoring volume for drying.`,
      [CupStage.CUP_BOTTOM]: `[ALERT] ${ticker}: Volume drying up — possible cup bottom forming. Watch for right-side reversal and volume pick-up. Primary entry zone.`,
      [CupStage.RIGHT_SIDE]: `[ALERT] ${ticker}: Right side building with increasing volume. Confirm fundamentals hold. Consider position sizing.`,
      [CupStage.HANDLE]: `[ALERT] ${ticker}: Handle forming. Tight consolidation above prior base. Watch for breakout above handle high on volume.`,
      [CupStage.BREAKOUT]: `[SIGNAL] ${ticker}: Price reclaiming prior highs. Breakout confirmation — monitor for follow-through volume.`,
      [CupStage.INDETERMINATE]: `[INFO] ${ticker}: Stage unclear — gather more price and volume data.`,
    };
    return `${alerts[stage]} (Cup formation probability: ${Math.round(probability)}%)`;
  }

  function evaluate(s) {
    if (s.decline_reason === DeclineReason.FUNDAMENTAL) {
      return {
        ticker: s.ticker,
        probability: 0,
        stage: CupStage.LEFT_SIDE_EARLY,
        alert: `[SKIP] ${s.ticker}: Fundamental decline detected — pattern unlikely.`,
        depth_pct: 0,
        component_scores: {},
        disqualified: true,
        disqualify_reason: "Internal/fundamental decline. Business has changed.",
      };
    }

    if (s.sector_type === SectorType.STRUCTURAL && Number(s.fundamentals_score) <= 2) {
      return {
        ticker: s.ticker,
        probability: 0,
        stage: CupStage.LEFT_SIDE_EARLY,
        alert: `[SKIP] ${s.ticker}: Structural sector decline + weak fundamentals — avoid.`,
        depth_pct: 0,
        component_scores: {},
        disqualified: true,
        disqualify_reason: "Structurally declining sector with poor fundamentals.",
      };
    }

    const { score: depthScore, depth_pct } = scoreDeclineDepth(Number(s.peak_price), Number(s.current_price));

    const component_scores = {
      decline_reason: scoreDeclineReason(s.decline_reason),
      prior_uptrend: scorePriorUptrend(!!s.had_clear_prior_uptrend),
      decline_depth: depthScore,
      decline_shape: scoreDeclineShape(s.decline_shape),
      volume_profile: scoreVolumeProfile(s.volume_drying_up_at_bottom, s.volume_picking_up_on_right_side),
      fundamentals: scoreFundamentals(Number(s.fundamentals_score)),
      sector_type: scoreSector(s.sector_type),
    };

    const probability = Math.max(
      0,
      Math.min(
        100,
        Number(
          Object.keys(component_scores)
            .reduce((sum, key) => sum + component_scores[key] * WEIGHTS[key], 0)
            .toFixed(1)
        )
      )
    );

    const stage = detectStage(s, depth_pct);
    const alert = generateAlert(stage, probability, s.ticker);

    return {
      ticker: s.ticker,
      probability,
      stage,
      alert,
      depth_pct: Number(depth_pct.toFixed(1)),
      component_scores,
      disqualified: false,
      disqualify_reason: "",
    };
  }

  const results = useMemo(() => {
    return stocks.map((s) => ({ input: s, result: evaluate(s) })).sort((a, b) => b.result.probability - a.result.probability);
  }, [stocks]);

  const selectedTicker = stocks[selectedIndex]?.ticker;
  const selectedResult = results.find((r) => r.input.ticker === selectedTicker) || { input: stocks[0], result: evaluate(stocks[0]) };

  function updateSelected(field, value) {
    setStocks((prev) => prev.map((stock, i) => (i === selectedIndex ? { ...stock, [field]: value } : stock)));
  }

  function addStock() {
    const newStock = {
      ticker: `NEW${stocks.length + 1}`,
      decline_reason: DeclineReason.UNKNOWN,
      had_clear_prior_uptrend: false,
      peak_price: 100,
      current_price: 80,
      decline_shape: DeclineShape.MIXED,
      volume_drying_up_at_bottom: null,
      volume_picking_up_on_right_side: null,
      fundamentals_score: 3,
      sector_type: SectorType.CYCLICAL,
      weeks_sideways_at_bottom: 0,
    };
    setStocks((prev) => [...prev, newStock]);
    setSelectedIndex(stocks.length);
  }

  function removeSelected() {
    if (stocks.length === 1) return;
    const next = stocks.filter((_, i) => i !== selectedIndex);
    setStocks(next);
    setSelectedIndex(Math.max(0, selectedIndex - 1));
  }

  function triBoolSelect(value, onChange) {
    return (
      <select
        value={value === null ? "unknown" : String(value)}
        onChange={(e) => {
          const v = e.target.value;
          onChange(v === "unknown" ? null : v === "true");
        }}
        className="w-full rounded-xl border px-3 py-2 bg-white"
      >
        <option value="unknown">Unknown</option>
        <option value="true">True</option>
        <option value="false">False</option>
      </select>
    );
  }

  function stageLabel(value) {
    return value.replaceAll("_", " ").replace(/\b\w/g, (m) => m.toUpperCase());
  }

  function scoreColor(probability) {
    if (probability >= 75) return "bg-green-100 text-green-800";
    if (probability >= 55) return "bg-yellow-100 text-yellow-800";
    return "bg-red-100 text-red-800";
  }

  function StageBadge({ stage }) {
    return (
      <span className="inline-flex items-center rounded-full border px-3 py-1 text-xs font-medium bg-slate-50">
        {stageLabel(stage)}
      </span>
    );
  }

  function ProgressBar({ value }) {
    return (
      <div className="w-full rounded-full bg-slate-200 h-3 overflow-hidden">
        <div className="h-3 rounded-full bg-slate-800" style={{ width: `${value}%` }} />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-slate-100 text-slate-900 p-6">
      <div className="max-w-7xl mx-auto grid grid-cols-1 xl:grid-cols-12 gap-6">
        <div className="xl:col-span-3 space-y-4">
          <div className="bg-white rounded-2xl shadow-sm border p-4">
            <div className="flex items-center justify-between mb-3">
              <div>
                <h1 className="text-xl font-semibold">Cup & Handle Model</h1>
                <p className="text-sm text-slate-600">Interactive UI built from your scoring model.</p>
              </div>
            </div>
            <div className="flex gap-2">
              <button onClick={addStock} className="rounded-xl px-3 py-2 bg-slate-900 text-white text-sm">Add Stock</button>
              <button onClick={removeSelected} className="rounded-xl px-3 py-2 border text-sm">Remove</button>
            </div>
          </div>

          <div className="bg-white rounded-2xl shadow-sm border p-3">
            <div className="text-sm font-medium mb-3">Universe</div>
            <div className="space-y-2">
              {stocks.map((stock, idx) => {
                const r = evaluate(stock);
                return (
                  <button
                    key={`${stock.ticker}-${idx}`}
                    onClick={() => setSelectedIndex(idx)}
                    className={`w-full text-left rounded-2xl border p-3 transition ${idx === selectedIndex ? "bg-slate-900 text-white border-slate-900" : "bg-white hover:bg-slate-50"}`}
                  >
                    <div className="flex items-center justify-between">
                      <div className="font-semibold">{stock.ticker}</div>
                      <div className={`text-xs px-2 py-1 rounded-full ${idx === selectedIndex ? "bg-white/20 text-white" : scoreColor(r.probability)}`}>
                        {Math.round(r.probability)}%
                      </div>
                    </div>
                    <div className={`text-xs mt-2 ${idx === selectedIndex ? "text-slate-200" : "text-slate-500"}`}>
                      {stageLabel(r.stage)}
                    </div>
                  </button>
                );
              })}
            </div>
          </div>
        </div>

        <div className="xl:col-span-5 space-y-6">
          <div className="bg-white rounded-2xl shadow-sm border p-5">
            <h2 className="text-lg font-semibold mb-4">Stock Input</h2>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <Field label="Ticker">
                <input value={stocks[selectedIndex]?.ticker || ""} onChange={(e) => updateSelected("ticker", e.target.value.toUpperCase())} className="w-full rounded-xl border px-3 py-2" />
              </Field>
              <Field label="Fundamentals Score (1–5)">
                <input type="number" min="1" max="5" value={stocks[selectedIndex]?.fundamentals_score || 3} onChange={(e) => updateSelected("fundamentals_score", Number(e.target.value))} className="w-full rounded-xl border px-3 py-2" />
              </Field>
              <Field label="Peak Price">
                <input type="number" value={stocks[selectedIndex]?.peak_price || 0} onChange={(e) => updateSelected("peak_price", Number(e.target.value))} className="w-full rounded-xl border px-3 py-2" />
              </Field>
              <Field label="Current Price">
                <input type="number" value={stocks[selectedIndex]?.current_price || 0} onChange={(e) => updateSelected("current_price", Number(e.target.value))} className="w-full rounded-xl border px-3 py-2" />
              </Field>
              <Field label="Decline Reason">
                <select value={stocks[selectedIndex]?.decline_reason || DeclineReason.UNKNOWN} onChange={(e) => updateSelected("decline_reason", e.target.value)} className="w-full rounded-xl border px-3 py-2 bg-white">
                  <option value={DeclineReason.MACRO_SENTIMENT}>Macro sentiment</option>
                  <option value={DeclineReason.FUNDAMENTAL}>Fundamental</option>
                  <option value={DeclineReason.UNKNOWN}>Unknown</option>
                </select>
              </Field>
              <Field label="Decline Shape">
                <select value={stocks[selectedIndex]?.decline_shape || DeclineShape.MIXED} onChange={(e) => updateSelected("decline_shape", e.target.value)} className="w-full rounded-xl border px-3 py-2 bg-white">
                  <option value={DeclineShape.GRADUAL_ROUNDED}>Gradual rounded</option>
                  <option value={DeclineShape.VERTICAL_CLIFF}>Vertical cliff</option>
                  <option value={DeclineShape.MIXED}>Mixed</option>
                </select>
              </Field>
              <Field label="Sector Type">
                <select value={stocks[selectedIndex]?.sector_type || SectorType.CYCLICAL} onChange={(e) => updateSelected("sector_type", e.target.value)} className="w-full rounded-xl border px-3 py-2 bg-white">
                  <option value={SectorType.CYCLICAL}>Cyclical</option>
                  <option value={SectorType.STRUCTURAL}>Structural</option>
                </select>
              </Field>
              <Field label="Weeks Sideways at Bottom">
                <input type="number" min="0" value={stocks[selectedIndex]?.weeks_sideways_at_bottom || 0} onChange={(e) => updateSelected("weeks_sideways_at_bottom", Number(e.target.value))} className="w-full rounded-xl border px-3 py-2" />
              </Field>
              <Field label="Had Clear Prior Uptrend">
                <select value={String(!!stocks[selectedIndex]?.had_clear_prior_uptrend)} onChange={(e) => updateSelected("had_clear_prior_uptrend", e.target.value === "true")} className="w-full rounded-xl border px-3 py-2 bg-white">
                  <option value="true">True</option>
                  <option value="false">False</option>
                </select>
              </Field>
              <Field label="Volume Drying Up at Bottom">
                {triBoolSelect(stocks[selectedIndex]?.volume_drying_up_at_bottom ?? null, (v) => updateSelected("volume_drying_up_at_bottom", v))}
              </Field>
              <Field label="Volume Picking Up on Right Side">
                {triBoolSelect(stocks[selectedIndex]?.volume_picking_up_on_right_side ?? null, (v) => updateSelected("volume_picking_up_on_right_side", v))}
              </Field>
            </div>
          </div>

          <div className="bg-white rounded-2xl shadow-sm border p-5">
            <div className="flex items-center justify-between gap-4 mb-4">
              <div>
                <h2 className="text-lg font-semibold">Current Evaluation</h2>
                <p className="text-sm text-slate-600">Selected ticker: {selectedResult.input.ticker}</p>
              </div>
              <StageBadge stage={selectedResult.result.stage} />
            </div>

            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-5">
              <MetricCard title="Probability" value={`${Math.round(selectedResult.result.probability)}%`} />
              <MetricCard title="Decline from Peak" value={`${selectedResult.result.depth_pct}%`} />
              <MetricCard title="Status" value={selectedResult.result.disqualified ? "Disqualified" : "Scored"} />
            </div>

            <ProgressBar value={selectedResult.result.probability} />

            <div className="mt-5 rounded-2xl bg-slate-50 border p-4 text-sm leading-6">
              {selectedResult.result.alert}
            </div>
          </div>
        </div>

        <div className="xl:col-span-4 space-y-6">
          <div className="bg-white rounded-2xl shadow-sm border p-5">
            <h2 className="text-lg font-semibold mb-4">Component Breakdown</h2>
            {selectedResult.result.disqualified ? (
              <div className="text-sm text-slate-600">{selectedResult.result.disqualify_reason}</div>
            ) : (
              <div className="space-y-3">
                {Object.entries(selectedResult.result.component_scores).map(([key, score]) => {
                  const weight = WEIGHTS[key];
                  const weighted = score * weight;
                  return (
                    <div key={key} className="rounded-2xl border p-3">
                      <div className="flex items-center justify-between mb-2">
                        <div className="text-sm font-medium capitalize">{key.replaceAll("_", " ")}</div>
                        <div className="text-xs text-slate-500">{weighted.toFixed(1)} pts</div>
                      </div>
                      <div className="text-xs text-slate-500 mb-2">{score.toFixed(2)} × {weight}</div>
                      <ProgressBar value={score * 100} />
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          <div className="bg-white rounded-2xl shadow-sm border p-5">
            <h2 className="text-lg font-semibold mb-4">Ranking</h2>
            <div className="space-y-3">
              {results.map(({ input, result }, idx) => (
                <div key={`${input.ticker}-${idx}`} className="rounded-2xl border p-3">
                  <div className="flex items-center justify-between mb-1">
                    <div className="font-semibold">{input.ticker}</div>
                    <div className={`text-xs px-2 py-1 rounded-full ${scoreColor(result.probability)}`}>
                      {Math.round(result.probability)}%
                    </div>
                  </div>
                  <div className="text-sm text-slate-600">{stageLabel(result.stage)}</div>
                </div>
              ))}
            </div>
          </div>

          <div className="bg-white rounded-2xl shadow-sm border p-5">
            <h2 className="text-lg font-semibold mb-3">Notes</h2>
            <ul className="text-sm text-slate-600 space-y-2 list-disc pl-5">
              <li>Preserves the logic from your uploaded Python model.</li>
              <li>Lets you adjust inputs and immediately re-rank the stock universe.</li>
              <li>Designed as a UI prototype that can later be wired to live market data.</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
  );
}

function Field({ label, children }) {
  return (
    <label className="block">
      <div className="text-sm font-medium mb-2">{label}</div>
      {children}
    </label>
  );
}

function MetricCard({ title, value }) {
  return (
    <div className="rounded-2xl border bg-slate-50 p-4">
      <div className="text-sm text-slate-600 mb-1">{title}</div>
      <div className="text-2xl font-semibold">{value}</div>
    </div>
  );
}
