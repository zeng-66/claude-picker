// 当前项目路径的共享存放点：AppContext 写、dto.js 读。
// 项目下拉框搬到原生标题栏后，DOM 里不再有「选择项目」<select>，dto 不能再靠它取当前项目。
let current = '';

export function setSharedActiveProject(path) {
  current = String(path ?? '');
}

export function getSharedActiveProject() {
  return current;
}
