### 2.3 Rust

- Prefer many small, single-purpose crates over one monolith; put shared logic in a thin library crate at the bottom of the dependency graph.
  ```
  workspace/
    rt/          # thin shared lib: error alias, small helpers — no dependents
    widget_fetch/
    widget_normalize/
    widget_export/
  ```
- **`anyhow::Result<T>` + `bail!()`/`.context()` everywhere** — this is the only accepted error-handling style now. Do not introduce a hand-rolled error enum or a project-wide `Rt<T> = Result<T, Box<dyn Error>>` alias for new code; treat any existing `Rt<T>`-style alias as legacy to migrate away from when touched, not a pattern to extend.
  ```rust
  use anyhow::{Result, Context, bail};

  fn parse_widget(bytes: &[u8]) -> Result<Widget> {
      if bytes.first() != Some(&b'W') {
          bail!("invalid widget header");
      }
      let body = std::str::from_utf8(bytes).context("widget body was not valid utf8")?;
      Ok(Widget::from_str(body)?)
  }
  ```
- `rustfmt`/`cargo fmt --check` and `cargo clippy --all-targets` (often `-D warnings`) enforced in CI; 2-space indent via `rustfmt.toml` is the deliberate house style, not default rustfmt (`tab_spaces = 2`, `newline_style = "Unix"`).
- `#![deny(warnings)]` at the crate root for services where that's appropriate.
- Config via `serde` + RON for human-edited files, not JSON/YAML.
  ```rust
  #[derive(serde::Deserialize)]
  struct WidgetConfig { batch_size: u32, endpoint: String }

  impl Default for WidgetConfig {
      fn default() -> Self { ron::from_str(DEFAULT_CONFIG_RON).unwrap() }
  }
  ```
- Time/randomness abstracted behind a trait (e.g. a `ClockSource`) so it can be faked in tests instead of sleeping or relying on real entropy.
  ```rust
  trait ClockSource { fn now(&self) -> Instant; }
  struct RealClock;
  impl ClockSource for RealClock { fn now(&self) -> Instant { Instant::now() } }
  struct TestClock(Cell<Instant>); // advance() manually in tests, never sleep
  ```
- Doc comments (`//!` module docs, `///` on public fns) spell out invariants, panics, and algorithmic guarantees — treated as load-bearing documentation, not boilerplate.
  ```rust
  /// Accumulates stats without a lock; fields update independently, so
  /// cross-field consistency is only guaranteed once writes have quiesced.
  pub struct StreamingStats { ... }
  ```
- Known-answer/round-trip tests as `const` arrays or deterministic hand-rolled PRNGs, preferred over pulling in a fuzzing dependency for small closed-form problems.
  ```rust
  // Verified against the spec, not against the implementation.
  const VECTORS: &[(&[u8], &str)] = &[(b"", ""), (b"f", "Zg=="), (b"fo", "Zm8=")];
  #[test]
  fn encodes_known_vectors() {
      for (input, expected) in VECTORS { assert_eq!(encode(input), *expected); }
  }
  ```
- `#[ignore]`-tag tests that need an external service so `cargo test` stays fast and hermetic by default.
  ```rust
  #[test]
  #[ignore] // requires a running postgres instance
  fn round_trips_through_postgres() { ... }
  ```
