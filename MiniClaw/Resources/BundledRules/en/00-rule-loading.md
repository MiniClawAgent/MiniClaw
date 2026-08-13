# MiniClaw Project Rules

- The Markdown files in this directory are project-managed rules shipped with the app; they are sorted stably by relative path and automatically injected into every agent reply.
- Rules should be direct, clear, and actionable; avoid defining the same thing in multiple files.
- When multiple rules apply, follow the rule that is more specific and more directly relevant to the current task; if unclear, ask the user for confirmation first.
- Never bypass system permissions, user confirmation, or data-security limits in the name of following rules.
- Files in this directory are named like 00-safety.md (numbers increment by 10) and end with ".md".
