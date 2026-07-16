### Angular

- Feature-module folder convention: `.module.ts` + `-routing.module.ts` + component + `.spec.ts` per feature.
- Centralize all HTTP in an injectable `ApiService` returning `Observable<T>`; put cross-cutting concerns (auth headers, error toasts) in interceptors, not per-call code.
  ```ts
  @Injectable()
  export class AuthInterceptor implements HttpInterceptor {
    intercept(req: HttpRequest<unknown>, next: HttpHandler) {
      return next.handle(req.clone({ setHeaders: { Authorization: `Bearer ${this.token}` } }));
    }
  }
  ```
- Route guards as dedicated classes; lazy-load feature modules.
- Loading state tracked via per-request keys in a shared `LoaderService` so multiple concurrent requests don't clobber each other's spinner state.
  ```ts
  @Injectable({ providedIn: "root" })
  export class LoaderService {
    private active: Record<string, boolean> = {};
    status = new BehaviorSubject<boolean>(false);
    set(key: string, isLoading: boolean) {
      this.active[key] = isLoading;
      this.status.next(Object.values(this.active).some(Boolean));
    }
  }
  ```
- Minimum "should create" (`TestBed` + `HttpClientTestingModule`) smoke test per component is an accepted floor even without deeper coverage.
- `npm audit` must pass for new dependencies; track any necessary exceptions in an explicit allowlist file rather than silently ignoring.
