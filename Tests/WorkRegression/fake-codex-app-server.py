#!/usr/bin/env python3
"""Codex App Server 协议替身：只实现 ClaudePicker 用到的子集（codex-cli 0.170 v2 形态）。

- `codex app-server --listen stdio://`：按行收发 JSON-RPC（不带 jsonrpc 头）。
- initialize → initialized；thread/start、thread/resume；turn/start 流式回复；turn/interrupt。
- 提示词含 "approve" 时先发命令审批请求，按答复执行或拒绝。
- 提示词含 "slow" 时一直等到 turn/interrupt。
每条收到的消息追加写入 FAKE_CODEX_LOG，供回归断言。
"""
import json
import os
import sys
import threading
import uuid

LOG = os.environ.get("FAKE_CODEX_LOG")
lock = threading.Lock()
state = {"thread": None, "turn": None, "approval": None, "pending_turn": None}


def log(entry):
    if LOG:
        with open(LOG, "a") as handle:
            handle.write(json.dumps(entry, separators=(",", ":"), ensure_ascii=False) + "\n")


def send(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def note(method, params):
    send({"method": method, "params": params})


def complete_turn(status, text=None):
    thread, turn = state["thread"], state["turn"]
    if turn is None:
        return
    if text:
        item = "msg-" + uuid.uuid4().hex[:8]
        note("item/started", {"threadId": thread, "turnId": turn, "item": {"type": "agentMessage", "id": item, "text": ""}})
        for chunk in (text[: len(text) // 2], text[len(text) // 2 :]):
            note("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": item, "delta": chunk})
        note("item/completed", {"threadId": thread, "turnId": turn, "item": {"type": "agentMessage", "id": item, "text": text}})
    note("turn/completed", {"threadId": thread, "turn": {"id": turn, "status": status, "error": None, "durationMs": 12, "items": []}})
    state["turn"] = None


def run_command(approved):
    thread, turn = state["thread"], state["turn"]
    item = {"type": "commandExecution", "id": "cmd-1", "command": "ls", "cwd": os.getcwd(), "status": "inProgress"}
    note("item/started", {"threadId": thread, "turnId": turn, "item": item})
    done = dict(item, status="completed" if approved else "declined", aggregatedOutput="file.txt\n" if approved else None,
                exitCode=0 if approved else None)
    note("item/completed", {"threadId": thread, "turnId": turn, "item": done})
    complete_turn("completed", "命令已执行" if approved else "命令被拒绝")


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "app-server":
        print("fake codex: only app-server is supported", file=sys.stderr)
        sys.exit(2)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        log(msg)
        method = msg.get("method")
        rid = msg.get("id")
        params = msg.get("params") or {}
        if method == "initialize":
            send({"id": rid, "result": {"userAgent": "fake-codex/0.170.0", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos"}})
        elif method == "initialized":
            pass
        elif method in ("thread/start", "thread/resume"):
            if method == "thread/resume":
                if params.get("threadId") == "missing-thread":
                    send({"id": rid, "error": {"code": -32600, "message": "thread not found"}})
                    continue
                state["thread"] = params["threadId"]
            else:
                state["thread"] = "fake-thread-" + uuid.uuid4().hex[:8]
            send({"id": rid, "result": {"thread": {"id": state["thread"]}, "model": "gpt-fake", "approvalPolicy": params.get("approvalPolicy"),
                                        "cwd": params.get("cwd") or os.getcwd(), "sandbox": {"type": params.get("sandbox")}}})
            note("thread/started", {"thread": {"id": state["thread"]}})
        elif method == "turn/start":
            turn = "turn-" + uuid.uuid4().hex[:8]
            state["turn"] = turn
            send({"id": rid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
            note("turn/started", {"threadId": state["thread"], "turn": {"id": turn, "status": "inProgress"}})
            text = "".join(part.get("text", "") for part in params.get("input", []))
            if "approve" in text:
                state["approval"] = 900
                send({"id": 900, "method": "item/commandExecution/requestApproval",
                      "params": {"threadId": state["thread"], "turnId": turn, "itemId": "cmd-1", "command": "ls", "reason": "列出文件"}})
            elif "slow" in text:
                pass
            else:
                complete_turn("completed", "收到：" + text)
        elif method == "turn/interrupt":
            send({"id": rid, "result": {}})
            complete_turn("interrupted")
        elif rid is not None and rid == state["approval"] and "result" in msg:
            state["approval"] = None
            decision = msg["result"].get("decision")
            if decision == "cancel":
                continue
            run_command(decision in ("accept", "acceptForSession", "approved"))
        elif rid is not None and method:
            send({"id": rid, "error": {"code": -32601, "message": "unsupported " + method}})


if __name__ == "__main__":
    main()
