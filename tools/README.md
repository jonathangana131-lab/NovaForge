# tools/ — predecessor session tooling

Battle-tested scripts from the Overdrive session (runs 9-29). Run with python3.

- openstep_lint.py <pbxproj>   — OpenStep plist grammar validator. Calibrated
  against Xcode's parser on a real failure: catches unquoted '+' in path
  values ("damaged project" errors). Lint BEFORE every pbxproj push.
- pbxproj_add.py <Group> <app|app,tests> <File.swift ...> — registers new
  source files in all four pbxproj sections. Quotes non-alphanumeric paths.
  Files compiled by AgentPadTests must target app,tests.
- swiftmap.py <file>           — top-level declaration map with line ranges.
- membermap.py <file> <start> <end> [minLines] — member-level map of a type
  body (4-space indent members).
- dead_code_purge2.py          — fixed-point dead-member deletion with
  paren-aware ranges, per-block brace+paren balance gates, and orphan-tail
  audit. Its predecessor cut a multi-line signature in half with balanced
  braces; this one refuses ambiguous blocks. Adapt the FAMILIES table first.
