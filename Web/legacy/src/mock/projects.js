import { claudeProject } from './projects-claude.js';
import { lmProject } from './projects-java.js';
import { lanmaProject } from './projects-python.js';

// 文件预览侧的项目数据源：树、文件、变更、默认展开目录。
export const projectData = {
  'claude-picker': claudeProject,
  'lm-global-java': lmProject,
  'lanma-bankend': lanmaProject,
};

export const projectOptions = [
  {
    id: 'claude-picker',
    label: 'claude-picker',
    path: '~/project/claude-picker',
    branch: projectData['claude-picker'].branch,
    ahead: 2,
    changes: 8,
  },
  {
    id: 'lm-global-java',
    label: 'lm-global-java',
    path: '~/project/lm-global-java',
    branch: lmProject.branch,
    ahead: 0,
    changes: 5,
  },
  {
    id: 'lanma-bankend',
    label: 'lanma-bankend',
    path: '~/project/lanma-bankend',
    branch: lanmaProject.branch,
    ahead: 1,
    changes: 4,
  },
];
