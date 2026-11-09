"""Validate the authoritative document and detect implementation drift.

Use --write only while preparing an explicitly reviewed contract change; never in CI.
"""
import argparse
import json
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate

from app.main import create_app
from app.config import Settings

ROOT = Path(__file__).resolve().parents[3]
CONTRACT = ROOT / "contracts" / "openapi.yaml"


def generated_contract():
    return create_app(Settings(mode="production"), seed=False).openapi()


def check():
    specification = yaml.safe_load(CONTRACT.read_text(encoding="utf-8"))
    validate(specification)
    if specification != generated_contract():
        raise AssertionError("OpenAPI implementation drift: update contract/models together under review")
    schemas = specification["components"]["schemas"]
    def fixture(name, schema, key=None):
        data = json.loads((ROOT / "contracts" / "examples" / name).read_text(encoding="utf-8"))
        if key:
            data = data[key]
        validator = Draft202012Validator({"$ref": f"#/components/schemas/{schema}",
                                         "components": {"schemas": schemas}}, format_checker=FormatChecker())
        validator.validate(data)
    fixture("catalog.json", "ContentPage")
    fixture("content-create.json", "ContentCreate")
    fixture("preferences.json", "Preferences")
    fixture("asset-upload-create.json", "AssetUploadCreate")
    fixture("version-conflict.json", "ErrorResponse")
    fixture("notification-dismissal.json", "NotificationEvent", "request")
    fixture("notification-dismissal.json", "NotificationResult", "response")
    fixture("notification-restoration.json", "NotificationRestore", "request")
    fixture("notification-restoration.json", "NotificationResult", "response")
    fixture("notification-restoration.json", "NotificationEvent", "late_dismissal")
    fixture("notification-restoration.json", "NotificationResult", "late_response")
    print("OpenAPI validation, runtime parity and 11 fixture payload checks passed.")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write:
        CONTRACT.parent.mkdir(parents=True, exist_ok=True)
        CONTRACT.write_text(yaml.safe_dump(generated_contract(), sort_keys=False, allow_unicode=True), encoding="utf-8")
    else:
        check()


if __name__ == "__main__":
    main()
