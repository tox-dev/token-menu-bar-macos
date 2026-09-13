# Provider data contracts

Internal implementation research for Token Menu Bar, September 7, 2026. Audience: app maintainers. Scope: close the 23
review findings and supported-provider information gaps without real-data tests or new background credential prompts.
All data transformation belongs in Core. Existing UI features stay reachable. No billing mutations are authorized.

## Findings that change implementation

Claude legacy spending uses minor units. Codex monthly allowances use credits, not dollars. Copilot's newer reset and
billing fields supersede legacy labels. Cursor's included pools cannot be combined by adding percentages. Gemini has
type-specific credit balances. Antigravity local quota access must not depend on cloud OAuth readiness.

Sources below are primary project implementations or official documentation. Private endpoint implementations establish
observed contracts, not vendor support guarantees. No account credentials or signed-in browser pages were accessed.

## Claim-to-source ledger

All sources accessed September 7 local / September 8 UTC, 2026. Repository commit dates are September 8 UTC unless
stated.

### Claude

- Legacy `used_credits` and `monthly_limit` contain minor units; `decimal_places` defaults to 2. Structured money uses
  `amount_minor` and its own exponent. High confidence, independently corroborated by two implementations.
  [oh-my-pi, can1357, daf07999, September 7](https://github.com/can1357/oh-my-pi/blob/daf07999c2fee9b22edc7bf8fea1fb6272e0df5e/packages/ai/src/usage/claude.ts#L393),
  [CodexBar, 2a71b479](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift#L1092).
- Read flat quota buckets alongside structured scoped limits. `is_active:false` does not prove a scoped limit is
  unenforceable.
  [CodexBar scoped quotas](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift#L1181).
- Anthropic's 50% weekly Claude Code boost ends September 13, 2026, at 11:59 PM Pacific. It does not change five-hour
  limits or establish a multiplier the app should apply to reported utilization. Eligibility excludes some Enterprise
  billing arrangements. Published plan information is not evidence of an account-specific API flag.
  [Anthropic promotion terms](https://support.claude.com/en/articles/15910845-claude-code-may-august-2026-weekly-limits-promotion).
- Fable has a separate allowance on eligible plans. Its 50% share is distinct from the temporary boost.
  [Anthropic Fable plan rules](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).
- Website enrichment uses a separately authenticated session: `/api/organizations`, organization `/usage`,
  `/overage_spend_limit`, `/prepaid/credits`, and `/api/account`. Overage fields include `monthly_credit_limit`,
  `used_credits`, `currency`, `is_enabled`; prepaid amounts use minor units. Account matching is required.
  [CodexBar web reader](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift#L1262).
- No inspected source establishes a monthly billing reset endpoint or an auto-reload object schema. Boolean false must
  stay false. A supplied reset date can be rendered; missing dates must remain unavailable. Auto-reload thresholds and
  purchase amounts exist in the product, but their payload contract remains unresolved.
  [Anthropic usage credits](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans),
  [CodexBar monthly cost mapping](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift#L1391).
- Existing repository fixtures contain null richer fields, including cap details and daily/weekly credit limits. Null
  proves presence, not the schema of a future non-null object. Preserve reasons, explicit scalar values, and source
  availability; do not invent nested DTOs from nulls.

### Gemini

- Quota buckets contain `remainingAmount`, `remainingFraction`, `resetTime`, `tokenType`, and `modelId`. Retain
  sublimits and their units; a missing fraction does not erase an absolute amount.
  [Google Gemini CLI quota types, 85aca163, September 4](https://github.com/google-gemini/gemini-cli/blob/85aca163f6c73ac6ce380b5447359146b8adcae4/packages/core/src/code_assist/types.ts#L250).
- Credit amounts use int64 strings and credit types. Google's billing reader filters `GOOGLE_ONE_AI`. Do not sum
  different types or paid/current copies of the same balance; preserve Decimal precision.
  [Google billing reader](https://github.com/google-gemini/gemini-cli/blob/85aca163f6c73ac6ce380b5447359146b8adcae4/packages/core/src/billing/billing.ts#L121).
- Balance refresh uses read-only `loadCodeAssist` with `mode:HEALTH_CHECK`. Separate its clock from cached plan
  metadata.
  [Google balance refresh](https://github.com/google-gemini/gemini-cli/blob/85aca163f6c73ac6ce380b5447359146b8adcae4/packages/core/src/code_assist/server.ts#L296).
- Google's May 19 announcement retires consumer Free/Pro/Ultra access June 18; Standard/Enterprise Code Assist and API
  keys differ. Current general CLI docs conflict with the dated announcement. Prefer observed service responses and the
  explicit transition policy; a paid eligible tier must outweigh an unrelated ineligible tier.
  [Google transition announcement](https://developers.googleblog.com/en/an-important-update-transitioning-gemini-cli-to-antigravity-cli/).

### Codex

- `spend_control.individual_limit` is a credit allowance. Preserve used/limit/remaining, source, and reset metadata.
  [OpenAI display, 98c7c041](https://github.com/openai/codex/blob/98c7c0415bf4af42fa291406c3ac730363741bc9/codex-rs/tui/src/status/rate_limits.rs#L328),
  [OpenAI spend schema](https://github.com/openai/codex/blob/98c7c0415bf4af42fa291406c3ac730363741bc9/codex-rs/codex-backend-openapi-models/src/models/spend_control_limit_details.rs).
- Additional rate limits may omit `rate_limit` or set it to null. Keep valid main limits when optional entries are
  absent or malformed. Preserve `metered_feature` and `normal_model_slug`.
  [OpenAI extra-limit schema](https://github.com/openai/codex/blob/98c7c0415bf4af42fa291406c3ac730363741bc9/codex-rs/codex-backend-openapi-models/src/models/additional_rate_limit_details.rs),
  [OpenAI client types](https://github.com/openai/codex/blob/98c7c0415bf4af42fa291406c3ac730363741bc9/codex-rs/backend-client/src/types.rs#L55).
- Reset credits include type, status, grant/expiry dates, title, and description. Upsell text differs from `promo`.
  Never reserve or consume credits while reading usage; do not send the Luna Reserve opt-in header.
  [OpenAI response types](https://github.com/openai/codex/blob/98c7c0415bf4af42fa291406c3ac730363741bc9/codex-rs/backend-client/src/types.rs#L23),
  [OpenAI read and mutation paths](https://github.com/openai/codex/blob/98c7c0415bf4af42fa291406c3ac730363741bc9/codex-rs/backend-client/src/client/rate_limit_resets.rs#L22).
- Workspace monthly usage has an optional account-scoped endpoint. Gate by workspace capability; cache and back off
  optional failures. Medium confidence, private implementation evidence.
  [CodexBar allowance DTO](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Codex/CodexSpendControlsMonthlyUsage.swift),
  [account-scoped URL](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift#L560).

### Cursor

- Usage summary includes `limitType`, model-selection messages, plan breakdown, absolute quantities, and team on-demand
  spending. Preserve those separate from compact percentages. High confidence from two implementations.
  [CodexBar summary model](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift#L230),
  [Cursor Usage Stats, fb35d1e3, July 25](https://github.com/numanaral/cursor-usage-stats/blob/fb35d1e3be0c07d427bc67fec0288813cadc66e9/src/types.ts).
- Included model pools have separate allowances. Do not add their percentages or derive a supplied aggregate from
  monetary totals. Membership is not a fixed model allowlist.
  [Cursor usage limits](https://prod.cursor.com/help/models-and-usage/usage-limits).
- Optional event history uses a paginated dashboard POST with dates and token/cost fields. Keep provider list-price cost
  distinct from charged cents. No stable event ID means equal-looking records are not proof of duplicates.
  [CodexBar Cursor event reader](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Cursor/CursorUsageEventsFetcher.swift).
- Legacy model-request quotas and the Grok Bot endpoint are separate optional capabilities. Normal editor sessions do
  not grant Admin API access.
  [legacy reader](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift#L1552),
  [Bot reader](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Cursor/CursorSandUsage.swift),
  [Cursor Admin API](https://docs.cursor.com/en/account/teams/admin-api).

### Copilot

- Reset precedence is category epoch seconds, then `quota_reset_date_utc`, `quota_reset_date`, and
  `limited_user_reset_date`. Preserve entitlement, remaining, overage allowance, billing mode, and credit precision.
  `has_quota:false` alone does not invalidate a finite token-billing category. Avoid summing overlapping categories.
  [Microsoft quota mapping, abb16775](https://github.com/microsoft/vscode/blob/abb16775f3ac861fdc281f8c1ef5d4e744f6c84a/src/vs/workbench/services/chat/common/chatEntitlementService.ts#L870).
- Map known plan SKUs to Pro, Pro+, Max, and education. Modern category snapshots replace equivalent legacy fields.
  Credit billing needs credit labels, not request labels.
  [Microsoft plan mapping](https://github.com/microsoft/vscode/blob/abb16775f3ac861fdc281f8c1ef5d4e744f6c84a/src/vs/workbench/services/chat/common/chatEntitlementService.ts#L1112),
  [GitHub billing semantics](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals).
- Detailed billing analytics requires Plan-read or organization Administration-read permission. An editor token is not
  proof of either. Browser budget access is a separate account-matched credential surface.
  [GitHub billing usage API](https://docs.github.com/en/rest/billing/usage),
  [CodexBar browser budget reader](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Copilot/CopilotBudgetWebFetcher.swift#L325).

### Antigravity

- Prefer bounded local app/CLI discovery over OAuth. App and CLI can provide grouped weekly/session quotas that cloud
  OAuth does not expose. IDE sources can have different endpoints. Match account identity when selecting a source.
  [CodexBar source notes](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/docs/antigravity.md).
- Summary supports root, `response`, or `summary` envelopes; validate RPC codes, including string forms. Fractions may
  be direct, `remaining.remainingFraction`, or the oneof representation. Missing fraction is unknown, not exhausted.
  Preserve bucket descriptions when no exact reset timestamp exists.
  [CodexBar quota parser](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Antigravity/AntigravityQuotaSummaryParser.swift),
  [response models](https://github.com/steipete/CodexBar/blob/2a71b479a5d410fd055ded73fc1046989f1d1218/Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe%2BResponseModels.swift).
- Official CLI documentation describes quota and credit views, but does not publish a stable complete localhost schema.
  [Google quota command](https://www.antigravity.google/docs/cli/commands/usage),
  [Google credit documentation](https://www.antigravity.google/docs/cli/credits/).

## Research limits and stopping decision

Two bounded research lanes covered Claude/Gemini and Codex/Cursor/Copilot. The coordinating agent read Antigravity
sources, reconciled findings against local DTOs, and spot-checked monetary conversions and official quota schemas.
Searches targeted current official product rules, generated schemas, first-party consumers, and pinned independent
readers. Broad discovery stopped after those sources established the implementation contracts or identified an explicit
credential/schema limitation. Auto-reload object details, account-specific Claude promotion payloads, and billing reset
endpoints remain unresolved. These fields must not acquire invented values or undocumented access side effects.
