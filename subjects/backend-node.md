### Node.js / TypeScript backend

- Layer "core" libraries by execution environment: environment-agnostic code first, dropping to a Node-only or browser-only layer only when the API genuinely needs it. It's fine for a Node-specific layer to duplicate an environment-agnostic function with a better platform-specific implementation.
  ```
  lib/
    anycore/     # environment-agnostic
    nodecore/    # Node-only, imports from anycore
    webcore/     # browser-only, imports from anycore
    nodesrv/     # server-specific, imports from nodecore
  ```
- Prefer factory functions (`xFactory(...)`) returning an object of bound functions over classes; no DI container — dependencies passed explicitly.
  ```ts
  export const widgetRepositoryFactory = (
    dbProvider: DbProviderType,
    onError: (error: string, details: Record<string, unknown>) => void,
  ): WidgetRepositoryType => {
    const create = async (widget: WidgetType) => { ... };
    const find = async (widgetId: string) => { ... };
    return { create, find };
  };
  ```
- Lightweight tagged error type with a short SCREAMING_SNAKE_CASE code (`throw new AppError("NO_CTX_REQ")`) instead of deep custom exception hierarchies.
  ```ts
  export class AppError extends Error {
    constructor(public code: string, public details?: Record<string, unknown>) {
      super(code);
    }
  }
  // usage:
  if (!ctx.req) throw new AppError("NO_CTX_REQ");
  ```
- A `ctx` object threaded through request handling carries db/session/request state.
  ```ts
  type CtxReqType = { settings: SettingsType; req: RequestInfoType; db: { dbProvider: DbProviderType } };
  const ctxReqFactory = (req: RequestInfoType, dbProvider: DbProviderType, settings: SettingsType): CtxReqType =>
    ({ settings, req, db: { dbProvider } });
  // handlers take `ctx: CtxReqType` instead of pulling globals
  ```
- snake_case filenames, camelCase identifiers, `.type.ts` suffix for pure type-only files, `.test.ts` colocated with source, `.default.ts` suffix for default-config/instance modules.
- Extract generic utilities into small scoped internal packages rather than duplicating inline helpers across services.
- Status/health convention: `/status` (grep-able structured log) plus `/healthz` for liveness.
