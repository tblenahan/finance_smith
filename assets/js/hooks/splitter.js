/**
 * SplitterHook — drives a draggable column resizer between two panels.
 *
 * Expected DOM (children of this.el):
 *   #left-panel    initial style="width: XX%"
 *   #resizer       the grab handle (role="separator", aria-valuenow set dynamically)
 *   #right-panel   initial style="width: 100-XX%"
 *
 * Uses Pointer Events (pointerdown/pointermove/pointerup + setPointerCapture)
 * so that dragging works on touch and pen input as well as mouse.
 * ECharts (or any other ResizeObserver-based child) reflows on its own
 * when the panel resizes.
 *
 * Keyboard: left/right arrow keys adjust split by STEP_PCT while focused.
 */

const MIN_PCT = 25;
const MAX_PCT = 75;
const STEP_PCT = 5;

const SplitterHook = {
  mounted() {
    this.leftPanel = this.el.querySelector("#left-panel");
    this.rightPanel = this.el.querySelector("#right-panel");
    this.resizer = this.el.querySelector("#resizer");

    // Seed aria-valuenow from the initial inline style.
    const initialPct = Math.round(parseFloat(this.leftPanel.style.width) || 66);
    this._setPct(initialPct);

    this._onPointerDown = (e) => {
      e.preventDefault();
      this.resizer.setPointerCapture(e.pointerId);
      document.body.style.userSelect = "none";
      document.body.style.cursor = "col-resize";
    };

    this._onPointerMove = (e) => {
      if (!this.resizer.hasPointerCapture(e.pointerId)) return;
      const rect = this.el.getBoundingClientRect();
      if (rect.width === 0) return;
      const rawPct = ((e.clientX - rect.left) / rect.width) * 100;
      this._setPct(Math.min(MAX_PCT, Math.max(MIN_PCT, rawPct)));
    };

    this._onPointerUp = (e) => {
      if (!this.resizer.hasPointerCapture(e.pointerId)) return;
      this.resizer.releasePointerCapture(e.pointerId);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
    };

    this._onKeyDown = (e) => {
      const current = parseFloat(this.leftPanel.style.width) || MIN_PCT;
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        this._setPct(Math.max(MIN_PCT, current - STEP_PCT));
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        this._setPct(Math.min(MAX_PCT, current + STEP_PCT));
      }
    };

    this.resizer.addEventListener("pointerdown", this._onPointerDown);
    this.resizer.addEventListener("pointermove", this._onPointerMove);
    this.resizer.addEventListener("pointerup", this._onPointerUp);
    this.resizer.addEventListener("keydown", this._onKeyDown);
  },

  _setPct(pct) {
    const rounded = Math.round(pct);
    this.leftPanel.style.width = rounded + "%";
    this.rightPanel.style.width = 100 - rounded + "%";
    this.resizer.setAttribute("aria-valuenow", rounded);
    this.resizer.setAttribute("aria-valuemin", MIN_PCT);
    this.resizer.setAttribute("aria-valuemax", MAX_PCT);
  },

  destroyed() {
    if (this.resizer) {
      this.resizer.removeEventListener("pointerdown", this._onPointerDown);
      this.resizer.removeEventListener("pointermove", this._onPointerMove);
      this.resizer.removeEventListener("pointerup", this._onPointerUp);
      this.resizer.removeEventListener("keydown", this._onKeyDown);
    }
    document.body.style.userSelect = "";
    document.body.style.cursor = "";
  },
};

export default SplitterHook;
