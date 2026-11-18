// 桌面桌宠悬浮窗的页面（原生 PetController 以 ?pet=desktop 加载）。
// 只渲染桌宠：状态来自同一份 app.state / Work 快照，操作交给原生（移动窗口、右键菜单、唤起主窗口）。
import React, { useEffect, useState } from 'react';
import { on, request } from '../bridge.js';
import { useWorks } from '../work/useWorks.js';
import DesktopPet from './DesktopPet.jsx';
import { usePetSignals } from './usePetSignals.js';
import { DEFAULT_PET } from './PetSettings.jsx';

for (const node of [document.documentElement, document.body, document.getElementById('root')]) {
  if (node) node.style.background = 'transparent';
}
document.body.style.margin = '0';
document.body.style.overflow = 'hidden';

export default function PetWindow() {
  const [state, setState] = useState(null);
  const { snapshot: workSnap } = useWorks();
  const signals = usePetSignals(state, workSnap);

  useEffect(() => {
    request('app.state')
      .then(setState)
      .catch(() => {});
    return on('state', setState);
  }, []);

  if (!state) return null;
  const pet = { ...DEFAULT_PET, ...state.settings?.pet };
  return (
    <DesktopPet
      desktop
      settings={{ ...pet, enabled: true }}
      signals={signals}
      onChange={(patch) => request('app.settings', { pet: { ...pet, ...patch } }).catch(() => {})}
      onClick={() => request('pet.click').catch(() => {})}
      onOpenTarget={(target) => request('pet.open', { displayId: target?.displayId }).catch(() => {})}
    />
  );
}
