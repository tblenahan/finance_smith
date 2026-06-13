/**
 * PlaidLink hook — opens Plaid Link via two code paths:
 *
 * 1. **Data-attribute auto-open (OAuth callback):**
 *    The hook element carries `data-link-token` and `data-received-redirect-uri`.
 *    On mount, Plaid Link is created and immediately opened so Plaid can complete
 *    the OAuth handshake.
 *
 * 2. **Push-event open (Dashboard / inline):**
 *    The server pushes an "open_plaid_link" event with `{link_token}`. The hook
 *    creates Plaid Link on demand and opens it. `receivedRedirectUri` is null
 *    because inline flows don't carry OAuth state.
 *
 * Events pushed to the LiveView:
 *   "plaid_link_success" — %{public_token, institution_name}
 *   "plaid_link_error"   — enriched, token-safe Plaid diagnostics
 */
const PlaidLink = {
  mounted() {
    this.handleEvent("open_plaid_link", ({ link_token }) => {
      this._openLink(link_token, null);
    });

    const linkToken = this.el.dataset.linkToken;
    if (linkToken) {
      const receivedRedirectUri = this.el.dataset.receivedRedirectUri;
      this._openLink(linkToken, receivedRedirectUri);
    }
  },

  _openLink(linkToken, receivedRedirectUri) {
    if (this.handler) {
      this.handler.destroy();
      this.handler = null;
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
      onExit: (err, metadata) => {
        if (err) {
          const institution = metadata?.institution ?? {};

          this.pushEvent("plaid_link_error", {
            error_type: err.error_type ?? "UNKNOWN",
            error_code: err.error_code ?? "UNKNOWN",
            error_message: err.error_message ?? "",
            display_message: err.display_message ?? "",
            request_id: err.request_id ?? "",
            link_status: metadata?.status ?? "",
            institution_id: institution.institution_id ?? "",
            institution_name: institution.name ?? "",
            link_session_id: metadata?.link_session_id ?? "",
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
