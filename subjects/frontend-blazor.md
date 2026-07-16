### Blazor

- Render mode is opt-in per component (e.g. `@rendermode InteractiveServer`), not set globally.
  ```razor
  @* WidgetPanel.razor *@
  @rendermode InteractiveServer
  ```
- Component-scoped CSS/JS colocated with the `.razor` file; static assets served via `MapStaticAssets()` / `@Assets[...]`.
  ```
  Components/WidgetPanel.razor
  Components/WidgetPanel.razor.css
  Components/WidgetPanel.razor.js
  ```
  ```razor
  <script src="@Assets["Components/WidgetPanel.razor.js"]"></script>
  ```
