@AGENTS.md

Claude Code specifics: hooks in `.claude/settings.json` format every edited Swift file and
feed SwiftLint findings back to you (fix them before finishing), block direct
`project.pbxproj` edits, and export Apple's Xcode agent skills on session start. Prefer the
`make` targets; they keep tool output small.
