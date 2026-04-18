/**
 * SplitterHook — drives a draggable column resizer between two panels.
 *
 * Expected DOM (children of this.el):
 *   #left-panel    initial style="width: XX%"
 *   #resizer       the grab handle
 *   #right-panel   initial style="width: 100-XX%"
 *
 * The hook clamps the left panel's width between MIN_PCT and MAX_PCT and
 * mirrors the remainder onto the right panel. ECharts (or any other
 * ResizeObserver-based child) reflows on its own when the panel resizes.
 */

const MIN_PCT = 25;
const MAX_PCT = 75;

const SplitterHook = {
  mounted() {
    this.leftPanel = this.el.querySelector("#left-panel");
    this.rightPanel = this.el.querySelector("#right-panel");
    this.resizer = this.el.querySelector("#resizer");

    this.isDragging = false;

    this._onMouseDown = (e) => {
      e.preventDefault();
      this.isDragging = true;
      document.body.style.userSelect = "none";
      document.body.style.cursor = "col-resize";
    };

    this._onMouseMove = (e) => {
      if (!this.isDragging) return;
      const rect = this.el.getBoundingClientRect();
      if (rect.width === 0) return;
      const rawPct = ((e.clientX - rect.left) / rect.width) * 100;
      const pct = Math.min(MAX_PCT, Math.max(MIN_PCT, rawPct));
      this.leftPanel.style.width = pct + "%";
      this.rightPanel.style.width = 100 - pct + "%";
    };

    this._onMouseUp = () => {
      if (!this.isDragging) return;
      this.isDragging = false;
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
    };

    this.resizer.addEventListener("mousedown", this._onMouseDown);
    window.addEventListener("mousemove", this._onMouseMove);
    window.addEventListener("mouseup", this._onMouseUp);
  },

  destroyed() {
    if (this.resizer) {
      this.resizer.removeEventListener("mousedown", this._onMouseDown);
    }
    window.removeEventListener("mousemove", this._onMouseMove);
    window.removeEventListener("mouseup", this._onMouseUp);
    document.body.style.userSelect = "";
    document.body.style.cursor = "";
  },
};

export default SplitterHook;
