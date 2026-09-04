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

    // MARK: - Statuspage v2 service status

    /// Canonical Statuspage summary. The unrelated component is deliberately
    /// down while the page indicator is green so descriptor scoping is pinned.
    public static let statuspageSummaryOperational200 = #"""
    {
      "page": {
        "id": "page-claude",
        "name": "Claude",
        "url": "https://status.claude.com",
        "time_zone": "Etc/UTC",
        "updated_at": "2026-09-03T11:59:00.000Z"
      },
      "status": { "indicator": "none", "description": "All Systems Operational" },
      "components": [
        {
          "id": "k8w3r06qmzrp",
          "name": "Claude API (api.anthropic.com)",
          "status": "operational",
          "created_at": "2023-07-11T17:53:10.880Z",
          "updated_at": "2026-09-03T11:58:00.000Z",
          "position": 3,
          "description": null,
          "group_id": null
        },
        {
          "id": "yyzkbfz2thpt",
          "name": "Claude Code",
          "status": "operational",
          "created_at": "2025-05-22T21:35:29.822Z",
          "updated_at": "2026-09-03T11:57:00.000Z",
          "position": 4,
          "description": "Command-line and IDE clients",
          "group_id": null
        },
        {
          "id": "unrelated-component",
          "name": "Unrelated product",
          "status": "major_outage",
          "created_at": "2025-01-01T00:00:00Z",
          "updated_at": "2026-09-03T11:56:00Z",
          "position": 99,
          "description": null,
          "group_id": null
        }
      ],
      "incidents": [],
      "scheduled_maintenances": []
    }
    """#

    public static let statuspageSummaryDegraded200 = #"""
    {
      "page": { "id": "page-claude", "name": "Claude", "url": "https://status.claude.com",
                "updated_at": "2026-09-03T11:59:00Z" },
      "status": { "indicator": "minor", "description": "Minor Service Outage" },
      "components": [
        { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "degraded_performance",
          "updated_at": "2026-09-03T11:58:00Z" }
      ]
    }
    """#

    public static let statuspageSummaryPartialOutage200 = #"""
    {
      "page": { "id": "page-claude", "name": "Claude", "url": "https://status.claude.com",
                "updated_at": "2026-09-03T11:59:00Z" },
      "status": { "indicator": "major", "description": "Partial System Outage" },
      "components": [
        { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "partial_outage",
          "updated_at": "2026-09-03T11:58:00Z" }
      ]
    }
    """#

    public static let statuspageSummaryMajorOutage200 = #"""
    {
      "page": { "id": "page-claude", "name": "Claude", "url": "https://status.claude.com",
                "updated_at": "2026-09-03T11:59:00Z" },
      "status": { "indicator": "critical", "description": "Major System Outage" },
      "components": [
        { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "major_outage",
          "updated_at": "2026-09-03T11:58:00Z" }
      ]
    }
    """#

    public static let statuspageSummaryMaintenance200 = #"""
    {
      "page": { "id": "page-claude", "name": "Claude", "url": "https://status.claude.com",
                "updated_at": "2026-09-03T11:59:00Z" },
      "status": { "indicator": "maintenance", "description": "Service Under Maintenance" },
      "components": [
        { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "under_maintenance",
          "updated_at": "2026-09-03T11:58:00Z" }
      ]
    }
    """#

    /// Unknown indicator and component tokens must decode successfully and
    /// map to the honest domain-level `unknown` state.
    public static let statuspageSummaryUnknown200 = #"""
    {
      "page": { "id": "page-claude", "name": "Claude", "url": "https://status.claude.com",
                "updated_at": "2026-09-03T11:59:00Z" },
      "status": { "indicator": "new_upstream_state", "description": "New state" },
      "components": [
        { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "brand_new_state",
          "updated_at": "2026-09-03T11:58:00Z" }
      ]
    }
    """#

    /// At `2026-09-03T12:00:00Z`: active/global/long incidents intersect the
    /// six-hour window; `inc-old` ends one minute before it and `inc-future`
    /// starts one hour after now. `inc-other` is explicitly scoped away.
    public static let statuspageIncidentsWindow200 = #"""
    {
      "page": {
        "id": "page-claude",
        "name": "Claude",
        "url": "https://status.claude.com",
        "time_zone": "Etc/UTC",
        "updated_at": "2026-09-03T11:59:30Z"
      },
      "incidents": [
        {
          "id": "inc-active",
          "name": "Elevated API errors",
          "status": "monitoring",
          "impact": "minor",
          "created_at": "2026-09-03T10:00:00Z",
          "updated_at": "2026-09-03T11:50:00Z",
          "started_at": "2026-09-03T10:00:00Z",
          "resolved_at": null,
          "shortlink": "https://status.claude.com/incidents/inc-active",
          "components": [
            { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "degraded_performance",
              "updated_at": "2026-09-03T11:50:00Z" },
            { "id": "yyzkbfz2thpt", "name": "Claude Code", "status": "degraded_performance",
              "updated_at": "2026-09-03T11:50:00Z" }
          ],
          "incident_updates": [
            {
              "id": "update-active",
              "status": "monitoring",
              "body": "A fix is deployed and recovery is being monitored.",
              "incident_id": "inc-active",
              "created_at": "2026-09-03T11:50:00Z",
              "updated_at": "2026-09-03T11:50:00Z",
              "display_at": "2026-09-03T11:50:00Z",
              "affected_components": [
                { "code": "k8w3r06qmzrp", "name": "Claude API",
                  "old_status": "partial_outage", "new_status": "degraded_performance" },
                { "code": "yyzkbfz2thpt", "name": "Claude Code",
                  "old_status": "partial_outage", "new_status": "degraded_performance" }
              ]
            }
          ]
        },
        {
          "id": "inc-long",
          "name": "Long-running issue",
          "status": "resolved",
          "impact": "major",
          "created_at": "2026-09-03T02:00:00Z",
          "updated_at": "2026-09-03T10:05:00Z",
          "started_at": "2026-09-03T02:00:00Z",
          "resolved_at": "2026-09-03T10:00:00Z",
          "shortlink": "https://status.claude.com/incidents/inc-long",
          "components": [
            { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "operational",
              "updated_at": "2026-09-03T10:00:00Z" }
          ],
          "incident_updates": []
        },
        {
          "id": "inc-global",
          "name": "Page-wide incident without component IDs",
          "status": "resolved",
          "impact": "critical",
          "created_at": "2026-09-03T10:30:00Z",
          "updated_at": "2026-09-03T11:20:00Z",
          "started_at": "2026-09-03T10:30:00Z",
          "resolved_at": "2026-09-03T11:00:00Z",
          "shortlink": "https://status.claude.com/incidents/inc-global",
          "incident_updates": []
        },
        {
          "id": "inc-old",
          "name": "Old incident",
          "status": "resolved",
          "impact": "minor",
          "created_at": "2026-09-02T23:00:00Z",
          "updated_at": "2026-09-03T05:59:00Z",
          "started_at": "2026-09-02T23:00:00Z",
          "resolved_at": "2026-09-03T05:59:00Z",
          "incident_updates": []
        },
        {
          "id": "inc-future",
          "name": "Future incident",
          "status": "scheduled",
          "impact": "maintenance",
          "created_at": "2026-09-03T11:00:00Z",
          "updated_at": "2026-09-03T11:10:00Z",
          "started_at": "2026-09-03T13:00:00Z",
          "resolved_at": null,
          "incident_updates": []
        },
        {
          "id": "inc-other",
          "name": "Unrelated component incident",
          "status": "investigating",
          "impact": "critical",
          "created_at": "2026-09-03T11:00:00Z",
          "updated_at": "2026-09-03T11:55:00Z",
          "started_at": "2026-09-03T11:00:00Z",
          "resolved_at": null,
          "components": [
            { "id": "unrelated-component", "name": "Unrelated product", "status": "major_outage",
              "updated_at": "2026-09-03T11:55:00Z" }
          ],
          "incident_updates": []
        }
      ]
    }
    """#

    public static let statuspageMaintenancesWindow200 = #"""
    {
      "page": {
        "id": "page-claude",
        "name": "Claude",
        "url": "https://status.claude.com",
        "updated_at": "2026-09-03T11:59:40Z"
      },
      "scheduled_maintenances": [
        {
          "id": "maint-active",
          "name": "API database maintenance",
          "status": "in_progress",
          "impact": "maintenance",
          "created_at": "2026-09-03T08:30:00Z",
          "updated_at": "2026-09-03T11:40:00Z",
          "started_at": "2026-09-03T09:00:00Z",
          "resolved_at": null,
          "shortlink": "https://attacker.example/redirect",
          "scheduled_for": "2026-09-03T09:00:00Z",
          "scheduled_until": "2026-09-03T13:00:00Z",
          "components": [
            { "id": "k8w3r06qmzrp", "name": "Claude API", "status": "under_maintenance",
              "updated_at": "2026-09-03T11:40:00Z" }
          ],
          "incident_updates": [
            {
              "id": "update-maint",
              "status": "in_progress",
              "body": "Maintenance is in progress.",
              "incident_id": "maint-active",
              "created_at": "2026-09-03T11:40:00Z",
              "updated_at": "2026-09-03T11:40:00Z",
              "display_at": "2026-09-03T11:40:00Z",
              "affected_components": [
                { "code": "k8w3r06qmzrp", "name": "Claude API",
                  "old_status": "operational", "new_status": "under_maintenance" }
              ]
            }
          ]
        }
      ]
    }
    """#

    public static let statuspageIncidentUnknownTokens200 = #"""
    {
      "incidents": [
        {
          "id": "inc-unknown",
          "name": "New upstream states",
          "status": "new_phase",
          "impact": "novel_impact",
          "created_at": "2026-09-03T11:00:00Z",
          "updated_at": "2026-09-03T11:30:00Z",
          "started_at": "2026-09-03T11:00:00Z",
          "resolved_at": null,
          "incident_updates": []
        }
      ]
    }
    """#

    // MARK: - DeepSeek FlashDuty service status

    /// Canonical active-summary payload from DeepSeek's official FlashDuty
    /// status page. The active change pins explicit partial-outage state.
    public static let deepseekStatusActive200 = #"""
    {
      "request_id": "request-active",
      "data": {
        "page": {
          "page_id": 6410630422455,
          "name": "DeepSeek",
          "url_name": "deepseek",
          "type": "public",
          "custom_domain": "status.deepseek.com",
          "logo": "https://static.flashcat.cloud/deepseek-logo.png",
          "logo_url": "https://www.deepseek.com/",
          "date_view": "calendar",
          "display_uptime_mode": "chart_and_percentage",
          "components": [
            {
              "component_id": "api-service",
              "name": "API Service",
              "description": "DeepSeek API availability",
              "available_since_seconds": 1706745600,
              "order_id": 1
            },
            {
              "component_id": "chat-service",
              "section_id": "chat-section",
              "name": "Chat Service",
              "available_since_seconds": 1706745600,
              "order_id": 2
            }
          ],
          "sections": [
            {
              "section_id": "chat-section",
              "name": "Chat",
              "description": "DeepSeek chat availability",
              "order_id": 1,
              "hide_uptime": false,
              "hide_all": false
            }
          ]
        },
        "active_changes": [
          {
            "change_id": 7001,
            "page_id": 6410630422455,
            "type": "incident",
            "title": "API partially unavailable",
            "description": "We are monitoring recovery.",
            "status": "monitoring",
            "affected_components": [
              {
                "component_id": "api-service",
                "name": "API Service",
                "description": "DeepSeek API availability",
                "available_since_seconds": 1706745600,
                "order_id": 1,
                "status": "partial_outage"
              }
            ],
            "start_at_seconds": 1788433200,
            "updates": [
              {
                "update_id": "update-identified",
                "at_seconds": 1788433200,
                "status": "identified",
                "description": "The cause has been identified.",
                "component_changes": [
                  {
                    "component_id": "api-service",
                    "component_name": "API Service",
                    "status": "partial_outage"
                  }
                ]
              },
              {
                "update_id": "update-monitoring",
                "at_seconds": 1788436200,
                "status": "monitoring",
                "description": "A fix is deployed; monitoring recovery.",
                "component_changes": [
                  {
                    "component_id": "api-service",
                    "component_name": "API Service",
                    "status": "partial_outage"
                  }
                ]
              }
            ],
            "notify_subscribers": true
          }
        ]
      }
    }
    """#

    /// Canonical six-hour structure response, including impact, uptime, and
    /// linked-change records from every new structure wire type.
    public static let deepseekStatusStructure200 = #"""
    {
      "request_id": "request-structure",
      "data": {
        "section_impacts": [
          {
            "section_id": "chat-section",
            "change_id": 7001,
            "start_at_seconds": 1788433200,
            "end_at_seconds": 1788436800,
            "status": "partial_outage"
          }
        ],
        "section_uptimes": [
          {
            "section_id": "chat-section",
            "uptime": 95.5,
            "available_since_seconds": 1788415200
          }
        ],
        "component_impacts": [
          {
            "component_id": "api-service",
            "section_id": "",
            "change_id": 7001,
            "start_at_seconds": 1788433200,
            "end_at_seconds": 1788436800,
            "status": "partial_outage"
          }
        ],
        "component_uptimes": [
          {
            "component_id": "api-service",
            "section_id": "",
            "uptime": 94.25,
            "available_since_seconds": 1706745600
          }
        ],
        "linked_changes": [
          { "id": 7001, "type": "incident", "title": "API partially unavailable" }
        ]
      }
    }
    """#

    /// Canonical change-list response. At 2026-09-03T12:00:00Z the active
    /// and long-running incidents intersect the window; old/future do not.
    public static let deepseekStatusChanges200 = #"""
    {
      "request_id": "request-changes",
      "data": {
        "items": [
          {
            "change_id": 7001,
            "page_id": 6410630422455,
            "type": "incident",
            "title": "API partially unavailable",
            "description": "We are monitoring recovery.",
            "status": "monitoring",
            "affected_components": [
              {
                "component_id": "api-service",
                "name": "API Service",
                "available_since_seconds": 1706745600,
                "order_id": 1,
                "status": "partial_outage"
              }
            ],
            "start_at_seconds": 1788433200,
            "updates": [
              {
                "update_id": "update-monitoring-newer",
                "at_seconds": 1788435900,
                "status": "monitoring",
                "description": "Recovery continues.",
                "component_changes": [
                  {
                    "component_id": "api-service",
                    "component_name": "API Service",
                    "status": "partial_outage"
                  }
                ]
              }
            ],
            "notify_subscribers": true
          },
          {
            "change_id": 7002,
            "page_id": 6410630422455,
            "type": "incident",
            "title": "Long-running API outage",
            "description": "Service restored.",
            "status": "resolved",
            "affected_components": [
              {
                "component_id": "api-service",
                "name": "API Service",
                "available_since_seconds": 1706745600,
                "order_id": 1,
                "status": "operational"
              }
            ],
            "start_at_seconds": 1788400800,
            "close_at_seconds": 1788429600,
            "updates": [
              {
                "update_id": "update-outage",
                "at_seconds": 1788400800,
                "status": "investigating",
                "description": "API requests are failing.",
                "component_changes": [
                  {
                    "component_id": "api-service",
                    "component_name": "API Service",
                    "status": "full_outage"
                  }
                ]
              },
              {
                "update_id": "update-resolved",
                "at_seconds": 1788429600,
                "status": "resolved",
                "description": "Service restored.",
                "component_changes": [
                  {
                    "component_id": "api-service",
                    "component_name": "API Service",
                    "status": "operational"
                  }
                ]
              }
            ],
            "notify_subscribers": true
          },
          {
            "change_id": 7003,
            "page_id": 6410630422455,
            "type": "maintenance",
            "title": "Old maintenance",
            "description": "Completed before the window.",
            "status": "completed",
            "affected_components": [],
            "start_at_seconds": 1788400800,
            "close_at_seconds": 1788415140,
            "updates": [],
            "notify_subscribers": false
          },
          {
            "change_id": 7004,
            "page_id": 6410630422455,
            "type": "incident",
            "title": "Future incident",
            "description": "Not started.",
            "status": "scheduled",
            "affected_components": [],
            "start_at_seconds": 1788440400,
            "updates": [],
            "notify_subscribers": false
          }
        ]
      }
    }
    """#

    // MARK: - RSS service status

    /// Canonical OpenRouter incident feed with HTML, a duplicate title/start
    /// pair, long/old/future incidents, and a hostile incident URL.
    public static let openRouterStatusRSS200 = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>OpenRouter Status - Incident History</title>
        <link>status.openrouter.ai</link>
        <description>Statuspage</description>
        <lastBuildDate>Thu, 03 Sep 2026 11:55:00 GMT</lastBuildDate>
        <item>
          <title>API &amp; routing degraded</title>
          <description><![CDATA[<p><small>Sep 3, 11:30 AM UTC</small><br/><strong>MONITORING</strong> - <p>A fix &amp;amp; recovery are being monitored.</p></p>]]></description>
          <pubDate>Thu, 03 Sep 2026 11:00:00 GMT</pubDate>
          <link>status.openrouter.ai/incidents/incident-active</link>
          <guid isPermaLink="true">status.openrouter.ai/incidents/incident-active</guid>
          <category>degraded_performance</category>
          <category>monitoring</category>
        </item>
        <item>
          <title>API &amp; routing degraded</title>
          <description><![CDATA[<p><small>Sep 3, 11:45 AM UTC</small><br/><strong>MONITORING</strong> - <p>Newer duplicate update.</p></p>]]></description>
          <pubDate>Thu, 03 Sep 2026 11:00:00 GMT</pubDate>
          <link>https://status.openrouter.ai/incidents/incident-active-duplicate</link>
          <guid isPermaLink="true">duplicate-guid</guid>
          <category>degraded_performance</category>
          <category>monitoring</category>
        </item>
        <item>
          <title>Long outage</title>
          <description><![CDATA[<p><small>Sep 3, 10:00 AM UTC</small><br/><strong>RESOLVED</strong> - Service restored.</p>]]></description>
          <pubDate>Thu, 03 Sep 2026 02:00:00 GMT</pubDate>
          <link>https://status.openrouter.ai/incidents/incident-long</link>
          <guid isPermaLink="true">incident-long</guid>
          <category>major_outage</category>
          <category>resolved</category>
        </item>
        <item>
          <title>Old incident</title>
          <description><![CDATA[<p><small>Sep 3, 5:59 AM UTC</small><br/><strong>RESOLVED</strong> - Old.</p>]]></description>
          <pubDate>Thu, 03 Sep 2026 00:00:00 GMT</pubDate>
          <guid isPermaLink="false">incident-old</guid>
          <category>minor</category>
          <category>resolved</category>
        </item>
        <item>
          <title>Future incident</title>
          <description><![CDATA[<strong>INVESTIGATING</strong> - Future.]]></description>
          <pubDate>Thu, 03 Sep 2026 13:00:00 GMT</pubDate>
          <guid isPermaLink="false">incident-future</guid>
          <category>minor</category>
          <category>investigating</category>
        </item>
        <item>
          <title>Hostile link outage</title>
          <description><![CDATA[<strong>IDENTIFIED</strong> - Link must be removed.]]></description>
          <pubDate>Thu, 03 Sep 2026 11:20:00 GMT</pubDate>
          <link>https://attacker.example/steal</link>
          <guid isPermaLink="false">incident-hostile</guid>
          <category>partial_outage</category>
          <category>identified</category>
        </item>
      </channel>
    </rss>
    """#

    /// Canonical xAI RSS feed pins explicit resolved timestamps and categories.
    public static let xaiStatusRSS200 = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>xAI System Status</title>
        <link>https://status.x.ai</link>
        <description>Current status and incident history</description>
        <atom:link href="https://status.x.ai/feed.xml" rel="self" type="application/rss+xml" />
        <lastBuildDate>Thu, 03 Sep 2026 11:58:00 GMT</lastBuildDate>
        <item>
          <title>[API] Models outage</title>
          <link>https://status.x.ai/api-us-east-1/INCactive</link>
          <guid isPermaLink="false">INCactive</guid>
          <description><![CDATA[
            <h3>Status: INVESTIGATING</h3>
            <p>Severity: major_outage</p>
            <p><strong>Thu, 03 Sep 2026 11:40:00 GMT</strong></p>
            <p>We are investigating elevated errors.</p>
          ]]></description>
          <pubDate>Thu, 03 Sep 2026 11:00:00 GMT</pubDate>
          <category>major_outage</category>
          <category>investigating</category>
        </item>
        <item>
          <title>[API] Elevated latency</title>
          <link>https://status.x.ai/api-us-west-2/INCresolved</link>
          <guid isPermaLink="false">INCresolved</guid>
          <description><![CDATA[
            <h3>Status: RESOLVED</h3>
            <p>Severity: available</p>
            <p>Resolved: Thu, 03 Sep 2026 10:30:00 GMT</p>
            <p>Traffic is healthy again.</p>
          ]]></description>
          <pubDate>Thu, 03 Sep 2026 09:30:00 GMT</pubDate>
          <category>available</category>
          <category>resolved</category>
        </item>
      </channel>
    </rss>
    """#

    public static func data(_ s: String) -> Data { Data(s.utf8) }
}
