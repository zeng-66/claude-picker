import React from 'react';
import { createRoot } from 'react-dom/client';

// 桌面桌宠悬浮窗（原生 PetController 以 ?pet=desktop 加载）只渲染桌宠，不加载整个外壳。
const root = createRoot(document.getElementById('root'));
const params = new URLSearchParams(location.search);
if (params.get('pet') === 'desktop') {
  import('./shell/pet/PetWindow.jsx').then(({ default: PetWindow }) => root.render(<PetWindow />));
} else {
  import('./shell/App.jsx').then(async ({ default: App }) => {
    if (import.meta.env.DEV && params.has('review')) {
      const { isNative } = await import('./shell/bridge.js');
      if (!isNative()) {
        const { default: ReviewNotes } = await import('./ReviewNotes.jsx');
        root.render(<><App /><ReviewNotes /></>);
        return;
      }
    }
    root.render(<App />);
  });
}
