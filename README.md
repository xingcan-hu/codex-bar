# Codex Bar

Codex Bar is a small macOS menu bar app that shows the remaining Codex usage for the active account and can switch between accounts managed by [`codex-auth`](https://github.com/Loongphy/codex-auth).

It reads the same multi-account registry used by `codex-auth` at `~/.codex/accounts/registry.json`, and switches accounts by copying the selected account snapshot to `~/.codex/auth.json`.

## What It Shows

- The menu bar title shows the active account's 5H and weekly remaining usage.
- The dropdown menu shows the active account, plan, 5H reset, weekly reset, and any request error.
- `Accounts` opens a submenu of `codex-auth` accounts. Opening it refreshes all accounts concurrently, then each row shows plan, 5H remaining, weekly remaining, relative last refresh time, and identity.
- Clicking an account row switches immediately.
- `Refresh Now` fetches the latest usage for the active account.
- `Refresh Interval...` lets you set the polling interval in seconds.
- `Request Timeout...` sets the maximum duration for each usage request.
- `Reload accounts on refresh` controls whether refreshes reread the registry and active auth file.

By default, Codex Bar reads account files once at startup and reuses the in-memory active token for regular active-account refreshes.

## Usage Source

Codex Bar follows the same basic API-backed usage flow used by `codex-auth`:

1. Read `tokens.access_token` and `tokens.account_id` from the active account auth file.
2. Request:

   ```http
   GET https://chatgpt.com/backend-api/wham/usage
   Authorization: Bearer <access_token>
   ChatGPT-Account-Id: <account_id>
   Accept: application/json
   ```

3. Parse `rate_limit.primary_window` and `rate_limit.secondary_window`.
4. Persist refreshed usage into `~/.codex/accounts/registry.json` for the matching account.

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

Overwrite the installed app and restart it:

```bash
./scripts/overwrite_install.sh
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
- Default request timeout: 3 seconds
- Minimum request timeout: 1 second
- Reload accounts on refresh: off by default

## Limitations

- ChatGPT/Codex auth only; API key auth is not supported.
- Account login, import, remove, and alias management are intentionally left to `codex-auth`.
- No token refresh. If a token expires, sign in or import through `codex-auth` again, then restart Codex Bar or enable `Reload accounts on refresh`.
- The usage endpoint is not a public stable API, so response fields may change.

## License

MIT
