import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Fixtures" / "ForgeRuntime" / "V14"


class AccessibilityParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lang = ""
        self.live_regions = 0
        self.autofocus = 0
        self.inputs = []
        self.canvases = []
        self.buttons = []
        self._button_stack = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "html":
            self.lang = values.get("lang") or ""
        if values.get("aria-live") in {"polite", "assertive"}:
            self.live_regions += 1
        if "autofocus" in values:
            self.autofocus += 1
        if tag == "input":
            self.inputs.append(values)
        elif tag == "canvas":
            self.canvases.append(values)
        elif tag == "button":
            record = {"attrs": values, "text": []}
            self.buttons.append(record)
            self._button_stack.append(record)

    def handle_endtag(self, tag):
        if tag == "button" and self._button_stack:
            self._button_stack.pop()

    def handle_data(self, data):
        if self._button_stack:
            self._button_stack[-1]["text"].append(data)


class FixtureAccessibilitySourceTests(unittest.TestCase):
    def audit(self, name):
        source = (FIXTURES / name / "index.html").read_text(encoding="utf-8")
        parser = AccessibilityParser()
        parser.feed(source)

        self.assertEqual(parser.lang, "en", f"{name}: document language")
        self.assertGreaterEqual(parser.live_regions, 1, f"{name}: status updates need a live region")
        self.assertEqual(parser.autofocus, 0, f"{name}: fixture must not steal focus on load")
        self.assertTrue(parser.buttons, f"{name}: expected interactive controls")

        for index, button in enumerate(parser.buttons):
            attrs = button["attrs"]
            text = "".join(button["text"]).strip()
            self.assertEqual(attrs.get("type"), "button", f"{name}: button {index} must not imply form submission")
            self.assertTrue(attrs.get("aria-label") or text, f"{name}: button {index} needs an accessible name")
            self.assertIn("data-novaforge-control", attrs, f"{name}: button {index} must expose a semantic control target")

        for index, attrs in enumerate(parser.inputs):
            self.assertTrue(attrs.get("aria-label"), f"{name}: input {index} needs an aria-label")
            self.assertIn("data-novaforge-text-input", attrs, f"{name}: input {index} must expose a semantic text target")

        return source, parser

    def test_focus_notes_source_accessibility_contract(self):
        source, parser = self.audit("focus-notes")
        self.assertEqual(len(parser.inputs), 1)
        self.assertIn("prefers-reduced-motion: no-preference", source)
        self.assertIn("event.key === 'Enter'", source, "keyboard add path must remain available")

    def test_vector_drift_source_accessibility_contract(self):
        source, parser = self.audit("vector-drift")
        self.assertEqual(len(parser.canvases), 1)
        canvas = parser.canvases[0]
        self.assertEqual(canvas.get("tabindex"), "0")
        self.assertEqual(canvas.get("role"), "application")
        self.assertTrue(canvas.get("aria-label"))
        self.assertIn("prefers-reduced-motion:reduce", source)
        for key in ("ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"):
            self.assertIn(key, source, f"keyboard direction {key} must remain available")


if __name__ == "__main__":
    unittest.main()
