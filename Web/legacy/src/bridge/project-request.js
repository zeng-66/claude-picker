// 针对「当前项目」的桥请求：自动带上当前项目路径，并丢弃过期的响应。
//
// git.* 在原生侧是并行执行的（后台线程），切项目时旧项目的请求可能比新项目的晚回来，
// 直接 setState 就会把新项目的数据覆盖掉。这里在响应回来时核对项目是否已变：
// 变了就返回一个永不 settle 的 Promise —— 调用方什么都不做，界面交给新项目那次请求更新。
import { request } from './client.js';
import { currentProjectId, projectPathFor } from './dto.js';

const NEVER = new Promise(() => {});

export function activeProjectPath() {
  return projectPathFor(currentProjectId());
}

export function projectRequest(method, params = {}, options) {
  const projectPath = activeProjectPath();
  const stale = () => activeProjectPath() !== projectPath;
  return request(method, { ...params, projectPath }, options).then(
    (result) => (stale() ? NEVER : result),
    (error) => (stale() ? NEVER : Promise.reject(error)),
  );
}
