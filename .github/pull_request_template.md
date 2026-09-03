## Summary

<!-- 2–4 sentences: what problem this solves, the architectural approach, and the user-visible or operator-visible outcome. Lead with intent, not a file list. -->

## Review findings addressed

<!-- Optional. Use when this PR incorporates code-review or hardening follow-ups. One bullet per finding: what was wrong, what changed. Omit the section if N/A. -->

## What's in the diff

### Domain / Ash resources
<!-- Resources, actions, calculations, aggregates, policies, code interfaces. Name modules and actions. -->

### Database & migrations
<!-- `mix ash.codegen` migrations and resource snapshots. Call out destructive or backfill-required changes. -->

### Ingestion / sync / workers
<!-- Plaid, Oban workers, processors, B2 paths. Omit if unchanged. -->

### Web & UI
<!-- LiveViews, Hybrid Approach: Petal for Core UI; custom HEEx + Tailwind for Domain UI. Omit if unchanged. -->

### Security & policies
<!-- Household isolation, `authorize?: false` sites, Cloak/token handling, IDOR fixes. Link AGENT_SECURITY.md when relevant. -->

### Tests
<!-- New or expanded suites and what behaviors they lock in. -->

### Docs
<!-- AGENT_SECURITY.md, SECURITY.md, README, REPO_README, runbooks. Omit if unchanged. -->

## Security checklist

- [ ] No hardcoded secrets, tokens, or credentials; new runtime secrets documented in `.env.example` and `SECURITY.md`
- [ ] Cloak / `access_token` handling unchanged or limited to documented load sites (`AGENT_SECURITY.md`)
- [ ] No sensitive values in `Logger` / `IO.inspect` / error payloads
- [ ] New `authorize?: false` only on non-user-facing paths and commented with reason
- [ ] Household (or actor) isolation enforced for new/changed resources; cross-tenant IDOR covered by policy tests where applicable
- [ ] `mix audit` considered for dependency changes

## Test plan

- [ ] `mix test` — <N> tests, 0 failures
- [ ] `mix format --check-formatted`
- [ ] `mix compile` (no new warnings)
- [ ] Focused suites (list paths) —
- [ ] Manual / ops steps (if any) —
