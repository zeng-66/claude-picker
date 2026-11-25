#!/usr/bin/env python3
"""Work 回归测试用的 Antigravity CLI (`agy`) 协议替身。

支持：
- `agy models`：输出与真实 `agy 1.5.10` 一致的 TSV 模型列表；
- `agy acp`：运行标准 JSON-RPC 2.0 ACP stdio 服务，处理 `initialize`、`session/new`、
  `session/load`（找不到旧会话时返回 -32602 测试自动回退）、`session/set_mode`、
  `session/set_model`、`session/prompt`（发送 `session/update` 流式分片与工具事件）、
  `session/request_permission` 双向审批以及 `session/cancel` 中断。
不访问网络，不调用真实智能体。
"""
import json
import os
import queue
import sys
import threading
import time
import uuid

args = sys.argv[1:]

if args and args[0] == "models":
    sys.stdout.write(
        "gemini-4-carbon-high\tGemini 4 Carbon (High)\n"
        "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n"
    )
    sys.exit(0)

if not args or args[0] != "acp":
    sys.stderr.write(f"fake-agy: unsupported args {args}\n")
    sys.exit(2)

state_dir = os.environ.get("FAKE_AGY_STATE", "/tmp")
log_path = os.environ.get("FAKE_AGY_LOG")
os.makedirs(state_dir, exist_ok=True)

out_lock = threading.Lock()
current_session_id = [None]


def log(record):
    if not log_path:
        return
    record["pid"] = os.getpid()
    record["session"] = current_session_id[0]
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


log({"event": "spawn", "argv": args, "cwd": os.getcwd()})

incoming = queue.Queue()
permission_replies = {}
cancelled = threading.Event()
prompt_queue = queue.Queue()
perm_seq = [100]


def reader():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            incoming.put(json.loads(line))
        except Exception:
            pass
    incoming.put(None)


threading.Thread(target=reader, daemon=True).start()


def dispatcher():
    while True:
        msg = incoming.get()
        if msg is None:
            prompt_queue.put(None)
            return
        method = msg.get("method")
        rpc_id = msg.get("id")
        params = msg.get("params") or {}

        # Client response to server-initiated session/request_permission
        if method is None and rpc_id is not None:
            outcome = (msg.get("result") or {}).get("outcome") or {}
            log({"event": "permission_reply", "id": rpc_id, "outcome": outcome})
            permission_replies[rpc_id] = outcome
            continue

        if method == "initialize":
            log({"event": "initialize", "id": rpc_id})
            emit({
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "protocolVersion": 1,
                    "agentCapabilities": {"loadSession": True},
                    "agentInfo": {"name": "antigravity-acp-fake", "version": "1.5.10-fake"},
                },
            })
        elif method == "session/new":
            sid = str(uuid.uuid4())
            current_session_id[0] = sid
            open(os.path.join(state_dir, f"{sid}.session"), "w", encoding="utf-8").write("created\n")
            log({"event": "session_new", "sessionId": sid})
            emit({
                "jsonrpc": "2.0",
                "id": rpc_id,
                "result": {
                    "sessionId": sid,
                    "modes": {
                        "currentModeId": "agent",
                        "availableModes": [
                            {"id": "agent", "name": "Agent"},
                            {"id": "plan", "name": "Plan"},
                            {"id": "ask", "name": "Ask"},
                        ],
                    },
                    "models": {
                        "currentModelId": "gemini-4-carbon-high",
                        "availableModels": [
                            {"modelId": "gemini-4-carbon-high", "name": "Gemini 4 Carbon (High)"},
                            {"modelId": "gemini-3-flash", "name": "Gemini 3 Flash"},
                        ],
                    },
                },
            })
        elif method == "session/load":
            sid = params.get("sessionId") or ""
            session_file = os.path.join(state_dir, f"{sid}.session")
            if not sid or not os.path.exists(session_file):
                log({"event": "session_load_missing", "sessionId": sid})
                emit({
                    "jsonrpc": "2.0",
                    "id": rpc_id,
                    "error": {"code": -32602, "message": f"session {sid} not found"},
                })
            else:
                current_session_id[0] = sid
                log({"event": "session_load", "sessionId": sid})
                emit({
                    "jsonrpc": "2.0",
                    "id": rpc_id,
                    "result": {
                        "sessionId": sid,
                        "modes": {"currentModeId": "agent"},
                        "models": {"currentModelId": "gemini-4-carbon-high"},
                    },
                })
        elif method in ("session/set_mode", "session/set_model"):
            log({"event": method, "params": params})
            emit({"jsonrpc": "2.0", "id": rpc_id, "result": {}})
        elif method == "session/cancel":
            log({"event": "cancel", "sessionId": params.get("sessionId")})
            cancelled.set()
        elif method == "session/prompt":
            blocks = params.get("prompt") or []
            text = "".join(b.get("text", "") for b in blocks if isinstance(b, dict))
            log({"event": "prompt", "text": text})
            prompt_queue.put((rpc_id, text))
        else:
            if rpc_id is not None:
                emit({
                    "jsonrpc": "2.0",
                    "id": rpc_id,
                    "error": {"code": -32601, "message": f"Unknown method {method}"},
                })


threading.Thread(target=dispatcher, daemon=True).start()


def scenario_of(text):
    # 使用最后一次出现的 SCENARIO:，方便跨引擎 Handoff 时第二轮指定新场景而不被第一轮前情里的标记干扰
    marker = "SCENARIO:"
    if marker not in text:
        return "plain"
    rest = text.rsplit(marker, 1)[1]
    name = ""
    for ch in rest:
        if ch.isalnum() or ch in "-_":
            name += ch
        else:
            break
    return name or "plain"


def send_update(update):
    emit({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": current_session_id[0],
            "update": update,
        },
    })


def request_permission(tool_id, title, raw_input):
    perm_seq[0] += 1
    req_id = perm_seq[0]
    emit({
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "session/request_permission",
        "params": {
            "sessionId": current_session_id[0],
            "toolCall": {
                "toolCallId": tool_id,
                "title": title,
                "kind": "edit",
                "rawInput": raw_input,
            },
            "options": [
                {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
            ],
        },
    })
    while req_id not in permission_replies:
        if cancelled.is_set():
            return None
        time.sleep(0.02)
    return permission_replies[req_id]


while True:
    item = prompt_queue.get()
    if item is None:
        break
    rpc_id, text = item
    cancelled.clear()
    scenario = scenario_of(text)
    log({"event": "turn", "scenario": scenario})

    if scenario == "edit":
        out_file = os.path.join(os.getcwd(), "agy-output.txt")
        send_update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call_agy_write",
            "title": "Write",
            "kind": "edit",
            "status": "in_progress",
            "rawInput": {"file_path": out_file, "content": "generated by fake agy acp\n"},
        })
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("generated by fake agy acp\n")
        send_update({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "call_agy_write",
            "title": "Write",
            "status": "completed",
            "content": "Wrote agy-output.txt",
        })
        send_update({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "Antigravity 已写入 agy-output.txt。"},
        })
        emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
    elif scenario == "permission":
        guarded = os.path.join(os.getcwd(), "agy-guarded.txt")
        raw_input = {"file_path": guarded, "content": "approved via acp\n"}
        send_update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call_agy_perm",
            "title": "Write",
            "kind": "edit",
            "status": "pending",
            "rawInput": raw_input,
        })
        outcome = request_permission("call_agy_perm", "Write", raw_input)
        if outcome is None or outcome.get("outcome") == "cancelled":
            emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "cancelled"}})
        elif outcome.get("optionId") == "allow_once":
            with open(guarded, "w", encoding="utf-8") as f:
                f.write("approved via acp\n")
            send_update({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "call_agy_perm",
                "title": "Write",
                "status": "completed",
                "content": "Wrote agy-guarded.txt",
            })
            send_update({
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "已获批准并写入 agy-guarded.txt。"},
            })
            emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
        else:
            send_update({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "call_agy_perm",
                "title": "Write",
                "status": "failed",
                "content": "Permission denied",
            })
            send_update({
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "权限已拒绝，未写入文件。"},
            })
            emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
    elif scenario == "slow":
        send_update({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "Antigravity 正在执行长耗时任务…"},
        })
        deadline = time.time() + 30.0
        while time.time() < deadline and not cancelled.is_set():
            time.sleep(0.02)
        if cancelled.is_set():
            emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "cancelled"}})
        else:
            emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})
    else:
        send_update({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "Antigravity 收到：" + text[:60]},
        })
        emit({"jsonrpc": "2.0", "id": rpc_id, "result": {"stopReason": "end_turn"}})

log({"event": "exit"})
