#!/usr/bin/env python3
"""Small, dependency-free smoke test for the bundled Codex App Server."""

import json
import select
import subprocess
import sys
import time
from pathlib import Path


EXECUTABLE = Path("/Applications/ChatGPT.app/Contents/Resources/codex")


def send(process, identifier, method, params):
    message = {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def read_messages(process, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0, deadline - time.monotonic())
        ready, _, _ = select.select([process.stdout], [], [], min(0.5, remaining))
        if not ready:
            continue
        line = process.stdout.readline()
        if not line:
            break
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def main():
    if not EXECUTABLE.is_file():
        print(f"Codex App Server executable not found: {EXECUTABLE}", file=sys.stderr)
        return 1

    process = subprocess.Popen(
        [
            str(EXECUTABLE),
            "app-server",
            "--stdio",
            "-c",
            "features.shell_tool=false",
            "-c",
            "features.apps=false",
            "-c",
            "web_search=disabled",
            "-c",
            "features.multi_agent=false",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    try:
        send(process, 1, "initialize", {
            "clientInfo": {"name": "ducky-access-smoke-test", "title": "Ducky Access", "version": "0.1.0"},
            "capabilities": {"experimentalApi": True, "requestAttestation": False, "optOutNotificationMethods": []},
        })
        initialized = next((m for m in read_messages(process) if m.get("id") == 1), None)
        if not initialized or "error" in initialized:
            print("initialize failed", file=sys.stderr)
            return 1
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
        process.stdin.flush()

        send(process, 2, "thread/start", {
            "ephemeral": True,
            "model": "gpt-5.6-luna",
            "serviceTier": "default",
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "environments": [],
        })
        started = next((m for m in read_messages(process) if m.get("id") == 2), None)
        thread = (started or {}).get("result", {}).get("thread", {})
        thread_id = thread.get("id")
        if not thread_id:
            print(f"thread/start failed: {started}", file=sys.stderr)
            return 1

        schema = {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": False,
        }
        send(process, 3, "turn/start", {
            "threadId": thread_id,
            "input": [{"type": "text", "text": 'Return JSON only in the exact shape {"text":"bridge smoke test passed"}.'}],
            "model": "gpt-5.6-luna",
            "effort": "low",
            "serviceTierForTurn": "default",
            "outputSchema": schema,
            "environments": [],
        })

        turn_response = next((m for m in read_messages(process) if m.get("id") == 3), None)
        if not turn_response or "error" in turn_response:
            print(f"turn/start failed: {turn_response}", file=sys.stderr)
            return 1
        turn_id = turn_response.get("result", {}).get("turn", {}).get("id")
        if not turn_id:
            print(f"turn/start returned no turn id: {turn_response}", file=sys.stderr)
            return 1

        final_text = None
        for message in read_messages(process):
            if message.get("method") == "item/completed":
                params = message.get("params", {})
                item = params.get("item", {})
                if params.get("turnId") == turn_id and item.get("type") == "agentMessage" and item.get("phase") == "final_answer":
                    final_text = item.get("text")
                    break
            if message.get("method") == "turn/completed":
                params = message.get("params", {})
                if params.get("turnId") == turn_id:
                    items = params.get("turn", {}).get("items", [])
                    final_text = "\n".join(item.get("text", "") for item in items if item.get("type") == "agentMessage")
                    break

        if not final_text:
            print("No final agent message received", file=sys.stderr)
            return 1
        decoded = json.loads(final_text)
        if decoded.get("text") != "bridge smoke test passed":
            print(f"Unexpected final text: {final_text}", file=sys.stderr)
            return 1
        print(f"Codex App Server verified: {decoded['text']}")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
