# Swttch 本地补丁

图形聊天模式打包的是上游 Swttch（`~/project/swttch`）的构建产物。上游基线：`3285a17b77919504c66e2ae7d8fbd5cfc4ab8a20`。

| 补丁 | 作用 |
| --- | --- |
| `0001-collapse-file-change-runs.patch` | 聊天记录里的文件改动（Edit / Write）默认收起，Verbose 视图除外 |
| `0002-composer-outside-transcript.patch` | 输入区独立于消息滚动区，防止文字穿过输入框；移除更新和浏览器通知提示，保留错误提示 |
| `0003-empty-state-logo-only.patch` | 空会话只显示 Logo，去掉小怪兽、轮换提示、首次引导清单和公告卡片（切换会话时不再闪现） |

重新构建：在上游目录 `git apply <补丁>` 后执行 `scripts/build.sh be-build` 与 `wv-build`（`BUILD_ENV=production`），再用 `scripts/build-app.sh --with-chat` 打包。

0002 的定向回归：`bash ./scripts/build.sh wv-test src/pages/ChatPage/__tests__/ChatPage.footerLayout.test.tsx src/pages/ChatPage/__tests__/ChatPage.topBar.test.tsx`。修改前布局用例 2 项失败，修改后共 9 项通过。

0003 的定向回归：`bash ./scripts/build.sh wv-test src/pages/ChatPage/__tests__/EmptyState.minimal.test.tsx src/pages/ChatPage/__tests__/EmptyState.desktop.test.tsx`。

通知权限不靠补丁：宿主 `ChatHost` 在页面加载前注入 `window.Notification` 替身（权限恒为 granted），页面发的通知转成 macOS 系统通知，所以不会再出现「回复完成时收到通知」横幅。
