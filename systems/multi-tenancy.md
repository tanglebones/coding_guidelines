# Multi-Tenancy

Reference for building a multi-tenant system — one where distinct customer organizations (or internal business units) share the same application and database, and must never see each other's data. This is one of the `systems/` reference docs (see `README.md`'s "Systems reference" section) — not part of the always-loaded guideline set, consulted only when this specific type of work is underway. The mechanisms below are verified against a real implementation.

## Data model: shared schema, `tenant_id` on every tenant-owned table

- **A `tenant` table**, with a stable slug distinct from its display name (the slug is what shows up in URLs/config and shouldn't change even if the display name is rebranded):
  ```sql
  create table tenant (
    tenant_id uuid primary key default (uuidv7()),
    tenant_slug text not null unique,
    tenant_display_name text not null
  );
  ```
- **Every tenant-owned table gets a direct `tenant_id` FK**, not a transitive relationship inferred through joins — this is the same "denormalized scoping FK on every leaf table" reasoning as the ownership discussion in `database`: a query can filter locally (`where tenant_id = $1`) instead of trusting a join chain to be complete.
  ```sql
  create table app (
    app_id uuid primary key default (uuidv7()),
    tenant_id uuid not null references tenant(tenant_id) on delete restrict,
    app_slug text not null,
    app_display_name text not null,
    unique (tenant_id, app_slug) -- slugs are a per-tenant namespace, not global
  );
  create index on app (tenant_id);
  ```
- **Membership is a many-to-many table with the role baked into the membership row itself**, not a separate join table — a user can hold more than one role in the same tenant (multiple rows), and belongs to as many tenants as needed:
  ```sql
  create table user_account_x_tenant (
    user_account_x_tenant_id uuid primary key default (uuidv7()),
    user_account_id uuid not null references user_account(user_account_id) on delete restrict,
    tenant_id uuid not null references tenant(tenant_id) on delete restrict,
    tenant_role_mnemonic text not null references tenant_role(tenant_role_mnemonic) on delete restrict,
    unique (user_account_id, tenant_id, tenant_role_mnemonic)
  );
  ```

## Users belonging to multiple tenants

**"Current tenant" is part of the session, not a per-request parameter the client supplies.** A session is scoped to exactly one active tenant at a time (via a claim on the session, see `systems/session-management.md`); acting as a different tenant means re-establishing the session for that tenant, not passing a different `tenantId` on each call.

- **Login is a two-step flow when a user belongs to more than one tenant**: verify identity first, then let them choose which tenant to act as. Carry the verified identity between those two steps with a short-lived encrypted token (the same technique as any multi-step flow needing to survive a redirect without server-side stashed state) — but **never trust the tenant choice that comes back without re-deriving it server-side**: re-check that the chosen tenant is actually one of that user's memberships before issuing a session for it, exactly the same "never trust client input for authorization" discipline as everywhere else in this guideline set.
  ```csharp
  // the posted tenant choice is re-verified against real membership rows,
  // not trusted just because it round-tripped through the encrypted token
  if (!userTenants.Any(t => t.TenantId == chosenTenantId))
      return Error("not a member of that tenant");
  ```
- **Roles for the chosen tenant are flattened into session claims at sign-in**, scoped to that one tenant — so an authorization check later in the session is a claim lookup, not a fresh DB query re-deriving membership on every request.
- **Switching tenants goes back through the same re-authentication path**, rather than a lightweight in-session "switch" — the chosen-tenant claim is only ever set as part of (re-)establishing the session, keeping there being exactly one place that mints it.

## Per-tenant roles, and a two-tier permission model

- Tenant-wide roles (e.g. `tenant_admin`, `tenant_operator`) answer "what can this user do across the tenant as a whole."
- **A separate, resource-level ACL layer answers a narrower question**: "can this user operate this *specific* resource," independent of their tenant-wide role. Modeling both — a tenant-wide role table and a per-resource ACL table — rather than trying to force everything through one flat role list, cleanly separates "member of the org" from "can operate this particular thing."

## The "platform"/global-admin concept

**Model global administration as membership-with-a-role in one reserved tenant, not a separate boolean flag on the user account.** A "platform" tenant is a real row in the same `tenant` table as any customer tenant; being a platform admin is derived, at sign-in, from holding the admin role specifically within that one reserved tenant — nothing else about the user account marks them as special.

```csharp
if (tenantId == PlatformTenantId && roles.Contains(TenantRoles.Admin))
    claims.Add(new Claim(NdyClaims.IsPlatformAdmin, "true"));
```

This needs no special-cased authorization path at all — it composes entirely out of the ordinary tenant + tenant-role primitives already built for regular tenants, just pointed at one designated tenant. (A genuinely separate area/app for global admin, entirely outside the tenant model, is just as valid a design — the point is to pick one of these deliberately, not end up with a bolted-on `IsSuperAdmin` boolean that bypasses the tenant model as an afterthought.)

## Enforcement — where this actually goes wrong in practice

**Filtering by tenant is a convention enforced by every query author remembering to do it — there is no structural guarantee (no ORM global query filter, no Postgres Row-Level Security, no tenant-aware repository base class) unless one is deliberately built.** This is the single biggest risk in a multi-tenant system, and it's exactly where a real, otherwise well-designed implementation of everything above still had a live cross-tenant vulnerability:

```csharp
// Anti-pattern, found in practice: loads a tenant-owned resource by primary
// key with no check that it belongs to the caller's current tenant at all.
// Any authenticated user of ANY tenant who learns/guesses this id — a
// leaked URL, a log line, a shared support ticket — can view and edit it.
protected override async Task OnInitializedAsync() {
    _app = await Apps.FindByIdAsync(AppId); // no tenant filter/check
}

// Fix: re-check the loaded resource's tenant against the caller's current
// tenant claim, even though the route/page is already behind [Authorize].
protected override async Task OnInitializedAsync() {
    _app = await Apps.FindByIdAsync(AppId);
    if (_app is null || _app.TenantId != CurrentTenantId) { Forbidden(); return; }
}
```

**Being authenticated, and even being gated behind an authorization policy at the page/endpoint level, proves nothing about whether the specific resource loaded by id belongs to the caller's tenant** — that's a separate check, and it has to happen after the load, every time a tenant-owned resource is fetched by id. This is the tenant-scoped instance of the IDOR pattern already called out in `backend-general`'s security-patterns section — the fix there generalizes directly here: re-check the specific resource against the caller's authorization on every request, not just "is this route behind a gate."

**Mandate at least one explicit cross-tenant isolation test per tenant-scoped repository/endpoint** — create data in two different tenants and assert tenant A's session cannot read, list, or write tenant B's rows. A composite index or unique constraint on `tenant_id` proves the schema *models* isolation; it proves nothing about whether the application code actually *enforces* it, and a test suite that only ever creates data in one tenant can't catch this class of bug at all.
