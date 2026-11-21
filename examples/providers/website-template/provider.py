#!/usr/bin/env python3
"""Template: a provider plugin for a chat website that has no public API.

Anvil opens the site's login page (auth.loginURL in anvil-provider.json), waits until the
localStorage keys or cookies you listed exist, and passes them to this program in
request["credentials"]. Your job is only to turn Anvil's messages into the site's own request
and stream the answer back. Find the site's endpoints in your browser's DevTools (Network tab).

Only uses the standard library, so it runs with the python3 that ships with macOS.
"""
import json
import sys
import urllib.error
import urllib.request

SITE = "https://chat.example.com"          # change me


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def fold(messages):
    """Many chat sites take a single prompt rather than a message list."""
    if len(messages) == 1:
        return messages[0]["content"]
    parts = [messages[0]["content"], "\nCONVERSATION SO FAR"]
    for m in messages[1:]:
        parts.append(("[assistant]\n" if m["role"] == "assistant" else "[user]\n") + m["content"])
    return "\n".join(parts)


def chat(request):
    token = request["credentials"].get("localStorage", {}).get("token", "")
    if not token:
        return emit({"type": "error", "code": "unauthorized", "message": "not signed in"})

    # Replace this with the site's real request (URL, headers, body shape).
    body = {"model": request["model"], "messages": request["messages"], "stream": True}
    req = urllib.request.Request(f"{SITE}/api/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                                          "Accept": "text/event-stream"})
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            for raw in resp:                     # server-sent events, one "data:" line per chunk
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                chunk = json.loads(data)
                delta = chunk.get("choices", [{}])[0].get("delta", {}).get("content")
                if delta:
                    emit({"type": "delta", "text": delta})
    except urllib.error.HTTPError as e:
        code = {401: "unauthorized", 403: "unauthorized", 429: "rate_limited", 413: "too_long"}.get(e.code, "upstream")
        return emit({"type": "error", "code": code, "message": f"HTTP {e.code}"})
    emit({"type": "done"})


def main():
    request = json.loads(sys.stdin.readline())
    if request.get("type") == "models":
        return emit({"type": "models", "models": [{"id": "default"}]})
    if request.get("type") == "chat":
        return chat(request)
    emit({"type": "error", "code": "upstream", "message": "unknown request"})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        emit({"type": "error", "code": "upstream", "message": str(e)})
