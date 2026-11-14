// lm-global-java 项目的演示文件树与变更集。
const lmOrderControllerContent = `package com.lanma.order.controller;

import org.springframework.web.bind.annotation.*;
import com.lanma.order.service.OrderService;

@RestController
@RequestMapping("/api/orders")
public class OrderController {
    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

    @PostMapping("/{orderId}/retry")
    public RetryResponse retry(@PathVariable Long orderId) {
        return orderService.retry(orderId);
    }
}
`;
const lmOrderServiceContent = `package com.lanma.order.service;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class OrderService {
    @Transactional
    public RetryResponse retry(Long orderId) {
        Order order = repository.findForUpdate(orderId);
        order.requireRetryable();
        retryTask.enqueue(order.getId());
        return RetryResponse.accepted(order.getId());
    }
}
`;
const lmApplicationContent = `server:
  port: 8080

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/lanma
    username: lanma
    password: change-me

order:
  retry:
    max-attempts: 3
`;
const lmFlowContent = `flowchart LR
  A[运营端请求重试] --> B[OrderController]
  B --> C[OrderService]
  C --> D{订单可重试?}
  D -- 是 --> E[写入重试任务]
  E --> F[XXL-JOB 执行]
  D -- 否 --> G[返回业务错误]`;
const lmApiContent = `# 订单重试接口

## POST /api/orders/{orderId}/retry

触发订单异步重试。

### 返回示例

\`\`\`json
{
  "accepted": true,
  "orderId": 1050356
}
\`\`\`
`;
const lmOrdersCsv = `orderId,status,attempts\n1050356,PAID,0\n1050357,PAYING,1\n1050358,WAIT_SHIP,0\n`;
const lmReadmeContent = `# lm-global-java

面向 Lanma 与 Fangguo 业务的 Java 服务。

## 当前项目能力

- 订单操作与批量任务
- 工厂列表与商品同步
- S3 素材与裁片任务
`;
const lmDeletedContent = `# Legacy API

旧版订单查询接口，已从路由中删除。

GET /api/legacy/orders/{id}
`;

const lmFiles = [
  { path: 'README.md', kind: 'markdown', content: lmReadmeContent },
  {
    path: 'pom.xml',
    kind: 'code',
    content:
      '<?xml version="1.0" encoding="UTF-8"?>\n<project>\n  <modelVersion>4.0.0</modelVersion>\n</project>\n',
  },
  { path: 'docs/order-api.md', kind: 'markdown', content: lmApiContent },
  { path: 'docs/order-flow.mmd', kind: 'diagram', content: lmFlowContent },
  {
    path: 'src/main/java/com/lanma/order/controller/OrderController.java',
    kind: 'code',
    content: lmOrderControllerContent,
  },
  {
    path: 'src/main/java/com/lanma/order/service/OrderService.java',
    kind: 'code',
    content: lmOrderServiceContent,
  },
  { path: 'src/main/resources/application.yml', kind: 'code', content: lmApplicationContent },
  { path: 'data/orders.csv', kind: 'csv', content: lmOrdersCsv },
  {
    path: 'assets/order-dashboard.png',
    kind: 'image',
    src: '/assets/workspace-preview.png',
    dimensions: '1180 × 728 px',
    size: '152 KB',
  },
];

export const lmProject = {
  branch: 'bugfix/zcl/20261113_operationRetryCropFailed',
  ahead: 0,
  defaultPath: 'docs/order-api.md',
  expanded: ['docs', 'src', 'data', 'assets'],
  files: lmFiles,
  deletedFiles: [
    { path: 'docs/legacy-api.md', kind: 'markdown', deleted: true, content: lmDeletedContent },
  ],
  tree: [
    { type: 'folder', name: 'docs', files: ['docs/order-api.md', 'docs/order-flow.mmd'] },
    {
      type: 'folder',
      name: 'src',
      files: [
        'src/main/java/com/lanma/order/controller/OrderController.java',
        'src/main/java/com/lanma/order/service/OrderService.java',
        'src/main/resources/application.yml',
      ],
    },
    { type: 'folder', name: 'data', files: ['data/orders.csv'] },
    { type: 'folder', name: 'assets', files: ['assets/order-dashboard.png'] },
    { type: 'file', path: 'README.md' },
    { type: 'file', path: 'pom.xml' },
  ],
  changes: {
    'src/main/java/com/lanma/order/controller/OrderController.java': {
      state: 'modified',
      label: 'M',
      staged: false,
      before: lmOrderControllerContent.replace(
        '        return orderService.retry(orderId);\n',
        '        return RetryResponse.notReady();\n',
      ),
      after: lmOrderControllerContent,
    },
    'docs/order-flow.mmd': {
      state: 'modified',
      label: 'M',
      staged: false,
      before: lmFlowContent.replace('  E --> F[XXL-JOB 执行]\n', ''),
      after: lmFlowContent,
    },
    'src/main/java/com/lanma/order/service/OrderService.java': {
      state: 'modified',
      label: 'M',
      staged: true,
      before: lmOrderServiceContent.replace('        retryTask.enqueue(order.getId());\n', ''),
      after: lmOrderServiceContent,
    },
    'assets/order-dashboard.png': {
      state: 'added',
      label: 'A',
      staged: true,
      binary: true,
      before: null,
      after: '/assets/workspace-preview.png',
    },
    'docs/legacy-api.md': {
      state: 'deleted',
      label: 'D',
      staged: true,
      before: lmDeletedContent,
      after: '',
    },
  },
};
