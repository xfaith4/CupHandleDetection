import React from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Legend,
  Line,
  LineChart,
  ReferenceDot,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

function barColor(value) {
  if (value >= 75) return "#14746f";
  if (value >= 55) return "#4d908e";
  if (value >= 35) return "#f4a261";
  return "#ef6f6c";
}

function formatCurrency(value) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: value >= 100 ? 0 : 2,
  }).format(value || 0);
}

function chartTooltip({ active, payload, label, formatter }) {
  if (!active || !payload?.length) return null;
  return (
    <div className="chart-tooltip">
      <div className="chart-tooltip-label">{label}</div>
      {payload.map((entry) => (
        <div key={entry.dataKey} className="chart-tooltip-row">
          <span>{entry.name}</span>
          <strong>{formatter ? formatter(entry.value, entry.name) : entry.value}</strong>
        </div>
      ))}
    </div>
  );
}

export default function WorkbenchChart({
  variant,
  leaderboardData = [],
  historyData = [],
  selectedStock,
  selectedHistoryStats,
  scoreBreakdownData = [],
  currentPriceLabel = "local input",
}) {
  if (variant === "leaderboard") {
    return (
      <div className="chart-shell tall-chart">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={leaderboardData} margin={{ top: 6, right: 12, left: -18, bottom: 0 }}>
            <CartesianGrid vertical={false} strokeDasharray="3 3" />
            <XAxis dataKey="ticker" tickLine={false} axisLine={false} />
            <YAxis tickFormatter={(value) => `${value}%`} tickLine={false} axisLine={false} />
            <Tooltip
              content={(props) =>
                chartTooltip({ ...props, formatter: (value) => `${value}%` })
              }
            />
            <Legend />
            <Bar dataKey="probability" name="Cup probability">
              {leaderboardData.map((entry) => (
                <Cell key={entry.ticker} fill={barColor(entry.probability)} />
              ))}
            </Bar>
          </BarChart>
        </ResponsiveContainer>
      </div>
    );
  }

  if (variant === "history") {
    return (
      <div className="chart-shell">
        {historyData.length ? (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={historyData} margin={{ top: 12, right: 24, left: 0, bottom: 6 }}>
              <CartesianGrid vertical={false} strokeDasharray="3 3" />
              <XAxis dataKey="date" tickLine={false} axisLine={false} minTickGap={24} />
              <YAxis
                domain={["dataMin - 8", "dataMax + 8"]}
                tickFormatter={(value) => `$${value}`}
                tickLine={false}
                axisLine={false}
                width={72}
              />
              <Tooltip
                content={(props) =>
                  chartTooltip({
                    ...props,
                    formatter: (value) => formatCurrency(value),
                  })
                }
              />
              <ReferenceLine
                y={selectedStock?.peak_price}
                stroke="#14746f"
                strokeDasharray="4 4"
                label="Peak"
              />
              <ReferenceLine
                y={selectedStock?.current_price}
                stroke="#ef6f6c"
                strokeDasharray="4 4"
                label={`Current · ${currentPriceLabel}`}
              />
              <ReferenceDot
                x={selectedHistoryStats?.peakPoint?.date}
                y={selectedHistoryStats?.peakPoint?.close}
                r={5}
                fill="#14746f"
              />
              <ReferenceDot
                x={selectedHistoryStats?.bottomPoint?.date}
                y={selectedHistoryStats?.bottomPoint?.close}
                r={5}
                fill="#c2410c"
              />
              <Line
                type="monotone"
                dataKey="close"
                name="Close"
                stroke="#102a43"
                strokeWidth={3}
                dot={false}
                activeDot={{ r: 5 }}
              />
            </LineChart>
          </ResponsiveContainer>
        ) : (
          <div className="empty-state">No price history is attached to this ticker yet.</div>
        )}
      </div>
    );
  }

  if (variant === "breakdown") {
    return (
      <div className="chart-shell">
        {scoreBreakdownData.length ? (
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={scoreBreakdownData} layout="vertical" margin={{ left: 16, right: 12 }}>
              <CartesianGrid horizontal={false} strokeDasharray="3 3" />
              <XAxis type="number" tickFormatter={(value) => `${value}%`} tickLine={false} axisLine={false} />
              <YAxis
                dataKey="label"
                type="category"
                tickLine={false}
                axisLine={false}
                width={110}
              />
              <Tooltip
                content={(props) =>
                  chartTooltip({ ...props, formatter: (value) => `${value}%` })
                }
              />
              <Bar dataKey="score" name="Component score">
                {scoreBreakdownData.map((entry) => (
                  <Cell key={entry.label} fill={barColor(entry.score)} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        ) : (
          <div className="empty-state">
            Disqualified setups skip weighted scoring and show as zero conviction.
          </div>
        )}
      </div>
    );
  }

  return <div className="empty-state">Unknown chart variant requested.</div>;
}
