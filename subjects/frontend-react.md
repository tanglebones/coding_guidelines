### 3.2 React / TypeScript

- Functional components + hooks only; no class components.
- Prefer `type` over `interface`; avoid `class`, prefer closures/functions.
- Named export per component, with an explicit `displayName` set at the bottom of the file.
  ```tsx
  export const PasswordInput = React.forwardRef<HTMLInputElement, PasswordInputProps>((props, ref) => {
    const [visible, setVisible] = React.useState(false);
    const toggle = (e: React.MouseEvent) => { e.preventDefault(); setVisible(v => !v); };
    exportActions(actions, { toggle }); // exposes the handler for tests, no prop-drilling
    return <div className="password-input">...</div>;
  });
  PasswordInput.displayName = "PasswordInput";
  ```
- An `exportActions(actions, {...})` pattern to expose internal handlers for testing without prop-drilling is a useful option for components with complex internal behavior.
- Encapsulate lifecycle-sensitive browser APIs in custom hooks (e.g. a hook wrapping `requestAnimationFrame` that also handles `cancelAnimationFrame` cleanup, or a subscribe-on-mount/unsubscribe-on-unmount transport hook).
  ```tsx
  function useLiveConnection(url: string) {
    const connectionRef = useRef<Connection>();
    useEffect(() => {
      connectionRef.current = connect(url);
      return () => connectionRef.current?.close();
    }, [url]);
  }
  useLiveConnection.displayName = "useLiveConnection";
  ```
- Keep `.tsx` files thin — extract non-trivial logic into plain functions/modules.
- For apps with heavy realtime/interactive needs, consider a single WebSocket-RPC transport for all post-auth data instead of ad hoc REST endpoints — not a universal rule, but worth evaluating.
- Prettier as the formatting gate (a reasonable baseline config: semi, singleQuote, trailingComma all, printWidth 120); a strict typecheck (`tsc -b` or equivalent) as the minimum lint gate where a full linter isn't set up.
- Vite + Vitest (+ Testing Library where present) is a solid modern toolchain default; wire up client-side error monitoring.
- Keep layout sub-panels always visible but disabled rather than conditionally unmounting them.
