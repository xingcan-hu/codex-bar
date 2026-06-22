# Codex Bar

Codex Bar is a small macOS menu bar app that shows the remaining Codex usage for the current account in `~/.codex/auth.json`.

It intentionally supports only one account: the current Codex account. It does not switch accounts, refresh OAuth tokens, edit `auth.json`, or manage Codex sessions.

## What It Shows

- The menu bar title shows the lowest remaining percentage across the primary and secondary usage windows.
- The dropdown menu shows primary and secondary remaining usage, window length, reset time, last refresh time, and any request error.
- `Refresh Now` fetches the latest usage immediately.
- `Refresh Interval...` lets you set the polling interval in seconds.
- `Reload auth.json on refresh` controls whether every refresh rereads `~/.codex/auth.json`.

By default, Codex Bar reads `~/.codex/auth.json` once at startup and reuses the in-memory token for later refreshes.

## Usage Source

Codex Bar follows the same basic API-backed usage flow used by `loongphy/codex-auth`:

1. Read `tokens.access_token` and `tokens.account_id` from `~/.codex/auth.json`.
2. Request:

   ```http
   GET https://chatgpt.com/backend-api/wham/usage
   Authorization: Bearer <access_token>
   ChatGPT-Account-Id: <account_id>
   Accept: application/json
   ```

3. Parse `rate_limit.primary_window` and `rate_limit.secondary_window`.

This sends your ChatGPT access token to OpenAI's ChatGPT backend endpoint. The app stores no copy of the token outside process memory unless you enable macOS crash/reporting tools yourself.

## Build

Requires macOS 13 or newer and Apple Command Line Tools with `clang`.

```bash
./scripts/test.sh
./scripts/build_app.sh
```

The app bundle is created at:

```text
dist/Codex Bar.app
```

## Install

Install to `/Applications`:

```bash
./scripts/install.sh /Applications
```

Launch it:

```bash
open "/Applications/Codex Bar.app"
```

You can also install to another folder:

```bash
./scripts/install.sh "$HOME/Applications"
```

## Settings

Settings are stored with `UserDefaults` under the app bundle identifier `com.local.codexbar`.

- Default refresh interval: 300 seconds
- Minimum refresh interval: 30 seconds
- Reload `auth.json` on refresh: off by default

## Limitations

- ChatGPT/Codex auth only; API key auth is not supported.
- One account only.
- No token refresh. If the token expires, sign in through Codex again, then restart Codex Bar or enable `Reload auth.json on refresh`.
- The usage endpoint is not a public stable API, so response fields may change.

## License

MIT
