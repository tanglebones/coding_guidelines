## 7. Working with AI Coding Assistants

- Review AI-generated code carefully, especially data structures and constraints — don't trust it silently, particularly around anything touching persisted data.
- Be explicit about unstated requirements (e.g. data-preservation rules) — the assistant won't infer them.
- Test AI-suggested migrations/changes against realistic, populated data, not empty tables.
- Keep a persistent, explicit "rules" document that the assistant is pointed at every session, so conventions survive across sessions instead of having to be re-explained (this file is meant to be exactly that).
