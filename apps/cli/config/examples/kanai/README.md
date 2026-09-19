---
description: "Configure the API Key and start DeepSeek-V4.1-Flash through the Kanai gateway on Windows."
---
# Kanai DeepSeek connection

English | [中文](README.zh.md)

## Summary

This configuration connects the shipped Web and headless profiles to `https://api.kanai.world:6860/v1`, using model `deepseek-v4.1-flash`. Harness runs on your computer and calls the model server through this gateway; the repository does not contain model weights. Run the commands below from the repository root. The launchers support the built-in Windows PowerShell 5.1 (`powershell.exe`); PowerShell 7 is optional.

## Contents

- [First-time setup and API Key](#setup)
- [Start](#start)
- [Background autostart](#autostart)
- [Configuration](#configuration)
- [Verification](#verification)

<a id="setup"></a>
## First-time setup and API Key

Install Node.js 22.19 or later in the 22.x series, or Node.js 24 or later, and pnpm 11.7.0. Install the workspace dependencies and build:

```powershell
pnpm install --frozen-lockfile
pnpm run build
```

Create `%USERPROFILE%\.dsh-kanai` outside the repository. Save your model API Key in the `.env` file in that directory. For the Windows account `pc`, the full path is **`C:\Users\pc\.dsh-kanai\.env`**; other accounts use their own user directory. The filename must be `.env`, not `.env.txt`. Save it as UTF-8 with this content, replacing `YOUR_MODEL_API_KEY` with your actual key:

```dotenv
KANAI_API_KEY=YOUR_MODEL_API_KEY
```

Use `KANAI_API_KEY` for this gateway configuration. Keep the real value in this local file; do not paste it into the repository, the YAML configuration, screenshots, or GitHub. The launcher does not read the key from the Python calling script. To rotate the key, edit this file and restart Harness. An inherited `KANAI_API_KEY` environment variable or a repository `.env` value can override the home file; remove conflicting values when rotating it.

Copy the gateway's `kanai-local-api-ca.crt` from the directory containing your existing model-calling script into the same `.dsh-kanai` directory. On the `pc` account, the required files are:

```text
C:\Users\pc\.dsh-kanai\
  .env
  kanai-local-api-ca.crt
```

Obtain the key and CA certificate from the model service administrator when configuring another computer. They are not included in the repository. The launcher reports a missing-file error if either file is absent. Do not disable TLS verification to work around a missing certificate.

<a id="start"></a>
## Start

Start the browser interface and open the authenticated URL printed in the terminal:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-kanai.ps1 -NoOpen
```

The default address is `http://127.0.0.1:3000`; a fresh browser needs the printed token URL. `-Port` selects another port. Omitting `-NoOpen` lets Harness open the browser. Stop the foreground server with Ctrl+C.

Run one task and exit:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-kanai.ps1 -Profile headless -WebSearch off -MaxTokens 256 -Prompt "Reply with exactly FINAL_CONNECTION_OK. Do not use tools."
```

`-Mode fast` is the default and disables thinking. `normal` and `thinking` request effort 20; `max` requests effort 100 and defaults to 262,144 output tokens. Other modes default to 65,536. An explicit `-MaxTokens` overrides the output cap. `-WebSearch off|auto|force` controls the gateway's search field, defaulting to `auto`. These are request settings; the server decides whether a particular answer needs reasoning or search.

<a id="autostart"></a>
## Background autostart

After the foreground launch works, stop it with Ctrl+C. Open CMD as administrator under the same Windows account that owns the model configuration, enter this repository directory, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1
```

The installer detects the repository, current user, and Node executable. Enter that user's Windows account password when prompted; a Windows Hello PIN and the model API Key cannot replace it. Windows Task Scheduler stores the account credential; the script does not write it into files. The task runs under that user with limited privileges, starts 30 seconds after boot even before login, and requests an immediate background start after installation. The task does not open a terminal window or browser. Keep the repository at its installed path; after moving it or changing the Windows password or Node installation, stop the task and reinstall it.

For an account that only uses a PIN, install a password-free task that starts after this user logs in instead:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1 -AtLogon
```

`-AtLogon` does not start before login and stops at logout. If Windows denies task registration, use an administrator CMD under the same account. Both modes read `%USERPROFILE%\.dsh-kanai\.env` and the adjacent CA certificate. For user `liang`, that directory is `C:\Users\liang\.dsh-kanai`. Installation refuses an occupied port; stop the existing server or pass `-Port 3001` when installing. Reinstalling a running task requires stopping it first.

Check the task, then open the authenticated page after the server is ready:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1 -Action Open
```

Logs are replaced at each start in `%USERPROFILE%\.dsh-kanai\autostart\web.stdout.log` and `web.stderr.log`. `Running` describes the task process, not model readiness; `Open` checks the logged Web URL before opening it. The stdout log contains a local Web authentication token, so keep it private. If the URL is not ready, inspect the logs and retry. Neither installing the task nor opening the Web UI validates the model API Key; send a message to verify model access. Boot registration with a saved password and startup after a real reboot require validation by the deploying user; local verification covers task definitions and the actual logon-task start/stop path.

Stop active work before stopping or removing the task. These commands terminate the background server; removing the task keeps the key, certificate, logs, and sessions:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1 -Action Stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1 -Action Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\kanai-autostart.ps1 -Action Remove
```

<a id="configuration"></a>
## Configuration

The launcher uses `%USERPROFILE%\.dsh-kanai` as its dedicated Harness home. See [first-time setup](#setup) for the credential and certificate files. Session history, user settings, and profiles also remain in this directory.

The launcher sets `NODE_EXTRA_CA_CERTS` before starting Node and bypasses proxies for this process with `NO_PROXY=*`; TLS verification remains enabled. It restores the parent PowerShell environment on exit.

[`cordis.patch.yml`](cordis.patch.yml) selects the gateway, model, text input, and 1,048,576-token context capacity declared by the calling script. [`request-fields.mjs`](request-fields.mjs) contributes `chat_template_kwargs`, `enable_web_search`, and `priority` through the existing DeepSeek request-extension registry. The native adapter continues to serialize messages, stream usage, and tool calls. Low/high reasoning selections map to 20, max to 100, and off to `enable_thinking: false`; title requests remain off.

The overlay disables official DeepSeek session uploads, package inventory uploads, and the separate official search provider. Gateway search uses `enable_web_search`; the standard URL fetch tool remains available. Title and compaction requests always use gateway search `off`. Image input is not declared. Saved model selections and settings retain Harness's normal precedence over startup defaults.

<a id="verification"></a>
## Verification

Run the keyless plugin tests after building:

```powershell
node --test apps/cli/config/examples/kanai/request-fields.test.mjs
```

The tests load the plugin through Cordis Loader and check mode mapping, auxiliary-request search policy, unrelated models, configuration validation, and effect disposal. The headless command above should return `FINAL_CONNECTION_OK` when the gateway accepts the configured key. HTTP 401 or 403 indicates an authentication or access failure; check the key and account permissions. A certificate error requires the gateway's trusted CA file. Local verification records, session data, and browser authentication tokens are not included in the repository.
