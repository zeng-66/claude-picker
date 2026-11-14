// lanma-bankend 项目的演示文件树与变更集。
const lanmaRoutesContent = `from fastapi import APIRouter, Depends

router = APIRouter(prefix="/api/orders", tags=["orders"])

@router.post("/{order_id}/retry")
async def retry_order(order_id: int, service=Depends(get_order_service)):
    return await service.retry(order_id)
`;
const lanmaServiceContent = `class OrderService:
    async def retry(self, order_id: int):
        order = await self.repository.find_for_update(order_id)
        self.retry_policy.ensure_retryable(order)
        await self.jobs.enqueue("order.retry", order_id=order.id)
        return {"accepted": True, "orderId": order.id}
`;
const lanmaAgentFlowContent = `flowchart TD
  A[用户消息] --> B[意图识别]
  B --> C{需要工单?}
  C -- 是 --> D[创建工单]
  C -- 否 --> E[直接回答]
  D --> F[通知处理人]
  E --> G[返回结果]`;
const lanmaApiDocContent = `# Lanma API

## 对话接口

客户端通过 SSE 接收 Agent 输出。

- POST /api/chat/stream
- GET /api/orders/{id}
- POST /api/orders/{id}/retry
`;
const lanmaTestContent = `import pytest
from app.services.order_service import OrderService

@pytest.mark.asyncio
async def test_retry_order():
    service = OrderService(repository=FakeRepository())
    result = await service.retry(1050356)
    assert result["accepted"] is True
`;
const lanmaReadmeContent = `# lanma-bankend

Lanma 业务后端，包含订单、工单和 Agent 服务。

## 运行

\`\`\`bash
uvicorn app.main:app --reload
\`\`\`
`;
const lanmaDeletedContent = `class LegacySessionAdapter:
    def load(self, session_id):
        return self.repository.get(session_id)
`;

const lanmaFiles = [
  { path: 'README.md', kind: 'markdown', content: lanmaReadmeContent },
  {
    path: 'requirements.txt',
    kind: 'code',
    content: 'fastapi>=0.115\nuvicorn>=0.32\nsqlalchemy>=2.0\n',
  },
  { path: 'docs/agent-flow.mmd', kind: 'diagram', content: lanmaAgentFlowContent },
  { path: 'docs/api-design.md', kind: 'markdown', content: lanmaApiDocContent },
  { path: 'app/api/routes/orders.py', kind: 'code', content: lanmaRoutesContent },
  { path: 'app/services/order_service.py', kind: 'code', content: lanmaServiceContent },
  { path: 'tests/test_orders.py', kind: 'code', content: lanmaTestContent },
  {
    path: 'data/conversations.csv',
    kind: 'csv',
    content: 'id,role,status\nc-101,agent,resolved\nc-102,human,waiting\n',
  },
];

export const lanmaProject = {
  branch: 'beta',
  ahead: 1,
  defaultPath: 'docs/api-design.md',
  expanded: ['docs', 'app', 'tests', 'data'],
  files: lanmaFiles,
  deletedFiles: [
    { path: 'app/legacy/session.py', kind: 'code', deleted: true, content: lanmaDeletedContent },
  ],
  tree: [
    { type: 'folder', name: 'docs', files: ['docs/agent-flow.mmd', 'docs/api-design.md'] },
    {
      type: 'folder',
      name: 'app',
      files: ['app/api/routes/orders.py', 'app/services/order_service.py'],
    },
    { type: 'folder', name: 'tests', files: ['tests/test_orders.py'] },
    { type: 'folder', name: 'data', files: ['data/conversations.csv'] },
    { type: 'file', path: 'README.md' },
    { type: 'file', path: 'requirements.txt' },
  ],
  changes: {
    'app/api/routes/orders.py': {
      state: 'added',
      label: 'A',
      staged: false,
      before: '',
      after: lanmaRoutesContent,
    },
    'docs/api-design.md': {
      state: 'modified',
      label: 'M',
      staged: false,
      before: lanmaApiDocContent.replace('- POST /api/orders/{id}/retry\n', ''),
      after: lanmaApiDocContent,
    },
    'app/services/order_service.py': {
      state: 'modified',
      label: 'M',
      staged: true,
      before: lanmaServiceContent.replace(
        '        await self.jobs.enqueue("order.retry", order_id=order.id)\n',
        '',
      ),
      after: lanmaServiceContent,
    },
    'app/legacy/session.py': {
      state: 'deleted',
      label: 'D',
      staged: true,
      before: lanmaDeletedContent,
      after: '',
    },
  },
};
