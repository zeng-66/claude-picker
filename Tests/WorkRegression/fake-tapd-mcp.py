#!/usr/bin/env python3
"""TAPD MCP 协议替身（stdio，JSON-RPC 2.0）：只实现 ClaudePicker 用到的工具子集。

- 没有 TAPD_ACCESS_TOKEN 时 tools/call 返回 isError。
- 项目 9999 不存在（status=0）；项目 1001、1002 可读，1001 有一条待办需求与一条缺陷。
- FAKE_TAPD_MCP_TOOLS=minimal 时只暴露必需工具。
每次 tools/call 追加写入 FAKE_TAPD_MCP_LOG。
"""
import json
import os
import sys

LOG = os.environ.get("FAKE_TAPD_MCP_LOG")
TOKEN = os.environ.get("TAPD_ACCESS_TOKEN")
ALL = ["get_workspace_info", "get_todo", "get_stories_or_tasks", "get_bug", "get_comments", "get_workspace_users",
       "create_comments", "get_workflows_status_map", "update_story_or_task", "update_bug", "get_iterations"]
TOOLS = ALL[:2] if os.environ.get("FAKE_TAPD_MCP_TOOLS") == "minimal" else ALL
NAMES = {"1001": "支付中台", "1002": "运营后台"}


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def text(payload, is_error=False):
    return {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}], "isError": is_error}


def call(name, args):
    if LOG:
        with open(LOG, "a") as handle:
            handle.write(json.dumps({"tool": name, "args": args, "token": bool(TOKEN)}, ensure_ascii=False) + "\n")
    if not TOKEN:
        return {"content": [{"type": "text", "text": "missing TAPD_ACCESS_TOKEN"}], "isError": True}
    ws = str(args.get("workspace_id", ""))
    if name == "get_workspace_info":
        if ws not in NAMES:
            return text({"status": 0, "data": [], "info": "workspace not found"})
        return text({"status": 1, "data": {"Workspace": {"id": ws, "name": NAMES[ws], "status": "normal"}}, "info": "success"})
    if name == "get_todo":
        if ws not in NAMES:
            return text({"status": 0, "data": [], "info": "no permission"})
        if ws != "1001":
            return text({"status": 1, "data": [], "info": "success"})
        if args.get("entity_type") == "bug":
            row = {"Bug": {"id": "1110010010000099", "workspace_id": ws, "title": "支付回调重复", "status": "new",
                           "current_owner": "me", "modified": "2026-11-18 10:00:00"}}
        else:
            # 与真实 get_todo 一样只给最少字段，其余由详情、状态表、迭代补齐。
            row = {"Story": {"id": "1110010010000042", "workspace_id": ws, "name": "退款对账", "status": "status_15",
                             "priority": "Middle", "creator": "me", "modified": "2026-11-19 09:00:00"}}
        return text({"status": 1, "data": [row], "info": "success"})
    opts = args.get("options") or {}
    if name == "get_stories_or_tasks":
        return text({"data": [{"Story": {"id": i, "owner": "me;", "iteration_id": "77", "created": "2026-11-01 08:00:00"}}
                              for i in str(opts.get("id", "")).split(",") if i], "count": 1})
    if name == "get_bug":
        return text({"status": 1, "data": [{"Bug": {"id": i, "current_owner": "me;", "created": "2026-11-02 08:00:00"}}
                                          for i in str(opts.get("id", "")).split(",") if i]})
    if name == "get_workflows_status_map":
        return text({"status": 1, "data": {"status_15": "C2-开发中", "new": "新"}})
    if name == "get_iterations":
        return text({"status": 1, "data": [{"Iteration": {"id": "77", "name": "11 月第 3 周"}}]})
    return {"content": [{"type": "text", "text": "unsupported in fake"}], "isError": True}


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method, rid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                                      "serverInfo": {"name": "fake-tapd", "version": "0.1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [
            {"name": n, "inputSchema": {"type": "object", "properties": {"workspace_id": {"type": "string"}}, "required": ["workspace_id"]}}
            for n in TOOLS]}})
    elif method == "tools/call":
        params = msg.get("params") or {}
        send({"jsonrpc": "2.0", "id": rid, "result": call(params.get("name"), params.get("arguments") or {})})
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unsupported"}})
