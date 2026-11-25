import React, { useEffect, useState } from 'react';
import { Timer } from '@phosphor-icons/react';

export default function PromptCacheTimer({ expiresAt }) {
  const [now, setNow] = useState(Date.now);
  const seconds = Math.ceil((expiresAt - now) / 1000);
  useEffect(() => {
    setNow(Date.now());
    if (expiresAt <= Date.now()) return undefined;
    const interval = window.setInterval(() => {
      const next = Date.now();
      setNow(next);
      if (next >= expiresAt) window.clearInterval(interval);
    }, 1000);
    return () => window.clearInterval(interval);
  }, [expiresAt]);

  if (seconds <= 0) return null;
  const label = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  return (
    <span className="cli-cache-countdown" title="根据最近一次完成回合估算 Claude 提示缓存剩余时间">
      <Timer size={11} />
      {label}
    </span>
  );
}
