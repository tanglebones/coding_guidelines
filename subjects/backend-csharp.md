### 2.2 C#/.NET

**Formatting & structure**
- 2-space indent, no tabs; braces always required (no single-line `if` without braces); **Allman style** — opening brace on its own line.
- One type per file, filename matches the type name; file-scoped namespaces; directories mirror namespaces (no incidental subfolders).
  ```csharp
  using System.IO.Abstractions; // NuGet: TestableIO.System.IO.Abstractions

  namespace Company.Widgets.Lib;

  public sealed class WidgetSyncRunner : IWidgetSyncRunner
  {
      internal static class Dep
      {
          public static IFileSystem FileSystem = FileSystemDep.Real;
      }

      public async Task RunAsync(CancellationToken ct = default)
      {
          if (Dep.FileSystem.File.Exists(path))
          {
              ...
          }
      }
  }
  ```
- No `#region`.
- `.editorconfig`-enforced where present: LF line endings, final newline, file-scoped namespaces.

**Design**
- Most restrictive access modifier by default (`private` > `internal` > `public`); avoid `protected` entirely.
- No `abstract` classes, no implementation inheritance (`virtual`/`override`) — use `sealed` classes + interfaces (ISP/LSP) + composition/delegation instead.
- Avoid `enum`; prefer discriminated-union-style types (e.g. `OneOf`) or string constants.
  ```csharp
  using OneOf;

  internal static class WidgetDeleteResolver
  {
      internal static OneOf<NeedsDelete, AlreadyGone, SizeMismatch> Decide(
          IFileSystem fileSystem, string path, long expectedSizeBytes)
      {
          if (!fileSystem.File.Exists(path)) return new AlreadyGone();
          return fileSystem.FileInfo.New(path).Length == expectedSizeBytes
              ? new NeedsDelete()
              : new SizeMismatch();
      }
  }
  ```
  **Once .NET 11 ships, prefer the native `union` type over `OneOf`** for this — it needs no library dependency and is consumed with an ordinary `switch`, no `.Match()`/`.Switch()` call needed:
  ```csharp
  internal union WidgetDeleteDecision(NeedsDelete, AlreadyGone, SizeMismatch);

  internal static class WidgetDeleteResolver
  {
      internal static WidgetDeleteDecision Decide(IFileSystem fileSystem, string path, long expectedSizeBytes)
      {
          if (!fileSystem.File.Exists(path)) return new AlreadyGone();
          return fileSystem.FileInfo.New(path).Length == expectedSizeBytes
              ? new NeedsDelete(path)
              : new SizeMismatch(path);
      }
  }

  // consuming code:
  switch (WidgetDeleteResolver.Decide(fileSystem, path, expectedSizeBytes))
  {
      case NeedsDelete needsDelete: fileSystem.File.Delete(needsDelete.Path); break;
      case AlreadyGone: break;
      case SizeMismatch sizeMismatch: Log(sizeMismatch.Path); break;
  }
  ```
- Avoid "class as data + serialization" — for external/DB-shaped data prefer raw dynamic/JSON objects or query results over rigid POCOs; prefer Newtonsoft.Json over `System.Text.Json` where a choice exists.
- Never emit explicit `null`s in API responses; model optionality more explicitly.
- UTC / `DateTimeOffset` / `TimeSpan` everywhere — never naive local `DateTime`.
  ```csharp
  public sealed class Clock : IClock
  {
      public DateTimeOffset UtcNow() => DateTimeOffset.UtcNow;
  }
  ```
- `var` everywhere; LINQ method syntax, not query syntax; iterative over recursive; depend on interfaces, construct concrete types lazily at the edges.

**Dependency injection & testing**
- No IoC container. Use a `Dep` static inner-class pattern for test seams: static mutable fields swapped in tests, `Reset()` called in teardown; generic classes get a companion `${Foo}Dep` class. The inner class is always named `Dep` (singular) — never `Deps`.
  ```csharp
  // One small wrapper per dependency source/area, not one shared class bundling
  // everything together — FileSystem and Clock come from unrelated libraries.
  internal static class FileSystemDep
  {
      public static readonly IFileSystem Real = new FileSystem(); // System.IO.Abstractions
  }

  internal static class ClockDep
  {
      public static readonly IClock Real = new Clock();
  }

  public sealed class WidgetSyncRunner
  {
      internal static class Dep
      {
          public static IFileSystem FileSystem = FileSystemDep.Real;
          public static IClock Clock = ClockDep.Real;
          public static void Reset() { FileSystem = FileSystemDep.Real; Clock = ClockDep.Real; }
      }
  }

  // in a test fixture:
  [SetUp] public void SetUp() { WidgetSyncRunner.Dep.Clock = _fakeClock; }
  [TearDown] public void TearDown() => WidgetSyncRunner.Dep.Reset();
  ```
- Testing stack: **NUnit + FakeItEasy** (`A.Fake<T>()`), with a fake/in-memory filesystem abstraction for file I/O.
  ```csharp
  [TestFixture]
  public class WidgetSyncRunnerTf
  {
      private IClock _clock = A.Fake<IClock>();

      [SetUp]
      public void SetUp() =>
          A.CallTo(() => _clock.UtcNow()).Returns(new DateTimeOffset(2025, 6, 15, 10, 30, 0, TimeSpan.Zero));
  }
  ```
- `InternalsVisibleTo` wired to the matching `.Test` assembly (and FakeItEasy's dynamic proxy assembly) via the `.csproj`.
- All `Task`/`Task<T>` methods take a trailing `CancellationToken ct = default`.
- Trivial "constructs without throwing" / non-null smoke tests are an accepted floor even when deeper coverage is missing.
- For libraries with well-defined boundaries, consider enforcing 100% line/branch coverage via a coverage gate, with explicit `[ExcludeFromCodeCoverage]` + a short comment for the handful of intentionally-excluded composition-root classes.
  ```csharp
  [ExcludeFromCodeCoverage(Justification = "Thin wrapper around the real DB connection")]
  internal static class SqlQueryExecutor { ... }
  ```

**Anti-patterns to avoid**
- `Try/Catch` that re-throws as `new Exception(ex.Message)`, losing the original stack trace — use `throw;` instead.
- Returning raw exception objects to API clients (e.g. `BadRequestObjectResult(ex)`) — map to a stable, safe error code/message instead.
