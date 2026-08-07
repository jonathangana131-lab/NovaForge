from pathlib import Path

path = Path("Packages/AgentHarnessKit/Tests/ForgeMissionTests/ForgeMissionTests.swift")
text = path.read_text()
old = 'MissionStage(stageID: optionalID, kind: .design, title: "Optional choice", order: 1, required: false)'
new = 'MissionStage(stageID: optionalID, kind: .plan, title: "Optional choice", order: 1, required: false)'
if text.count(old) != 1:
    raise SystemExit(f"transition fixture kind: expected exactly one match, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
