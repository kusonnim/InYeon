"""Static HTTP/SQL representation check, not a migration or RLS execution test.

Run with the backend development environment (PyYAML is already installed):
  services/backend/.venv/Scripts/python.exe supabase/verify_contract.py
The intentionally small SQL reader supports this foundation migration's format.
Use a PostgreSQL parser and live pgTAP tests for SQL correctness.
"""
from pathlib import Path
import re

import yaml


ROOT = Path(__file__).resolve().parents[1]
SQL = (ROOT / "supabase/migrations/202611090001_foundation.sql").read_text(encoding="utf-8")
SCHEMAS = yaml.safe_load((ROOT / "contracts/openapi.yaml").read_text(encoding="utf-8"))["components"]["schemas"]
TABLES = dict(re.findall(r"create table public\.(\w+) \((.*?)\n\);", SQL, flags=re.S))


def check_properties(model, table, derived=(), aliases=None):
    aliases = aliases or {}
    columns = set(re.findall(r"^  (\w+)\s+(?:uuid|text|bigint|boolean|integer|timestamptz|jsonb)\b", TABLES[table], re.M))
    properties = SCHEMAS[model]["properties"]
    missing = {aliases.get(name, name) for name in properties if name not in derived} - columns
    assert not missing, f"{model} has HTTP properties missing in {table}: {missing}"
    for name, definition in properties.items():
        values = definition.get("enum")
        if not values:
            continue
        column = aliases.get(name, name)
        match = re.search(rf"\b{column}\s+in\s*\(([^)]*)\)", TABLES[table])
        assert match, f"{table}.{column} has no SQL enum constraint"
        sql_values = set(re.findall(r"'([^']*)'", match[1]))
        assert set(values) == sql_values, f"{model}.{name}: HTTP {values} differs from SQL {sql_values}"


def main():
    checks = [
        ("Content", "contents", ("asset_ids", "analysis", "recommendations", "notification")),
        ("Analysis", "analyses", ()),
        ("Recommendation", "recommendations", ()),
        ("NotificationState", "notification_states", ()),
        ("Preferences", "preferences", ()),
        ("FeedbackEvent", "feedback_events", ()),
        ("SyncEvent", "sync_events", ()),
        ("AssetUploadCreate", "content_assets", ()),
    ]
    for model, table, derived in checks:
        check_properties(model, table, derived)
    # Upload capabilities are ephemeral, not columns or public object URLs.
    check_properties("AssetComplete", "content_assets", aliases={"asset_id": "id"})
    for table, body in TABLES.items():
        assert re.search(r"^  user_id uuid", body, re.M), f"{table} has no explicit owner"
    print(f"HTTP/SQL field and enum mapping checks passed for {len(checks) + 1} models and {len(TABLES)} owned tables.")


if __name__ == "__main__":
    main()
