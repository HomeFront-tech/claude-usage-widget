"""Read OpenRouter key usage and spending caps."""
from typing import Optional

from usage_common import get_json, money

URL = "https://openrouter.ai/api/v1/key"
LABELS = {"daily": "Today", "weekly": "This week", "monthly": "This month"}
FIELDS = {"daily": "usage_daily", "weekly": "usage_weekly",
          "monthly": "usage_monthly"}


def normalize(data: dict, budget: Optional[float]) -> dict:
    credits = []
    facts = []
    cap = data.get("limit")
    period = data.get("limit_reset")
    if cap is not None:
        remaining = data.get("limit_remaining")
        if remaining is None:
            used = float(data.get(FIELDS.get(period, "usage")) or 0)
        else:
            used = float(cap) - float(remaining)
        used = round(used, 2)
        pct = max(0.0, min(100.0, used / float(cap) * 100)) if float(cap) else 0.0
        credits.append({"label": LABELS.get(period, "Spending cap"), "used": used,
                        "limit": cap, "pct": pct, "resets_at": None})
    elif budget is not None:
        used = round(float(data.get("usage_monthly") or 0), 2)
        pct = max(0.0, min(100.0, used / budget * 100)) if budget else 0.0
        credits.append({"label": "This month", "used": used, "limit": budget,
                        "pct": pct, "resets_at": None})
    else:
        parts = []
        if data.get("usage_daily") is not None:
            parts.append("Today " + money(float(data["usage_daily"])))
        if data.get("usage_monthly") is not None:
            parts.append("Month " + money(float(data["usage_monthly"])))
        if parts:
            facts.append(" · ".join(parts))
    if data.get("is_free_tier"):
        facts.append("Free tier")
    return {"ok": True, "plan": None, "limits": [], "credits": credits,
            "facts": facts}


def fetch(key: Optional[str], opts: dict) -> dict:
    data = get_json(URL, {"Authorization": "Bearer " + key},
                    {401: "Key not accepted",
                     402: "Out of credits or over the key's cap"})
    return normalize(data.get("data") or {}, opts.get("budget"))
