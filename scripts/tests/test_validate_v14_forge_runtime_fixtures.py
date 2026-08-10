import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "validate-v14-forge-runtime-fixtures.py"
spec = importlib.util.spec_from_file_location("fixture_validator", SCRIPT)
validator = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(validator)


class FixtureValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "V14"
        shutil.copytree(validator.FIXTURE_ROOT, self.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_canonical_fixture_corpus_passes(self):
        self.assertEqual(validator.validate_all(self.root), ["focus-notes", "vector-drift"])

    def test_external_network_reference_fails_closed(self):
        page = self.root / "focus-notes" / "index.html"
        page.write_text(page.read_text() + "\n<script>fetch('https://example.com')</script>\n")
        with self.assertRaisesRegex(validator.ValidationError, "external-network"):
            validator.validate_all(self.root)

    def test_storage_namespace_cannot_cross_project(self):
        manifest = self.root / "vector-drift" / "novaforge.runtime.json"
        payload = json.loads(manifest.read_text())
        payload["storage"]["namespace"] = "fixture.focus-notes"
        manifest.write_text(json.dumps(payload))
        with self.assertRaisesRegex(validator.ValidationError, "storage namespace"):
            validator.validate_all(self.root)

    def test_semantic_target_duplicates_fail_closed(self):
        page = self.root / "focus-notes" / "index.html"
        text = page.read_text()
        text = text.replace('</main>', '<button data-novaforge-control="add-task">duplicate</button></main>')
        page.write_text(text)
        with self.assertRaisesRegex(validator.ValidationError, "duplicate data-novaforge-control"):
            validator.validate_all(self.root)

    def test_unknown_fixture_fails_closed(self):
        shutil.copytree(self.root / "focus-notes", self.root / "unexpected")
        with self.assertRaisesRegex(validator.ValidationError, "fixture set"):
            validator.validate_all(self.root)


if __name__ == "__main__":
    unittest.main()
