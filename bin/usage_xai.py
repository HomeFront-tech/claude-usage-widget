# Built from xAI's published docs; untested against a live account.
"""Read xAI prepaid balance and monthly spending."""
import re
from decimal import Decimal, InvalidOperation
from typing import Optional

from usage_common import Fail, get_json, money

BASE = "https://management-api.x.ai/v1/billing/teams/{team}/"
AUTH_ERRORS = {401: "Needs a Management key, not an API key",
               403: "Needs a Management key, not an API key"}


def cents(v) -> Optional[float]:
    if isinstance(v, dict):
        v = v.get("val")
    if isinstance(v, bool) or not isinstance(v, (str, int, float)):
        return None
    try:
        return float(Decimal(str(v)) / 100)
    except (InvalidOperation, ValueError):
        return None


def normalize(balance: dict, invoice: Optional[dict], limits: Optional[dict],
              budget: Optional[float]) -> dict:
    facts = []
    credits = []
    remaining = cents((balance.get("total") or {}))
    if remaining is not None:
        facts.append(money(-remaining) + " credits left")
    core = (invoice or {}).get("coreInvoice") or {}
    spent = cents(core.get("amountAfterVat"))
    if spent is None:
        spent = cents(core.get("amountBeforeVat"))
    spending = (limits or {}).get("spendingLimits") or {}
    cap = cents(spending.get("effectiveSl"))
    if cap is None or cap <= 0:
        cap = budget
    if spent is not None:
        if cap is not None and cap > 0:
            credits.append({"label": "This month", "used": round(spent, 2),
                            "limit": cap,
                            "pct": max(0.0, min(100.0, spent / cap * 100)),
                            "resets_at": None})
        else:
            facts.append("This month " + money(spent))
    return {"ok": True, "plan": None, "limits": [], "credits": credits,
            "facts": facts}


def fetch(key: Optional[str], opts: dict) -> dict:
    team = opts.get("team_id")
    if not isinstance(team, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", team):
        raise Fail("Add your team ID")
    base = BASE.format(team=team)
    headers = {"Authorization": "Bearer " + key}
    balance = get_json(base + "prepaid/balance", headers, AUTH_ERRORS)
    optional = []
    for endpoint in ("postpaid/invoice/preview", "postpaid/spending-limits"):
        try:
            optional.append(get_json(base + endpoint, headers, AUTH_ERRORS))
        except Fail as exc:
            if exc.error == AUTH_ERRORS[401]:
                raise
            optional.append(None)
    return normalize(balance, optional[0], optional[1], opts.get("budget"))
