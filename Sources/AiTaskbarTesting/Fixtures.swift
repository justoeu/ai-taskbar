import Foundation

public enum Fixtures {
    public static let anthropicUsage200 = #"""
    {
      "five_hour": { "utilization": 47.2, "resets_at": "2026-05-27T22:00:00Z",
                     "used": 471, "limit": 1000 },
      "seven_day": { "utilization": 12.0, "resets_at": "2026-06-02T11:00:00Z" },
      "seven_day_opus": { "utilization": 0.0 },
      "limits": [
        { "kind": "session", "group": "session", "percent": 47, "severity": "normal",
          "resets_at": "2026-05-27T22:00:00Z", "scope": null, "is_active": false },
        { "kind": "weekly_all", "group": "weekly", "percent": 12, "severity": "normal",
          "resets_at": "2026-06-02T11:00:00Z", "scope": null, "is_active": false },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 88, "severity": "warning",
          "resets_at": "2026-06-02T11:00:00Z",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
          "is_active": true }
      ],
      "extra_usage": { "is_enabled": true, "monthly_limit": 2000, "used_credits": 245,
                       "utilization": 12.25, "currency": "USD", "decimal_places": 2 }
    }
    """#

    public static let openaiUsage200 = #"""
    {
      "user_id": "u_abc",
      "account_id": "acc_xyz",
      "email": "test@example.com",
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {
          "used_percent": 33.0,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 10800
        },
        "secondary_window": {
          "used_percent": 4.5,
          "limit_window_seconds": 604800
        }
      },
      "credits": {
        "balance": "$4.20",
        "has_credits": true,
        "unlimited": false,
        "approx_local_messages": [5, 10]
      }
    }
    """#

    public static let openrouterCredits200 = #"""
    { "data": { "total_credits": 10.00, "total_usage": 2.50 } }
    """#

    public static let openrouterKey200 = #"""
    { "data": { "label": "primary", "usage": 2.50, "limit": 10.00,
                "is_free_tier": false } }
    """#

    /// Free-tier: no `limit` field → branch that emits "balance unknown".
    public static let openrouterKeyFreeTier200 = #"""
    { "data": { "label": "free", "usage": 0.10, "is_free_tier": true } }
    """#

    public static let openrouterActivity200 = #"""
    { "data": [
      { "model": "openai/gpt-4.1",   "usage": 3.20, "requests": 12,
        "prompt_tokens": 8000,  "completion_tokens": 2000,  "reasoning_tokens": 0 },
      { "model": "anthropic/claude-sonnet-4.6", "usage": 2.10, "requests": 8,
        "prompt_tokens": 6000,  "completion_tokens": 1500,  "reasoning_tokens": 0 },
      { "model": "google/gemini-2.5-flash", "usage": 1.50, "requests": 5,
        "prompt_tokens": 4000,  "completion_tokens": 1000,  "reasoning_tokens": 0 }
    ] }
    """#

    public static let openrouterKeyWithPeriods200 = #"""
    { "data": { "label": "primary", "usage": 12.00, "limit": 50.00,
                "usage_daily": 2.50, "usage_weekly": 18.00, "usage_monthly": 45.00,
                "limit_remaining": 38.00, "limit_reset": "monthly",
                "is_free_tier": false } }
    """#

    /// OpenAI balance encoded as an Int (older format) — exercises the
    /// Int64 branch of OpenAICredits.balance decoding.
    public static let openaiUsageBalanceAsInt200 = #"""
    {
      "user_id": "u_int",
      "rate_limit": {
        "primary_window": { "used_percent": 20.0, "limit_window_seconds": 18000 }
      },
      "credits": { "balance": 7, "has_credits": true,
                   "approx_cloud_messages": [50, 75] }
    }
    """#

    public static let zaiUsage200 = #"""
    {
      "code": 200, "msg": "Operation successful", "success": true,
      "data": {
        "level": "lite",
        "limits": [
          { "type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 1000,
            "currentValue": 40, "remaining": 960, "percentage": 4,
            "nextResetTime": 1784333321994,
            "usageDetails": [
              { "modelCode": "search-prime", "usage": 20 },
              { "modelCode": "web-reader", "usage": 15 },
              { "modelCode": "zread", "usage": 5 }
            ] },
          { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 24,
            "nextResetTime": 1781759602799 },
          { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 16,
            "nextResetTime": 1782346121993 }
        ]
      }
    }
    """#

    public static let kimiBalance200 = #"""
    {
      "code": 0,
      "status": true,
      "scode": "0x0",
      "data": {
        "available_balance": 87.65,
        "voucher_balance": 30.00,
        "cash_balance": 57.65
      }
    }
    """#

    /// Older shape — only `balance` exposed, no available/voucher/cash split.
    public static let kimiBalanceLegacy200 = #"""
    { "code": 0, "status": true, "data": { "balance": 42.00 } }
    """#

    /// Wild shape: balance fields encoded as strings (observed in early
    /// Moonshot rollouts).
    public static let kimiBalanceStringNumbers200 = #"""
    {
      "code": 0,
      "data": {
        "available_balance": "21.50",
        "voucher_balance": "0.00",
        "cash_balance": "21.50"
      }
    }
    """#

    /// DeepSeek `/user/balance` — canonical shape. DeepSeek returns balance
    /// values as JSON **strings**. An account may carry both CNY and USD; we
    /// pick USD. Here both are present so the USD-preference branch is
    /// exercised (USD total 110 must win over the CNY 770 entry).
    public static let deepseekBalance200 = #"""
    {
      "is_available": true,
      "balance_infos": [
        { "currency": "CNY", "total_balance": "770.00", "granted_balance": "70.00", "topped_up_balance": "700.00" },
        { "currency": "USD", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00" }
      ]
    }
    """#

    /// DeepSeek with only a CNY entry — exercises the CNY fallback (no USD).
    public static let deepseekBalanceCNYOnly200 = #"""
    {
      "is_available": true,
      "balance_infos": [
        { "currency": "CNY", "total_balance": "500.00", "granted_balance": "0", "topped_up_balance": "500.00" }
      ]
    }
    """#

    /// DeepSeek with numeric (non-string) balance values — exercises the
    /// `flexibleDouble` int/float path of the decoder (real API sends strings,
    /// but we tolerate numbers defensively, matching the Kimi wire type).
    public static let deepseekBalanceNumbers200 = #"""
    {
      "is_available": true,
      "balance_infos": [
        { "currency": "USD", "total_balance": 42.5, "granted_balance": 2.5, "topped_up_balance": 40 }
      ]
    }
    """#

    /// DeepSeek when balance is insufficient (`is_available: false`) and no
    /// balance_infos at all — degenerate but must not crash.
    public static let deepseekBalanceInsufficient200 = #"""
    { "is_available": false }
    """#

    /// xAI prepaid balance — `total.val` is USD cents as a signed string
    /// (purchases are negative; spend is positive). $-45.00 remaining.
    public static let xaiPrepaidBalance200 = #"""
    {
      "changes": [],
      "total": { "val": "-4500" }
    }
    """#

    /// xAI invoice preview for the current billing cycle: $12.50 spent against
    /// a $200 soft limit, with $45 prepaid on file and $5 prepaid already used.
    public static let xaiInvoicePreview200 = #"""
    {
      "coreInvoice": {
        "lines": [],
        "amountAfterVat": "1250",
        "autoCreditsIssued": "0",
        "defaultCreditsIssued": "0",
        "prepaidCredits": { "val": "-4500" },
        "prepaidCreditsUsed": { "val": "500" }
      },
      "effectiveSpendingLimit": "20000",
      "defaultCredits": "0",
      "billingCycle": { "year": 2026, "month": 7 }
    }
    """#

    /// xAI invoice preview with zero spending limit (prepaid-only mode).
    public static let xaiInvoicePreviewPrepaidOnly200 = #"""
    {
      "coreInvoice": {
        "amountAfterVat": "0",
        "prepaidCredits": { "val": "-1000" },
        "prepaidCreditsUsed": { "val": "0" }
      },
      "effectiveSpendingLimit": "0",
      "billingCycle": { "year": 2026, "month": 7 }
    }
    """#

    /// Gemini `models.list` payload — heartbeat used as a stand-in for a
    /// quota signal (Google AI doesn't expose one publicly). Three sample
    /// models so the snapshot's modelCount has something to count.
    public static let geminiModels200 = #"""
    {
      "models": [
        {
          "name": "models/gemini-2.5-pro",
          "displayName": "Gemini 2.5 Pro",
          "supportedGenerationMethods": ["generateContent", "countTokens"]
        },
        {
          "name": "models/gemini-2.5-flash",
          "displayName": "Gemini 2.5 Flash",
          "supportedGenerationMethods": ["generateContent", "countTokens"]
        },
        {
          "name": "models/gemini-2.0-flash",
          "displayName": "Gemini 2.0 Flash",
          "supportedGenerationMethods": ["generateContent"]
        }
      ]
    }
    """#

    /// Empty model list — exercises the "no models visible" branch (still a
    /// valid 200, just an API key without access).
    public static let geminiModelsEmpty200 = #"""
    { "models": [] }
    """#

    /// Synthetic OAuth refresh response.
    public static let oauthRefresh200 = #"""
    { "access_token": "new.acc.tk", "refresh_token": "new.ref.tk", "expires_in": 28800 }
    """#

    public static func data(_ s: String) -> Data { Data(s.utf8) }
}
