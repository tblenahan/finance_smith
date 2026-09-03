import "phoenix_html";
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";
import PlaidLink from "./hooks/plaid_link";
import ChartHook from "./hooks/chart";
import SplitterHook from "./hooks/splitter";
import BudgetDblClick from "./hooks/budget_dblclick";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PlaidLink, Chart: ChartHook, Splitter: SplitterHook, BudgetDblClick},
});

liveSocket.connect();
window.liveSocket = liveSocket;
