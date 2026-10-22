# Contributing

## Setup

keryx is developed on the Ruby that `mise.toml` pins and supports Ruby 3.4 and later.

```sh
mise install
bin/setup
```

`bin/setup` installs the gems and ShellCheck and reports anything missing.

## Checks

| Command | What it runs |
|---|---|
| `bundle exec rake` | the tests and RuboCop |
| `bundle exec rake test` | the tests |
| `bundle exec rake test:cov` | the tests with line and branch coverage gates |
| `bundle exec rake lint:shell` | ShellCheck on `bin/setup` and the bash completion script |
| `bundle exec rake audit` | bundler-audit over `Gemfile.lock` |
| `bundle exec rake check` | all of the above, as CI runs them |

The tests never reach a real agent session. They use temporary mailboxes, a fake clock and fake
sockets, and the ones that start `exe/keryx` clear the variables Claude Code, Codex and herdr set.

## Conventions

- Everything in the repository is in English.
- Code explains itself through names and structure. A comment is for what the code cannot say,
  such as how another program behaves, in one line.
- Text that comes from a file or another session goes through `Text.plain` before it is printed.
- keryx has no runtime dependencies; `test/unit/version_test.rb` checks it.
- Code, scripts and tests are ASCII; `test/unit/conventions_test.rb` checks it.

## Commits and pull requests

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org) with an
  imperative summary, such as `fix: keep the bell text plain`.
- Each commit does one thing and leaves the tests passing.
- Commits are signed.
- User-visible changes get a line under `## [Unreleased]` in `CHANGELOG.md`. A change to something
  not yet released rewrites its line instead of adding a `Fixed` one.

`main` takes changes only through pull requests. The CI checks must pass on a branch up to date
with `main`, and pull requests merge as merge commits, so your signed commits reach `main` as you
signed them.

## Releases

The maintainer publishes releases. [docs/maintenance.md](docs/maintenance.md) describes how.
