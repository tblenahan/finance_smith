/**
 * ChartHook — renders an Apache ECharts instance inside a LiveView element.
 *
 * Usage in HEEx:
 *   <div id="my-chart-id" phx-hook="Chart" phx-update="ignore" class="w-full h-96"></div>
 *
 * The server pushes chart options via:
 *   push_event(socket, "update-chart-my-chart-id", spec_map)
 *
 * Resizing: a ResizeObserver watches this.el so the chart reflows whenever its
 * container changes size (e.g. a splitter drag or parent layout shift), not
 * just on window resize.
 */
import * as echarts from "echarts";

const ChartHook = {
  mounted() {
    this.chart = echarts.init(this.el);

    this._resizeObserver = new ResizeObserver(() => this.chart.resize());
    this._resizeObserver.observe(this.el);

    this.handleEvent("update-chart-" + this.el.id, (opts) => {
      // Pie chart: slice labels stay short (`name`); hover uses `readable_name` from the server
      // (Plaid snake_case → readable text). String tooltip formatters cannot be pushed from LV.
      if (this.el.id === "outflow-pie-chart") {
        const tooltipBase = opts.tooltip || {};
        const {formatter: _tpl, ...tooltipRest} = tooltipBase;
        opts = {
          ...opts,
          tooltip: {
            ...tooltipRest,
            trigger: "item",
            formatter: (params) => {
              const d = params.data || {};
              const label =
                d.readable_name != null && d.readable_name !== ""
                  ? d.readable_name
                  : params.name;
              const v = params.value;
              const pct = params.percent != null ? params.percent : "";
              return `${label}: $${v} (${pct}%)`;
            },
          },
        };
      }
      this.chart.setOption(opts);
    });
  },

  destroyed() {
    if (this._resizeObserver) {
      this._resizeObserver.disconnect();
      this._resizeObserver = null;
    }
    this.chart.dispose();
    this.chart = null;
  },
};

export default ChartHook;
