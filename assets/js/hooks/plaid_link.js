/**
 * PlaidLink hook — re-initializes Plaid Link on the OAuth callback page.
 *
 * The hook element must carry two data attributes set server-side:
 *   data-link-token          — a fresh Plaid link_token for this user
 *   data-received-redirect-uri — the full current URL including oauth_state_id
 *
 * On mount, Plaid Link is created and immediately opened. Plaid detects the
 * receivedRedirectUri, completes the OAuth handshake automatically, and calls
 * either onSuccess or onExit.
 *
 * Events pushed to the LiveView:
 *   "plaid_link_success" — %{public_token, institution_name}
 *   "plaid_link_error"   — %{error_type, error_code, display_message}
 */
const PlaidLink = {
  mounted() {
    const linkToken = this.el.dataset.linkToken;
    const receivedRedirectUri = this.el.dataset.receivedRedirectUri;

    if (!linkToken) {
      console.error("[PlaidLink] Missing data-link-token attribute.");
      return;
    }

    if (typeof window.Plaid === "undefined") {
      console.error("[PlaidLink] Plaid Link SDK not loaded.");
      this.pushEvent("plaid_link_error", {
        error_type: "SDK_NOT_LOADED",
        error_code: "SDK_NOT_LOADED",
        display_message: "Plaid Link SDK failed to load.",
      });
      return;
    }

    const config = {
      token: linkToken,
      receivedRedirectUri: receivedRedirectUri,
      onSuccess: (public_token, metadata) => {
        this.pushEvent("plaid_link_success", {
          public_token: public_token,
          institution_name: metadata?.institution?.name ?? "",
        });
      },
      onExit: (err, _metadata) => {
        if (err) {
          this.pushEvent("plaid_link_error", {
            error_type: err.error_type ?? "UNKNOWN",
            error_code: err.error_code ?? "UNKNOWN",
            display_message: err.display_message ?? "",
          });
        }
      },
    };

    this.handler = window.Plaid.create(config);
    this.handler.open();
  },

  destroyed() {
    if (this.handler) {
      this.handler.destroy();
    }
  },
};

export default PlaidLink;
