# Contributing to ThunderNet

Thanks for helping improve ThunderNet For Roblox (full name: ThunderNetworking).
This project favors small, tested changes over large speculative rewrites.

## Before you start

- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
  [docs/SECURITY.md](docs/SECURITY.md).
- Check open issues and pull requests to avoid duplicate work.
- For a security vulnerability, follow [SECURITY.md](SECURITY.md). Never open a
  public issue with exploit details.
- For a large feature, open an issue describing the problem and proposed API
  before writing code.

## Development setup

Requirements:

- [Luau CLI](https://github.com/luau-lang/luau/releases) 0.746 with
  `luau-analyze`
- [Rojo](https://github.com/rojo-rbx/rojo/releases) 7.7.1
- Node.js 18 or newer

Run the full verification:

```bash
./scripts/check.sh
```

Focused commands:

```bash
./scripts/test.sh          # CLI test suite
node scripts/analyze.mjs   # strict cross-module analysis
./scripts/bench.sh         # CPU benchmarks
```

## Rules for changes

- **Test first.** Add a failing test that describes the behavior, then make it
  pass. Bug fixes need a regression test.
- **Keep `--!strict` clean.** New modules start with `--!strict`; analysis must
  report `analysis clean`.
- **Never trust client data.** Client values are requests, not facts. Handlers
  must re-derive damage, currency, inventory, permissions, prices and cooldowns
  from server state.
- **Preserve wire compatibility deliberately.** Protocol or behavior changes
  need tests and a changelog entry. Bump the protocol version if old and new
  peers cannot interoperate.
- **No new runtime dependencies.** The framework uses Roblox primitives and the
  Luau standard library only.
- **Distribution stays release-only.** Documentation must state that the
  supported way to get ThunderNet is the `.rbxm` from GitHub Releases.
- **Update the docs.** Public API changes require updates to `README.md`,
  `docs/API.md` and `docs/TUTORIAL.md` where relevant.

## Pull requests

A pull request should include:

- a clear description of the problem and the chosen fix
- tests that fail without the change
- the output of `./scripts/check.sh`
- documentation and `CHANGELOG.md` updates for user-visible changes
- no unrelated refactors

Keep commits focused. Reviewers may ask you to split a mixed change.

## Issue templates

Use the bug report or feature request template. Include the ThunderNet version,
Roblox Studio version when relevant, and the smallest reproduction you can.

## License

By contributing, you agree that your contribution is licensed under the
[MIT License](LICENSE), the same license as the project.
