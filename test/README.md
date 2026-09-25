# Test layout

Mirror the implementation path and namespace where possible:

| Implementation | Tests |
| --- | --- |
| `lib/laughter.ex` | `test/laughter_test.exs`, with parser feature suites under `test/laughter/` |
| `lib/laughter/rewriter.ex` | `test/laughter/rewriter_test.exs`, with feature suites under `test/laughter/rewriter/` |
| `lib/laughter/rewriter/{content,legacy,session}.ex` | Corresponding `test/laughter/rewriter/*_test.exs` |
| `lib/laughter/nif.ex` / native plan implementations | `test/laughter/nif/{plan,stream,dynamic}_test.exs` |
| `codegen/{rewrite,nif,events}.exs` | Corresponding `test/codegen/*_test.exs` |

- Test module names follow their paths: `Laughter.Rewriter.SessionTest`,
  `Laughter.Codegen.EventsTest`, etc.
- Keep one test case per file. Put private fixture modules inside their owning case.
- Keep direct NIF contract tests separate from public API tests and code-generation tests.
- Legacy tests exercise the public callback API, ensuring its compatibility facade works.
- Cross-mode equivalence and lifecycle tests stay under `test/laughter/rewriter/`.
- Lifecycle counters and call-tracing cleanup tests remain `async: false` because
  they observe VM-global state. Other suites retain their existing async behavior.
- Keep helpers local unless multiple suites genuinely need the same abstraction.

`test/fixtures/package_consumer/` is a standalone project for archive validation,
not another test case in this project. `scripts/check-package.sh` copies it to a
fresh temporary directory and runs `smoke.exs` against extracted package sources.

Run a feature or layer directly:

```sh
mix test test/laughter/rewriter_test.exs test/laughter/rewriter/
mix test test/laughter/nif/
mix test test/codegen/
```
