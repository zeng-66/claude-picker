// git patch → 可渲染的 hunk 列表。行结构沿用原型：[kind, 旧行号, 新行号, 文本]。

const META =
  /^(diff --git |index |--- |\+\+\+ |new file mode|deleted file mode|old mode|new mode|similarity index|rename (from|to) |Binary files )/;

/// 单次最多渲染的行数：再大的差异浏览器会明显卡顿，超出部分只给提示。
export const MAX_DIFF_LINES = 4000;

export function parsePatch(patch) {
  const hunks = [];
  if (!patch) return { hunks, truncated: false };
  const lines = String(patch).split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  let current = null;
  let oldLine = 0;
  let newLine = 0;
  let count = 0;
  let truncated = false;
  for (const text of lines) {
    const head = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/.exec(text);
    if (head) {
      oldLine = Number(head[1]);
      newLine = Number(head[2]);
      // 展示用的减号换成原型里的「−」
      current = { header: `@@ −${text.slice(4)}`, lines: [] };
      hunks.push(current);
      continue;
    }
    if (!current) {
      // 文件头（diff --git / index / ---）在第一个 hunk 之前：新的文件段落，重新等 hunk。
      continue;
    }
    if (META.test(text)) {
      current = null;
      continue;
    }
    if (text.startsWith('\\')) continue;
    if (count >= MAX_DIFF_LINES) {
      truncated = true;
      break;
    }
    count += 1;
    if (text.startsWith('+')) current.lines.push(['add', '', newLine++, text.slice(1)]);
    else if (text.startsWith('-')) current.lines.push(['del', oldLine++, '', text.slice(1)]);
    else
      current.lines.push([
        'context',
        oldLine++,
        newLine++,
        text.startsWith(' ') ? text.slice(1) : text,
      ]);
  }
  return { hunks, truncated };
}

/// 未跟踪 / 新文件没有 diff：整份内容当作新增行。
export function addedHunk(content) {
  const lines = String(content ?? '').split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  const shown = lines.slice(0, MAX_DIFF_LINES);
  return {
    hunks: [
      {
        header: `@@ −0,0 +1,${lines.length} @@`,
        lines: shown.map((text, index) => ['add', '', index + 1, text]),
      },
    ],
    truncated: lines.length > shown.length,
    additions: lines.length,
  };
}

/// 并排视图：把连续的删除 / 新增配对成同一行，左右两列行数始终一致。
export function splitRows(lines) {
  const rows = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (line[0] === 'context') {
      rows.push([line, line]);
      index += 1;
      continue;
    }
    const removed = [];
    const added = [];
    while (index < lines.length && lines[index][0] === 'del') removed.push(lines[index++]);
    while (index < lines.length && lines[index][0] === 'add') added.push(lines[index++]);
    for (let i = 0; i < Math.max(removed.length, added.length); i += 1)
      rows.push([removed[i] ?? null, added[i] ?? null]);
  }
  return rows;
}

/// 多文件 patch（git show）按文件切开：[{ path, patch }]。
export function splitFiles(patch) {
  const files = [];
  if (!patch) return files;
  let current = null;
  for (const line of String(patch).split('\n')) {
    const head = /^diff --git a\/(.*) b\/(.*)$/.exec(line);
    if (head) {
      current = { path: head[2], lines: [] };
      files.push(current);
      continue;
    }
    if (current) current.lines.push(line);
  }
  return files.map((file) => ({ path: file.path, patch: file.lines.join('\n') }));
}
