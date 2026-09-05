# Cursor

Tracks your Cursor plan usage using credentials from Cursor or Grok Bot.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Cursor Models | Usage percent for Cursor's own models, including Cursor Grok and Composer |
| Other Models | Usage percent for other models |
| Grok Bot | Grok Bot weekly usage percent and reset countdown; enabled by default |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Credits | Credit balance left from grants and prepaid account balance |

When Cursor reports your plan name, OpenUsage shows it beside the provider name.

Grok Bot has its own usage allowance, separate from Cursor's normal billing-cycle meter. Its widget
is enabled by default in Cursor's On Demand section. It uses your existing Cursor login, so signing
into the Grok CLI is not required.

## Where credentials come from

Sign in to Cursor or use Cursor through Grok Bot. OpenUsage first checks Cursor's local state database and Keychain entries. It keeps their existing selection order and saves refreshed tokens back to the selected Cursor source.

If those credentials are absent, OpenUsage reads the active Cursor account from Grok Bot. macOS may ask for access to the `Grok Bot Safe Storage` Keychain item. Choose **Always Allow** to permit background refreshes. This fallback is read-only. OpenUsage decrypts only the active account's access token. It never decrypts the Grok Bot refresh token or account profile, and it never changes Grok Bot's secrets file or Keychain item. OpenUsage reads the Grok Bot file again on every refresh.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. OpenUsage uses the exported token counts and shared model pricing to estimate the cost locally. Cursor's export may occasionally arrive late, so the newest figures can lag behind current activity. OpenUsage leaves isolated malformed rows out instead of silently counting broken values as zero. A failed download, invalid export schema, or broken CSV structure leaves spend history unavailable for that refresh. Each failure is recorded in the diagnostic log without including the exported usage data.

## Troubleshooting

- **"Not logged in" or token errors** — sign in to Cursor, or open Grok Bot and confirm that its active Cursor account works. Then refresh OpenUsage.
- **Grok Bot Keychain access required** — refresh manually and choose **Always Allow** in the macOS Keychain prompt.
- **Grok Bot login rejected** — open Grok Bot so it can renew the Cursor login, then refresh OpenUsage.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes owned Cursor credentials and retries once after a 401/403. OpenUsage does not refresh borrowed Grok Bot credentials. If Cursor rejects a borrowed token, OpenUsage asks you to open Grok Bot and refresh again. Optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses exported token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
