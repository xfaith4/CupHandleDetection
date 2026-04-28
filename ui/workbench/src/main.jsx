import React from "react";
import { createRoot } from "react-dom/client";

import CupHandleWorkbench from "../StartingPoint.js";
import "./styles.css";

class AppErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null, resetCount: 0 };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  handleReset = () => {
    this.setState((current) => ({
      error: null,
      resetCount: current.resetCount + 1,
    }));
  };

  render() {
    if (this.state.error) {
      return (
        <div className="boundary-shell">
          <div className="boundary-card">
            <p className="eyebrow">Runtime Failure</p>
            <h1>The UI crashed inside the React tree.</h1>
            <p className="hero-copy">
              The application caught the failure in an error boundary instead of leaving a blank
              screen.
            </p>
            <pre className="boundary-error">
              {this.state.error?.stack || this.state.error?.message || "Unknown render failure"}
            </pre>
            <div className="button-row">
              <button type="button" className="primary-button" onClick={this.handleReset}>
                Reset React tree
              </button>
              <button
                type="button"
                className="secondary-button"
                onClick={() => window.location.reload()}
              >
                Reload page
              </button>
            </div>
          </div>
        </div>
      );
    }

    return <CupHandleWorkbench key={this.state.resetCount} />;
  }
}

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <AppErrorBoundary />
  </React.StrictMode>,
);
