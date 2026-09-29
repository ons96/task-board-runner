#!/usr/bin/env python3
"""Validate free, temporary provider entries without exposing credential values."""

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def load_manifest(path, now=None):
    data = json.loads(Path(path).read_text())
    if data.get("schema_version") != 1 or not isinstance(data.get("providers"), list):
        raise ValueError("invalid manifest schema")
    now = now or datetime.now(timezone.utc)
    seen = set()
    active = []
    rejected = []
    for item in data["providers"]:
        required = {"id", "model", "base_url", "credential_env", "expires_at", "fallback_position", "free_tier"}
        if not isinstance(item, dict) or not required <= item.keys():
            raise ValueError("provider entry missing required fields")
        if not isinstance(item["id"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", item["id"]) or item["id"] in seen:
            raise ValueError("invalid or duplicate provider id")
        seen.add(item["id"])
        if not isinstance(item["free_tier"], bool):
            raise ValueError(f"{item['id']}: free_tier must be boolean")
        if type(item["fallback_position"]) is not int or item["fallback_position"] < 0:
            raise ValueError(f"{item['id']}: invalid fallback position")
        if not isinstance(item["base_url"], str) or not item["base_url"].startswith("https://") or not isinstance(item["model"], str) or not item["model"]:
            raise ValueError(f"{item['id']}: invalid endpoint or model")
        if not isinstance(item["credential_env"], str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", item["credential_env"]):
            raise ValueError(f"{item['id']}: invalid credential env name")
        if not isinstance(item["expires_at"], str):
            raise ValueError(f"{item['id']}: invalid expiry")
        try:
            expires = datetime.fromisoformat(item["expires_at"].replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError(f"{item['id']}: invalid expiry") from error
        if expires.tzinfo is None:
            raise ValueError(f"{item['id']}: expiry must include timezone")
        if expires <= now:
            rejected.append((item["id"], "expired"))
            continue
        if not os.environ.get(item["credential_env"]):
            rejected.append((item["id"], "credential_missing"))
            continue
        if not item["free_tier"]:
            rejected.append((item["id"], "not_free"))
            continue
        active.append(item)
    return sorted(active, key=lambda item: item["fallback_position"]), rejected


def build_config(config_path, manifest_path):
    config = json.loads(Path(config_path).read_text())
    providers, _ = load_manifest(manifest_path)
    optional_models = []
    for item in providers:
        provider_id = item["id"]
        config["provider"][provider_id] = {
            "options": {"baseURL": item["base_url"], "apiKey": "{env:" + item["credential_env"] + "}"},
            "models": {item["model"].split("/", 1)[-1]: {"name": item["model"]}},
        }
        optional_models.append(provider_id + "/" + item["model"].split("/", 1)[-1])
    return config, optional_models


def self_test():
    import tempfile

    now = datetime(2030, 1, 1, tzinfo=timezone.utc)
    valid = {"schema_version": 1, "providers": [{
        "id": "temp", "model": "vendor/model", "base_url": "https://api.example.test/v1",
        "credential_env": "TEMP_KEY", "expires_at": "2030-01-02T00:00:00Z",
        "fallback_position": 1, "free_tier": True,
    }]}
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "manifest.json"
        path.write_text(json.dumps(valid))
        os.environ["TEMP_KEY"] = "test-only"
        providers, rejected = load_manifest(path, now)
        assert [p["id"] for p in providers] == ["temp"] and rejected == []
        valid["providers"][0]["expires_at"] = "not-a-date"
        path.write_text(json.dumps(valid))
        try:
            load_manifest(path, now)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid expiry accepted")
        valid["providers"][0]["expires_at"] = "2029-12-31T00:00:00Z"
        path.write_text(json.dumps(valid))
        providers, rejected = load_manifest(path, now)
        assert providers == [] and rejected == [("temp", "expired")]
        valid["providers"][0]["free_tier"] = False
        valid["providers"][0]["expires_at"] = "2030-01-02T00:00:00Z"
        path.write_text(json.dumps(valid))
        providers, rejected = load_manifest(path, now)
        assert providers == [] and rejected == [("temp", "not_free")]
        del os.environ["TEMP_KEY"]
        valid["providers"][0]["free_tier"] = True
        valid["providers"][0]["expires_at"] = "2030-01-02T00:00:00Z"
        path.write_text(json.dumps(valid))
        providers, rejected = load_manifest(path, now)
        assert providers == [] and rejected == [("temp", "credential_missing")]
        valid["providers"][0]["free_tier"] = True
        valid["providers"][0]["expires_at"] = "2030-01-02T00:00:00Z"
        valid["providers"][0]["base_url"] = "http://insecure.example.test"
        path.write_text(json.dumps(valid))
        try:
            load_manifest(path, now)
        except ValueError:
            pass
        else:
            raise AssertionError("insecure endpoint accepted")
        config = {"provider": {}}
        config_path = Path(directory) / "config.json"
        config_path.write_text(json.dumps(config))
        valid["providers"][0]["expires_at"] = "2030-01-02T00:00:00Z"
        os.environ["TEMP_KEY"] = "test-only"
        valid["providers"][0]["base_url"] = "https://api.example.test/v1"
        path.write_text(json.dumps(valid))
        os.environ["TEMP_KEY"] = "test-only"
        cfg, optional_models = build_config(config_path, path)
        assert cfg["provider"]["temp"]["options"]["apiKey"] == "{env:TEMP_KEY}"
        assert optional_models == ["temp/model"]
        config["provider"]["temp"] = {"options": {"baseURL": "https://old"}}
        config_path.write_text(json.dumps(config))
        merged, _ = build_config(config_path, path)
        assert merged["provider"]["temp"]["options"]["baseURL"] == "https://api.example.test/v1"
        print("provider manifest self-test: PASS (active, expired, paid, missing-key, config merge)")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif sys.argv[1:2] == ["--opencode-config"] and len(sys.argv) >= 5 and sys.argv[3] == "--manifest" and "--quarantine" in sys.argv[5:]:
        manifest = json.loads(Path(sys.argv[4]).read_text())
        _, rejected = load_manifest(sys.argv[4])
        providers = manifest.get("providers", [])
        by_id = {item.get("id"): item for item in providers if isinstance(item, dict)}
        for provider_id, reason in rejected:
            print(f"{provider_id} {reason}")
    elif sys.argv[1:2] == ["--opencode-config"] and len(sys.argv) >= 5 and sys.argv[3] == "--manifest":
        cfg, optional_models = build_config(sys.argv[2], sys.argv[4])
        if "--models" in sys.argv[5:]:
            if optional_models:
                print("\n".join(optional_models))
            raise SystemExit(0)
        print(json.dumps(cfg, separators=(",", ":")))
    else:
        providers, rejected = load_manifest(sys.argv[1] if len(sys.argv) > 1 else "provider-manifest.json")
        for provider in providers:
            print(f"{provider['id']} {provider['model']} {provider['base_url']} {provider['credential_env']} {provider['fallback_position']}")
        for provider_id, reason in rejected:
            print(f"{provider_id} {reason}")
