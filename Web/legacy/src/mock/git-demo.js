// Git 工作台的演示数据：导航配置、变更文件、提交历史、分支 / Stash / 标签 / 工作树。
// T1 起这些常量改由 src/bridge/ 的真实数据填充，UI 不再自己造数据。
import {
  GitBranch,
  GitMerge,
  CloudArrowUp,
  Stack,
  Tag,
  TreeStructure,
  Terminal,
  Clock,
  SquaresFour,
} from '@phosphor-icons/react';
export const navigation = [
  ['工作区', SquaresFour, '4'],
  ['提交历史', Clock, '128'],
  ['分支管理', GitBranch, '8'],
  ['合并与冲突', GitMerge, '1'],
  ['Stash 暂存', Stack, '2'],
  ['标签 Tags', Tag, '3'],
  ['工作树', TreeStructure, '2'],
  ['远程仓库', CloudArrowUp, ''],
  ['全部操作', Terminal, ''],
];
export const operations = {
  仓库与配置: [
    '初始化仓库 init',
    '克隆仓库 clone',
    '仓库配置 config',
    '忽略规则 .gitignore',
    '子模块 submodule',
    'Git LFS',
  ],
  日常变更: [
    '查看状态 status',
    '差异比较 diff',
    '暂存 add',
    '取消暂存 restore --staged',
    '恢复文件 restore',
    '提交 commit',
    '修改最近提交 amend',
    '临时存储 stash',
  ],
  分支与协作: [
    '创建分支 branch',
    '切换分支 switch',
    '合并 merge',
    '变基 rebase',
    '交互式变基 rebase -i',
    '拣选 cherry-pick',
    '获取 fetch',
    '拉取 pull',
    '推送 push',
    '远程管理 remote',
    '标签 tag',
    '工作树 worktree',
  ],
  历史与恢复: [
    '提交记录 log',
    '行追溯 blame',
    '查找提交 bisect',
    '撤销提交 revert',
    '重置 reset',
    '引用日志 reflog',
    '清理文件 clean',
    '补丁 format-patch / apply',
    '归档 archive',
    '对象检查 show / ls-tree',
    '维护 gc / fsck',
    '高级 Git 命令',
  ],
};
export const demoInitialFiles = [
  { name: 'GitPanel.swift', path: 'Sources/ClaudeDeck', type: 'M', add: 86, del: 24 },
  { name: 'Models.swift', path: 'Sources/ClaudeDeck', type: 'M', add: 18, del: 4 },
  { name: 'GitService.swift', path: 'Sources/ClaudeDeck', type: 'A', add: 124, del: 0 },
  { name: 'git-workbench.md', path: 'docs', type: 'A', add: 32, del: 0 },
];
export const gitFilesByProject = {
  'claude-picker': demoInitialFiles,
  'lm-global-java': [
    {
      name: 'OrderController.java',
      path: 'src/main/java/com/lanma/order/controller',
      type: 'M',
      add: 18,
      del: 6,
    },
    {
      name: 'OrderService.java',
      path: 'src/main/java/com/lanma/order/service',
      type: 'M',
      add: 12,
      del: 3,
    },
    { name: 'order-flow.mmd', path: 'docs', type: 'M', add: 4, del: 1 },
    { name: 'order-dashboard.png', path: 'assets', type: 'A', add: 0, del: 0 },
    { name: 'legacy-api.md', path: 'docs', type: 'D', add: 0, del: 24 },
  ],
  'lanma-bankend': [
    { name: 'orders.py', path: 'app/api/routes', type: 'A', add: 38, del: 0 },
    { name: 'api-design.md', path: 'docs', type: 'M', add: 9, del: 1 },
    { name: 'order_service.py', path: 'app/services', type: 'M', add: 14, del: 2 },
    { name: 'session.py', path: 'app/legacy', type: 'D', add: 0, del: 16 },
  ],
};
export const commits = [
  'feat: 新增 Git 工作区与文件差异预览',
  'fix: 优化终端焦点与快捷键响应',
  'feat: 支持多项目会话快速切换',
  'refactor: 统一工作区状态管理',
  'feat: 增加 Git 分支与工作树面板',
  'fix: 修复侧边栏折叠后的布局问题',
];
export const demoBranch = 'feature/git-workbench';
export const demoBranches = [
  'feature/git-workbench',
  'master',
  'feature/terminal-tabs',
  'fix/sidebar-focus',
];
export const demoStash = ['WIP: 终端多标签布局', 'WIP: 偏好设置面板'];
export const demoTags = ['v0.3.0', 'v0.2.1', 'v0.2.0'];
export const demoWorktrees = ['主工作树', 'terminal-tabs'];
export const demoLog = ['工作区已就绪 · 所有操作使用演示数据'];

// 工作区 Diff 面板的演示代码行；after 为 true 时使用「修改后」一侧。
export function codeLines(name, after) {
  if (name !== 'GitPanel.swift')
    return [
      ['', '// ' + (name || '文件预览')],
      ['', 'import Foundation'],
      ['', ''],
      [after ? 'added' : '', 'struct WorkspaceState {'],
      [after ? 'added' : '', '    var branch: String'],
      [after ? 'added' : '', '    var changedFiles: [GitFile]'],
      [after ? 'added' : '', '    var isLoading = false'],
      [after ? 'added' : '', '}'],
      ['', ''],
      ['', '// 文件内容仅供界面演示'],
    ];
  return [
    ['', 'struct GitWorkspaceView: View {'],
    ['', '    @ObservedObject var store: GitStore'],
    ['', ''],
    ['', '    var body: some View {'],
    [after ? 'added' : 'removed', after ? '        HSplitView {' : '        VStack(spacing: 12) {'],
    [
      after ? 'added' : 'removed',
      after ? '            changesSidebar' : '            statusHeader',
    ],
    [
      after ? 'added' : 'removed',
      after ? '                .frame(minWidth: 280)' : '            changedFiles',
    ],
    [after ? 'added' : 'removed', after ? '            diffPreview' : '            commitForm'],
    ['', '        }'],
    [after ? 'added' : '', after ? '        .background(Color.workspace)' : ''],
    ['', '    }'],
    ['', ''],
    [after ? 'added' : '', after ? '    private var diffPreview: some View {' : ''],
    [after ? 'added' : '', after ? '        DiffView(file: store.selectedFile)' : ''],
    [after ? 'added' : '', after ? '            .toolbar { diffActions }' : ''],
    [after ? 'added' : '', after ? '    }' : ''],
    ['', '}'],
  ];
}
