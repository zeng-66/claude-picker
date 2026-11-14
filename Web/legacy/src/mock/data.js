// 演示数据的唯一出口。
// 页面与组件一律从这里取数据；T1 接入桥接协议后，只需要替换本文件底下的实现，
// 上层 UI 不需要跟着改。当前所有内容都是原型里的硬编码演示数据。
import { markdownFiles, diagramFiles, htmlFiles } from './documents.js';
import { codeFiles } from './code-content.js';

export * from './git-demo.js';
export * from './projects.js';
export * from './sidebar-projects.js';
export { markdownFiles, diagramFiles, htmlFiles, codeFiles };

// 可编辑的文本文件初始内容：文档 / 代码 / 图表 / HTML 合在一起按路径索引。
export function createTextDocuments() {
  return {
    ...markdownFiles,
    ...codeFiles,
    ...diagramFiles,
    ...htmlFiles,
  };
}
