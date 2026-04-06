import "phoenix_html";
import {Socket} from "phoenix";
import {LiveSocket} from "phoenix_live_view";
import PlaidLink from "./hooks/plaid_link";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PlaidLink},
});

liveSocket.connect();
window.liveSocket = liveSocket;
