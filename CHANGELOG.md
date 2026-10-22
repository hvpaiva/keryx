# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Addresses that outlive sessions, claimed with `keryx join` and released with `keryx leave`, for
  Claude Code, Codex and Cursor sessions and any agent in a herdr pane.
- Maildir-style mailboxes under `$XDG_STATE_HOME/keryx`, with atomic delivery and no locks.
- `send`, `ask`, `inbox`, `read`, `reply` and `wait`, with request deadlines and threads. Agents
  can write to the person at the keyboard before that person has used keryx.
- Bells through the Claude Code peer socket, `codex queue`, or typing into a herdr pane when no
  dialog shows, which is how Cursor is rung.
- `keryx hook stop`, the stop hook of Claude Code, Codex and Cursor, which reminds a session of
  unread mail and unanswered requests before it ends a turn.
- `who`, `whoami` and `status`, and `ring` to retry bells that did not reach a session.
- `keryx skill`, the instructions agents follow to use keryx.
- Shell completion for bash, zsh and fish.

[Unreleased]: https://github.com/hvpaiva/keryx/commits/main
