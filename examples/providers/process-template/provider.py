#!/usr/bin/env python3
"""A minimal Anvil provider plugin (protocol 1).

Anvil starts this program once per request, writes ONE JSON line to stdin, and reads JSON lines
from stdout until it sees "done" or "error". Print nothing else to stdout (use stderr for logs).

Requests:
  {"type": "models", "credentials": {...}}
      -> {"type": "models", "models": [{"id": "echo-1", "vision": false, "context": 8000}]}
  {"type": "chat", "model": "echo-1", "messages": [{"role": "user", "content": "..."}],
   "stream": true, "stop": [...], "max_tokens": 1000, "credentials": {...}}
      -> {"type": "delta", "text": "..."}   (any number, while streaming)
      -> {"type": "done", "usage": {"prompt": 12, "completion": 34}}
  Any request can end with {"type": "error", "code": "unauthorized" | "rate_limited" | "too_long" | "upstream",
  "message": "..."}.

credentials holds what the user set up in Anvil: {"apiKey": "..."} for apiKey auth, or
{"cookies": {...}, "localStorage": {...}} for web sign-in. A "done" event may include
{"credentials": {"cookies": {...}}} to save cookies the site rotated.

This example "answers" by echoing the request back in Anvil's reply format, so you can try the
whole round trip without any account. Replace answer() with a call to the service you're adding.
"""
import json
import sys


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def answer(messages, model, credentials):
    """Return the model's reply text. This is where a real plugin calls its service."""
    last = messages[-1]["content"] if messages else ""
    first_line = last.strip().splitlines()[-1] if last.strip() else "(empty)"
    reply = {"say": f"Echo from {model}: {first_line[:200]}", "done": True}
    return "Echoing the request.\n```json\n" + json.dumps(reply) + "\n```"


def main():
    request = json.loads(sys.stdin.readline())
    kind = request.get("type")
    creds = request.get("credentials", {})

    if kind == "models":
        emit({"type": "models", "models": [{"id": "echo-1", "context": 8000}]})
        return

    if kind == "chat":
        text = answer(request.get("messages", []), request.get("model", ""), creds)
        if request.get("stream"):
            for i in range(0, len(text), 24):           # stream in small pieces
                emit({"type": "delta", "text": text[i:i + 24]})
        else:
            emit({"type": "delta", "text": text})
        prompt_chars = sum(len(m.get("content", "")) for m in request.get("messages", []))
        emit({"type": "done", "usage": {"prompt": prompt_chars // 4, "completion": len(text) // 4}})
        return

    emit({"type": "error", "code": "upstream", "message": f"unknown request type {kind!r}"})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # report failures to Anvil instead of a bare exit code
        emit({"type": "error", "code": "upstream", "message": str(e)})
