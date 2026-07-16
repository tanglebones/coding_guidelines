## Frontend

### General frontend guidelines
- Centralize all HTTP/API calls behind one service/module — never hardcode endpoints inline in components.
  ```ts
  export class ApiService {
    constructor(private http: HttpClient) {}
    getWidgets(): Observable<WidgetType[]> { return this.http.get<WidgetType[]>(`${API_URL}/widgets`); }
  }
  ```
- Strong-type API responses; avoid `any`.
- **Keep a large-integer field (anything the backend encoded as a JSON string per `backend-general`'s payload conventions) as a string or `BigInt`, never `Number(...)`-coerce it.** Coercing back to a plain JS number reintroduces exactly the precision loss the string encoding existed to avoid — the type the backend chose for the field is part of the contract, not an inconvenience to undo on receipt.
- Avoid `Map`/`Set` in component/app state — prefer `Record<K, V>` so state stays trivially JSON-serializable.
  ```ts
  const [featureFlags, setFeatureFlags] = useState<Record<string, boolean>>({});
  ```
- Consistent async UX: disable the triggering control and show a loading indicator during the action; on completion, always clear the loading state and surface errors — no infinite spinners (wrap in try/catch/finally).
  ```ts
  function useActionLoading() {
    const [loading, setLoading] = useState(false);
    const withLoading = <T,>(fn: () => Promise<T>) => async () => {
      setLoading(true);
      try { return await fn(); } finally { setLoading(false); }
    };
    return { loading, withLoading };
  }
  // <Switch disabled={loading} onChange={(_, v) => withLoading(() => updateFlag(key, v))()} />
  ```
- Debounce search inputs; persist meaningful page/filter state in the URL, not only in memory.
  ```ts
  const [searchParams, setSearchParams] = useSearchParams();
  const [query, setQuery] = useState(searchParams.get("q") ?? "");
  const debouncedQuery = useDebouncedValue(query, 150);
  useEffect(() => { fetchResults(debouncedQuery); }, [debouncedQuery]);
  const onChange = (v: string) => {
    setQuery(v);
    setSearchParams(v.trim() ? { q: v } : {}, { replace: true });
  };
  ```
- Route by stable ID, not by display name.
- Environment config is swapped/token-replaced at build or deploy time — never hand-edit a generated environment file.
- Zero-warning lint gate in CI (`--max-warnings=0` style) where a lint step exists.
