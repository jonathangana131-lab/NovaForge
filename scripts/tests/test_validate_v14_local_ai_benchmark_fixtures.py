from __future__ import annotations

import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR_PATH = ROOT / "scripts" / "validate-v14-local-ai-benchmark-fixtures.py"
SPEC = importlib.util.spec_from_file_location("benchmark_validator", VALIDATOR_PATH)
assert SPEC and SPEC.loader
validator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = validator
SPEC.loader.exec_module(validator)
FIXTURES = ROOT / "Benchmarks" / "LocalAI" / "v1"


def canonical_write(path: pathlib.Path, value: dict) -> None:
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")


class FixturePackValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name) / "v1"
        shutil.copytree(FIXTURES, self.root)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def load_manifest(self) -> dict:
        return json.loads((self.root / "manifest.json").read_text(encoding="utf-8"))

    def test_canonical_pack_is_valid_and_stable(self) -> None:
        result = validator.validate(FIXTURES)
        self.assertEqual(result.suite_id, "novaforge.local-ai.general-agent")
        self.assertEqual(result.suite_version, 1)
        self.assertEqual(result.task_count, 8)
        self.assertEqual(len(result.task_digests), 8)
        self.assertEqual(result.corpus_sha256, "a4ee62068403cb15e077eb0556e6efd61a4cc18915a7383ac63f67aee12cd269")

    def test_tampered_fixture_fails_digest_binding(self) -> None:
        manifest = self.load_manifest()
        path = self.root / manifest["tasks"][0]["path"]
        fixture = json.loads(path.read_text(encoding="utf-8"))
        fixture["instructions"] += " tampered"
        canonical_write(path, fixture)
        with self.assertRaisesRegex(validator.ValidationError, "fixture SHA-256 mismatch"):
            validator.validate(self.root)

    def test_manifest_path_traversal_is_rejected(self) -> None:
        manifest = self.load_manifest()
        manifest["tasks"][0]["path"] = "../escape.json"
        canonical_write(self.root / "manifest.json", manifest)
        with self.assertRaisesRegex(validator.ValidationError, "path traversal"):
            validator.validate(self.root)

    def test_duplicate_json_key_is_rejected(self) -> None:
        path = self.root / "manifest.json"
        raw = path.read_text(encoding="utf-8").rstrip("\n")
        raw = raw[:-1] + ',"suite_id":"duplicate"}\n'
        path.write_text(raw, encoding="utf-8", newline="\n")
        with self.assertRaisesRegex(validator.ValidationError, "duplicate JSON key"):
            validator.validate(self.root)

    def test_fixture_identity_mismatch_is_rejected_even_after_rehash(self) -> None:
        manifest = self.load_manifest()
        task = manifest["tasks"][0]
        path = self.root / task["path"]
        fixture = json.loads(path.read_text(encoding="utf-8"))
        fixture["task_id"] = "wrong-id"
        canonical_write(path, fixture)
        task["fixture_sha256"] = validator.sha256(path.read_bytes())
        canonical_write(self.root / "manifest.json", manifest)
        with self.assertRaisesRegex(validator.ValidationError, "task_id mismatch"):
            validator.validate(self.root)

    def test_duplicate_workspace_path_is_rejected_even_after_rehash(self) -> None:
        manifest = self.load_manifest()
        task = next(item for item in manifest["tasks"] if item["category"] == "codeRepair")
        path = self.root / task["path"]
        fixture = json.loads(path.read_text(encoding="utf-8"))
        fixture["workspace"].append(dict(fixture["workspace"][0]))
        canonical_write(path, fixture)
        task["fixture_sha256"] = validator.sha256(path.read_bytes())
        canonical_write(self.root / "manifest.json", manifest)
        with self.assertRaisesRegex(validator.ValidationError, "duplicate workspace path"):
            validator.validate(self.root)

    def test_required_category_cannot_be_downgraded(self) -> None:
        manifest = self.load_manifest()
        task = next(item for item in manifest["tasks"] if item["category"] == "intentRouting")
        task["is_required"] = False
        canonical_write(self.root / "manifest.json", manifest)
        with self.assertRaisesRegex(validator.ValidationError, "required category"):
            validator.validate(self.root)

    def test_noncanonical_json_is_rejected(self) -> None:
        path = self.root / "manifest.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8", newline="\n")
        with self.assertRaisesRegex(validator.ValidationError, "not in canonical"):
            validator.validate(self.root)

    def test_nonfinite_json_constant_is_rejected(self) -> None:
        path = self.root / "manifest.json"
        raw = path.read_text(encoding="utf-8")
        path.write_text(raw.replace('"weight":1.0', '"weight":NaN', 1), encoding="utf-8", newline="\n")
        with self.assertRaisesRegex(validator.ValidationError, "non-finite JSON constant"):
            validator.validate(self.root)

    def test_boolean_fixture_schema_version_is_rejected_even_after_rehash(self) -> None:
        manifest = self.load_manifest()
        task = manifest["tasks"][0]
        path = self.root / task["path"]
        fixture = json.loads(path.read_text(encoding="utf-8"))
        fixture["schema_version"] = True
        canonical_write(path, fixture)
        task["fixture_sha256"] = validator.sha256(path.read_bytes())
        canonical_write(self.root / "manifest.json", manifest)
        with self.assertRaisesRegex(validator.ValidationError, "unsupported schema_version"):
            validator.validate(self.root)

    def test_v1_suite_version_is_pinned(self) -> None:
        manifest = self.load_manifest()
        manifest["suite_version"] = 2
        canonical_write(self.root / "manifest.json", manifest)
        with self.assertRaisesRegex(validator.ValidationError, "requires suite version 1"):
            validator.validate(self.root)

    def test_suite_definition_matches_local_ai_benchmark_core_codable_shape(self) -> None:
        result = validator.validate(FIXTURES)
        suite = result.suite_definition
        self.assertEqual(set(suite), {"id", "version", "requiredCategories", "tasks"})
        self.assertEqual(suite["id"], "novaforge.local-ai.general-agent")
        self.assertEqual(suite["version"], 1)
        self.assertEqual(
            suite["requiredCategories"],
            sorted(validator.REQUIRED_GENERAL_AGENT_CATEGORIES),
        )
        self.assertEqual(len(suite["tasks"]), 8)
        self.assertEqual(
            set(suite["tasks"][0]),
            {"id", "revision", "category", "weight", "isRequired", "fixtureDigest"},
        )
        task = next(item for item in suite["tasks"] if item["id"] == "v14.repair.restart-counter")
        self.assertEqual(
            task["fixtureDigest"],
            "84bfe34b9ae312a2b691ff4d3eb066d4980455560ad71afca89dffc88c2a078f",
        )
        self.assertTrue(task["isRequired"])


if __name__ == "__main__":
    unittest.main()
