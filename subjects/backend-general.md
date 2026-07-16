## 2. Backend

### 2.1 General backend guidelines
- Layer strictly: handlers/controllers never touch data access directly; a repository/data-access layer sits in between.
- Return structured, stable error codes/mnemonics from the API boundary; never leak raw exception details or stack traces to clients. Map error codes centrally on the consuming (frontend) side rather than ad hoc per call site.
- Every mutation of important state should be auditable — either an audit-log table, structured logging, or both — especially for anything with compliance implications.
- Prefer reversible actions (deactivate/soft-delete) over hard deletes where the domain allows it.
- Async all the way — no sync-over-async blocking; wrap unit-of-work/connections in `using`/RAII so they're always released.
