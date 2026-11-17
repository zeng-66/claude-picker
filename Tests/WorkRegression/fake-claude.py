#!/usr/bin/env python3
"""Work 回归测试用的 Claude CLI 替身。

只实现执行器依赖的那部分 stream-json 协议，消息形态取自 CLI 2.1.325 的实测记录：
initialize 握手、每轮开始的 system/init、assistant / user(tool_result)、can_use_tool 控制请求、
interrupt、result。行为由用户消息里的 `SCENARIO:<名字>` 指令决定。不访问网络，不调用真实 Claude。
"""
import json
import os
import sys
import time
import threading
import queue

args = sys.argv[1:]

# 一次性的结构化理解调用（企业微信机器人用来判断消息意图）：按消息内容给出确定的结果。
if "--json-schema" in args:
    prompt = args[-1]
    message = prompt.split("<message>", 1)[-1].split("</message>", 1)[0].strip()
    try:
        index = json.loads(prompt.split("# 项目索引", 1)[1].split("# 上下文", 1)[0])
    except Exception:
        index = {"projects": []}
    try:
        context = json.loads(prompt.split("# 上下文（这个会话已有的 Work 与待澄清的意图）", 1)[1].split("# 消息", 1)[0])
    except Exception:
        context = {"works": [], "openIntents": []}
    log_path = os.environ.get("FAKE_CLAUDE_LOG")
    if log_path:
        with open(log_path, "a") as f:
            f.write(json.dumps({"event": "intent", "message": message, "tools": args[args.index("--tools") + 1] if "--tools" in args else None}, ensure_ascii=False) + "\n")
    if isinstance(index, list):
        index = {"projects": index}
    elif not isinstance(index, dict):
        index = {"projects": []}
    named = [p for p in index.get("projects", []) if isinstance(p, dict) and p.get("name") and p["name"] in message]
    if "进度" in message:
        out = {"kind": "chat", "reply": "目前有 %d 个 Work" % len(context.get("works", []))}
    elif context.get("openIntents") and named:
        out = {"kind": "clarify_reply", "reply": "好的", "intentId": context["openIntents"][0]["intentId"],
               "objective": context["openIntents"][0]["objective"], "projectId": named[0]["projectId"],
               "resolution": "resolved", "evidence": ["回复里写明了 " + named[0]["name"]]}
    elif len(named) == 1:
        out = {"kind": "work", "reply": "好的", "objective": message, "title": message[:20],
               "projectId": named[0]["projectId"], "resolution": "resolved", "evidence": ["消息里写明了 " + named[0]["name"]]}
    elif "帮我" in message:
        out = {"kind": "work", "reply": "需要确认项目", "objective": message, "resolution": "needs_clarification",
               "question": "要在哪个项目里处理？"}
    else:
        out = {"kind": "chat", "reply": "你好"}
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "structured_output": out}, ensure_ascii=False))
    sys.exit(0)

session_id = None
resume = False
for i, a in enumerate(args):
    if a == "--session-id":
        session_id = args[i + 1]
    if a == "--resume":
        session_id = args[i + 1]
        resume = True

state_dir = os.environ.get("FAKE_CLAUDE_STATE", "/tmp")
log_path = os.environ.get("FAKE_CLAUDE_LOG")
session_file = os.path.join(state_dir, f"{session_id}.session")


def log(record):
    if not log_path:
        return
    record["pid"] = os.getpid()
    record["session"] = session_id
    with open(log_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


log({"event": "spawn", "argv": args, "cwd": os.getcwd(), "resume": resume})

if resume and not os.path.exists(session_file):
    sys.stderr.write(f"No conversation found with session ID: {session_id}\n")
    log({"event": "resume-missing"})
    sys.exit(1)

if os.environ.get("FAKE_CLAUDE_EXIT_ON_START"):
    sys.stderr.write("fake startup failure\n")
    sys.exit(7)

out_lock = threading.Lock()


def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def emit_raw(data):
    with out_lock:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


incoming = queue.Queue()
eof = threading.Event()


def reader():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            incoming.put(json.loads(line))
        except Exception:
            pass
    eof.set()
    incoming.put(None)


threading.Thread(target=reader, daemon=True).start()

control_responses = {}
interrupted = threading.Event()
user_messages = queue.Queue()
request_counter = [0]


def dispatcher():
    while True:
        msg = incoming.get()
        if msg is None:
            user_messages.put(None)
            return
        kind = msg.get("type")
        if kind == "control_request":
            rid = msg.get("request_id")
            sub = msg.get("request", {}).get("subtype")
            log({"event": "control_request", "subtype": sub, "request_id": rid})
            if sub == "initialize":
                if os.environ.get("FAKE_CLAUDE_NO_HANDSHAKE"):
                    continue
                emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                                                                "response": {"commands": []}}})
            elif sub == "interrupt":
                interrupted.set()
                emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid,
                                                                "response": {"still_queued": []}}})
            else:
                emit({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        elif kind == "control_response":
            response = msg.get("response", {})
            log({"event": "control_response", "request_id": response.get("request_id"),
                 "behavior": response.get("response", {}).get("behavior")})
            control_responses[response.get("request_id")] = response.get("response", {})
        elif kind == "user":
            text = "".join(b.get("text", "") for b in msg.get("message", {}).get("content", []) if b.get("type") == "text")
            log({"event": "user", "text": text})
            user_messages.put(text)


threading.Thread(target=dispatcher, daemon=True).start()


def ask_permission(tool, tool_input, interaction=False):
    request_counter[0] += 1
    rid = f"req-{os.getpid()}-{request_counter[0]}"
    request = {"subtype": "can_use_tool", "tool_name": tool, "display_name": tool, "input": tool_input,
               "tool_use_id": f"toolu_{rid}"}
    if interaction:
        request["requires_user_interaction"] = True
    emit({"type": "control_request", "request_id": rid, "request": request})
    while rid not in control_responses:
        if interrupted.is_set():
            return None
        time.sleep(0.02)
    return control_responses[rid]


def assistant(blocks):
    emit({"type": "assistant", "message": {"role": "assistant", "content": blocks},
          "parent_tool_use_id": None, "session_id": session_id})


def tool_result(tool_use_id, content, is_error=False):
    emit({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool_use_id, "content": content, "is_error": is_error}]},
        "parent_tool_use_id": None, "session_id": session_id})


def result(text, is_error=False, subtype="success", reason="completed"):
    emit({"type": "result", "subtype": subtype, "is_error": is_error, "terminal_reason": reason,
          "stop_reason": None if is_error else "end_turn", "result": text, "num_turns": 1,
          "duration_ms": 12, "total_cost_usd": 0, "permission_denials": [], "session_id": session_id})


def scenario_of(text):
    marker = "SCENARIO:"
    if marker not in text:
        return "plain"
    rest = text.split(marker, 1)[1]
    name = ""
    for ch in rest:
        if ch.isalnum() or ch in "-_":
            name += ch
        else:
            break
    return name or "plain"


def run_turn(text):
    interrupted.clear()
    open(session_file, "a").write(text[:80].replace("\n", " ") + "\n")
    emit({"type": "system", "subtype": "init", "session_id": session_id, "model": "fake-model",
          "permissionMode": "default", "cwd": os.getcwd(), "claude_code_version": "0.0.0-fake"})
    name = scenario_of(text)
    log({"event": "turn", "scenario": name})

    if name == "edit":
        path = os.path.join(os.getcwd(), "work-output.txt")
        assistant([{"type": "tool_use", "id": "toolu_edit", "name": "Write",
                    "input": {"file_path": path, "content": "generated by fake claude\n"}}])
        with open(path, "a") as f:
            f.write("generated by fake claude\n")
        tool_result("toolu_edit", "File created successfully")
        emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                "delta": {"type": "text_delta", "text": "已完成"}},
              "parent_tool_use_id": None, "session_id": session_id})
        assistant([{"type": "text", "text": "已完成修改：新增 work-output.txt。验证：未运行。"}])
        result("已完成修改：新增 work-output.txt。验证：未运行。")
    elif name == "question":
        tool_input = {"questions": [{"question": "同步失败时如何处理本地状态？", "header": "口径",
                                     "multiSelect": False,
                                     "options": [{"label": "回滚本地操作", "description": "恢复本地状态"},
                                                 {"label": "保留并重试", "description": "记录失败后重试"}]}]}
        assistant([{"type": "tool_use", "id": "toolu_q", "name": "AskUserQuestion", "input": tool_input}])
        answer = ask_permission("AskUserQuestion", tool_input, interaction=True)
        if answer is None:
            emit({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}})
            result(None, True, "error_during_execution", "aborted_tools")
            return
        if answer.get("behavior") == "allow":
            picked = json.dumps(answer.get("updatedInput", {}).get("answers", {}), ensure_ascii=False, sort_keys=True)
            with open(os.path.join(os.getcwd(), "answer.txt"), "w") as f:
                f.write(picked + "\n")
            tool_result("toolu_q", "Your questions have been answered: " + picked)
            assistant([{"type": "text", "text": "已按你的选择处理：" + picked}])
            result("已按你的选择处理：" + picked)
        else:
            tool_result("toolu_q", answer.get("message", "denied"), True)
            result("问题被拒绝，未做修改。")
    elif name == "permission":
        path = os.path.join(os.getcwd(), "guarded.txt")
        tool_input = {"file_path": path, "content": "guarded write\n"}
        assistant([{"type": "tool_use", "id": "toolu_w", "name": "Write", "input": tool_input}])
        answer = ask_permission("Write", tool_input)
        if answer is None:
            result(None, True, "error_during_execution", "aborted_tools")
            return
        if answer.get("behavior") == "allow":
            with open(path, "w") as f:
                f.write(answer.get("updatedInput", {}).get("content", ""))
            tool_result("toolu_w", "File created successfully")
            result("已写入 guarded.txt。")
        else:
            tool_result("toolu_w", answer.get("message", "denied"), True)
            assistant([{"type": "text", "text": "写入被拒绝，没有修改文件。"}])
            result("写入被拒绝，没有修改文件。")
    elif name == "slow":
        assistant([{"type": "text", "text": "开始一个耗时的任务…"}])
        deadline = time.time() + float(os.environ.get("FAKE_CLAUDE_SLOW_SECONDS", "60"))
        while time.time() < deadline and not interrupted.is_set():
            time.sleep(0.02)
        if interrupted.is_set():
            emit({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}})
            result(None, True, "error_during_execution", "aborted_streaming")
        else:
            result("耗时任务结束。")
    elif name == "fail":
        result("API Error: simulated failure", True, "error_during_execution", "model_error")
    elif name == "crash":
        assistant([{"type": "text", "text": "即将异常退出"}])
        sys.stderr.write("fake fatal error: boom\n")
        sys.stderr.flush()
        os._exit(3)
    elif name == "multibyte":
        line = (json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "多字节字符切包测试：订单批量锁定与解锁 ✅"}]},
            "parent_tool_use_id": None, "session_id": session_id}, ensure_ascii=False) + "\n").encode("utf-8")
        # 故意切在一个多字节字符的中间，分两次写出。
        cut = line.index("订".encode("utf-8")) + 1
        emit_raw(line[:cut])
        time.sleep(0.15)
        emit_raw(line[cut:])
        result("多字节字符切包测试：订单批量锁定与解锁 ✅")
    else:
        assistant([{"type": "text", "text": "收到：" + text[:40]}])
        result("收到：" + text[:40])


while True:
    text = user_messages.get()
    if text is None:
        break
    run_turn(text)

log({"event": "exit"})
