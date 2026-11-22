# Adding a model provider

Anvil can use any model provider described by an **`anvil-provider.json`** file. There are two kinds:

| Kind | Use it when | You write |
|---|---|---|
| `"openai"` | the service has an OpenAI-compatible chat API (most do: Z.ai, OpenRouter, Groq, DeepSeek, Mistral, Ollama, LM Studio, vLLM…) | one JSON file, no code |
| `"process"` | anything else: a chat website with no public API, an unusual protocol, local tooling | the JSON file plus a small program in any language |

Users add providers in **Settings → Provider → More providers → Add provider**, from a preset, a GitHub URL, or a folder. Models show up in the model menu as `<id>/<model>`, for example `zai/glm-4.6`.

- [A no-code provider in one file](#a-no-code-provider-in-one-file)
- [A provider that needs code](#a-provider-that-needs-code)
- [Website sign-in](#website-sign-in)
- [Publishing on GitHub](#publishing-on-github)
- [Reference](#reference)

## A no-code provider in one file

This is the whole Z.ai provider ([examples/providers/zai](../examples/providers/zai/anvil-provider.json)):

```json
{
  "spec": 1,
  "id": "zai",
  "name": "Z.ai",
  "type": "openai",
  "baseURL": "https://api.z.ai/api/paas/v4",
  "auth": { "type": "apiKey", "keyURL": "https://z.ai/manage-apikey/apikey-list" },
  "models": [
    { "id": "glm-4.6", "context": 200000 },
    { "id": "glm-4.5v", "vision": true }
  ],
  "capabilities": { "stop": false }
}
```

- **`baseURL`** is the API root, the same one you'd give an OpenAI SDK. Anvil calls `baseURL/chat/completions` and lists models at `baseURL/models` (both paths can be changed with `chatPath` and `modelsPath`).
- **`auth`**: `"apiKey"` shows a key field in Settings and sends `Authorization: Bearer <key>`. Use `header` and `prefix` for services that want something else, such as `{"type": "apiKey", "header": "x-api-key", "prefix": ""}`.
- **`models`** are shown before the live list arrives, and they add what a `/models` endpoint usually doesn't say: `vision`, `context`, and prices (`input`/`output` in USD per million tokens) for the cost meter.
- **`capabilities`** describe the API's quirks. The ones that matter most:
  - `stop: false` if the API rejects or ignores `stop` sequences. Anvil then ends the stream itself when the reply is complete. When unsure, use `false`; it always works.
  - `reasoningEffort: true` if it accepts `reasoning_effort`.
  - `maxTokensField: "max_completion_tokens"` for APIs that renamed it.

### Bringing a local server

Many community projects turn a chat website into an OpenAI-style API that runs as a small server. A plugin can ship that server and have Anvil run it **on the user's Mac**, so there's nothing to deploy:

```json
"type": "openai",
"baseURL": "http://127.0.0.1:39876/v1",
"server": {
  "setup": ["sh", "setup.sh"],
  "command": ["sh", "start.sh"],
  "env": { "PORT": "39876" },
  "ready": "http://127.0.0.1:39876/",
  "startupTimeout": 120
}
```

- **`setup`** runs once from the plugin's folder (and again if the spec or the setup script changes): typically clone the upstream project at a pinned commit and `npm install`. Its output goes to `.anvil-server.log`.
- **`command`** starts the server. Anvil runs it the first time one of the provider's models is used, waits until **`ready`** (a localhost URL) answers, and stops it when Anvil quits. Settings shows its state, with Start, Stop and the log.
- `baseURL` and `ready` must be localhost. Make the server listen on `127.0.0.1` only, so nobody else on the network can use it.
- `body` adds request fields the server understands (for example `{"enable_thinking": false}`), and `"editableBaseURL": true` lets people point the plugin at a copy they host elsewhere instead.

[deeeeone/anvil-provider-qwen2api](https://github.com/deeeeone/anvil-provider-qwen2api), [deeeeone/anvil-provider-zai-proxy](https://github.com/deeeeone/anvil-provider-zai-proxy) and [deeeeone/anvil-provider-kimi](https://github.com/deeeeone/anvil-provider-kimi) are complete examples. They download the upstream project during setup instead of copying it, which keeps the plugin small and respects the upstream's license.

To try it, save the file in a folder and pick **Add provider → From a folder**. Edit, then click **Reload**.

## A provider that needs code

Set `"type": "process"` and give a `command`. For every request, Anvil runs the command from the plugin's folder, writes **one JSON line** to its stdin, and reads **JSON lines** from its stdout until it sees `done` or `error`.

```json
{ "spec": 1, "id": "echo", "name": "Echo", "type": "process",
  "command": ["python3", "provider.py"], "auth": { "type": "none" }, "models": [{ "id": "echo-1" }] }
```

**Requests from Anvil:**

```jsonc
// list models
{"type": "models", "protocol": 1, "credentials": {}}

// one reply
{"type": "chat", "protocol": 1, "model": "echo-1", "stream": true,
 "messages": [{"role": "user", "content": "…"}, {"role": "assistant", "content": "…"}],
 "stop": ["<observation"], "max_tokens": 4000, "effort": "high",
 "credentials": {"apiKey": "…"}}
```

Images, when the model has `"vision": true`, come as `"images": [{"mime": "image/png", "data": "<base64>"}]` on a message.

**Events your program prints:**

```jsonc
{"type": "models", "models": [{"id": "echo-1", "vision": false, "context": 8000}]}
{"type": "delta", "text": "partial reply text"}                  // as many as you like
{"type": "done", "usage": {"prompt": 120, "completion": 40}}     // ends a chat request
{"type": "error", "code": "unauthorized", "message": "session expired"}
```

Error codes: `unauthorized` (Anvil asks the user to sign in again), `rate_limited` (Anvil backs off and retries), `too_long`, `upstream` (anything else). Print logs to **stderr**, never stdout. Anvil ignores stdout lines that aren't JSON, but an unexpected JSON line could be mistaken for an event.

[examples/providers/process-template](../examples/providers/process-template) is a complete, working plugin in about 60 lines of Python, with only the standard library. Copy it and replace `answer()`.

## Website sign-in

For services you use through a website (the case of chat sites such as chat.z.ai, which have no public API for their web chat), let Anvil handle the sign-in:

```json
"auth": {
  "type": "web",
  "loginURL": "https://chat.example.com/login",
  "domain": "chat.example.com",
  "localStorage": ["token"],
  "cookies": ["session"]
}
```

**Sign in…** in Settings opens `loginURL` in a private browser window. As soon as the listed localStorage keys and cookies exist for `domain`, Anvil saves them in the Keychain and closes the window. Only values for that domain are kept. They reach your program as:

```json
"credentials": {"cookies": {"session": "…"}, "localStorage": {"token": "…"}}
```

If the site rotates cookies, return them in `done` (`{"type": "done", "credentials": {"cookies": {…}}}`) and Anvil saves them.

Some sites accept the web token as a bearer key on an OpenAI-compatible endpoint. Then you don't need code at all: use `"type": "openai"` with `"bearer": "localStorage:token"` (or `"cookie:<name>"`).

[examples/providers/website-template](../examples/providers/website-template) is a starting point. Find the site's real request in your browser's DevTools (Network tab, send a message, look for the streaming request) and adapt `chat()` to it.

> Respect the service's terms. Unofficial clients can get accounts limited, so say so in your plugin's README.

## Publishing on GitHub

1. Put `anvil-provider.json` (and your program, for process plugins) at the root of a repository, or in a folder of one.
2. Add a README saying what the provider is, what it needs (an API key, a sign-in, `python3`…), and what it sends where.
3. Tag the repository with the **`anvil-provider`** topic so others can find it.

Users install it by pasting the URL: `https://github.com/you/anvil-zai-web`, or `https://github.com/you/plugins/tree/main/zai-web` for a folder. Before anything is installed, Anvil shows what the plugin does: which host an `openai` plugin talks to, or the exact command a `process` plugin runs, with a warning that it runs code. Updates show the same confirmation again.

## Reference

The [JSON Schema](anvil-provider.schema.json) validates the file in editors that support it. Add `"$schema": "https://raw.githubusercontent.com/deeeeone/Anvil/main/docs/anvil-provider.schema.json"` at the top.

| Field | Type | Notes |
|---|---|---|
| `spec` | number | `1` |
| `id` | string | 2-32 lowercase letters, digits, dashes; unique; the model prefix. Can't be a built-in name (`chatgpt`, `gemini`, `luna`, `experiential`, `anvil`, `builtin`, `local`). |
| `name` | string | shown in menus and Settings |
| `description`, `homepage` | string | optional |
| `symbol` | string | an [SF Symbol](https://developer.apple.com/sf-symbols/) name; default `cpu` |
| `type` | `"openai"` \| `"process"` | |
| `baseURL` | string | openai: https, or http for localhost |
| `chatPath`, `modelsPath` | string | relative to baseURL; defaults `chat/completions`, `models`; `""` turns listing off |
| `headers` | object | extra headers on every request |
| `body` | object | extra fields merged into every chat request body |
| `server` | object | openai: a local server Anvil runs: `setup`, `command`, `env`, `ready` (localhost URL), `startupTimeout`, `setupTimeout` |
| `editableBaseURL` | bool | Settings shows a server URL field (for self-hosted proxies people deploy themselves) |
| `command` | [string] | process: run from the plugin folder, resolved on `PATH` |
| `auth.type` | `"none"` \| `"apiKey"` \| `"web"` | |
| `auth.header`, `auth.prefix` | string | apiKey: default `Authorization` and `Bearer ` |
| `auth.label`, `auth.keyURL` | string | apiKey: field label, where to get a key |
| `auth.optional` | bool | apiKey: the key may be left empty |
| `auth.loginURL`, `auth.domain` | string | web: required |
| `auth.cookies`, `auth.localStorage` | [string] | web: what "signed in" means (at least one of them) |
| `auth.bearer` | string | web + openai: `localStorage:<key>` or `cookie:<name>` |
| `auth.manual` | bool | web: wait for the owner to click "I'm signed in" instead of saving as soon as guest values exist |
| `models[]` | object | `id` (required), `name`, `vision`, `context`, `input`, `output` |
| `capabilities` | object | `stop` (default true), `reasoningEffort` (false), `streaming` (true), `streamUsage` (true), `maxTokensField` (`max_tokens`) |
| `free` | bool | shows "free" and records no cost |

Installed plugins live in `~/Library/Application Support/Anvil/providers/<id>/`. Keys and sessions are in the Keychain under `provider.<id>.key` and `provider.<id>.session`.
