# Swttch 本地补丁

图形聊天模式打包的是上游 Swttch（`~/project/swttch`）的构建产物。上游基线：`3285a17b77919504c66e2ae7d8fbd5cfc4ab8a20`。

| 补丁 | 作用 |
| --- | --- |
| `0001-collapse-file-change-runs.patch` | 聊天记录里的文件改动（Edit / Write）默认收起，Verbose 视图除外 |

重新构建：在上游目录 `git apply <补丁>` 后执行 `scripts/build.sh be-build` 与 `wv-build`（`BUILD_ENV=production`），再用 `scripts/build-app.sh --with-chat` 打包。
