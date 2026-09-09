import { clear, el } from './ui';
import { resolveWsUrl } from './net';
import type { WsUrlSource } from './net';

export interface EntryHandlers {
  tutorial(): void;
  login(): void;
  register(): void;
  applyServer(url: string): void;
  resetServer(): void;
}

const WS_SOURCE_TEXT: Record<WsUrlSource, string> = {
  param: '调试参数',
  manual: '手动',
  build: '构建',
  auto: '自动',
};

export function isDebugMode(): boolean {
  return new URLSearchParams(location.search).get('debug') === '1';
}

export function renderEntry(root: HTMLElement, h: EntryHandlers): void {
  clear(root);
  const screen = el('div', 'entry-screen');
  const hero = el('section', 'entry-hero');
  hero.appendChild(el('div', 'entry-mark', 'TIDES · 2-4 人卡牌桌游'));
  hero.appendChild(el('h1', 'entry-logo', '潮汐商会'));
  hero.appendChild(el('p', 'entry-sub', '潮起潮落之间，唯有借势者赢得群岛。'));
  const actions = el('div', 'entry-actions');
  const loginBtn = el('button', 'btn btn-primary btn-wide', '登录') as HTMLButtonElement;
  loginBtn.type = 'button'; loginBtn.onclick = h.login; actions.appendChild(loginBtn);
  const registerBtn = el('button', 'btn btn-ghost btn-wide', '注册') as HTMLButtonElement;
  registerBtn.type = 'button'; registerBtn.onclick = h.register; actions.appendChild(registerBtn);
  const tutorialBtn = el('button', 'btn btn-ghost btn-wide', '新手教程') as HTMLButtonElement;
  tutorialBtn.type = 'button'; tutorialBtn.onclick = h.tutorial; actions.appendChild(tutorialBtn);
  hero.appendChild(actions);
  screen.appendChild(hero);

  if (isDebugMode()) {
    const resolved = resolveWsUrl();
    const serverRow = el('div', 'server-row entry-debug');
    serverRow.appendChild(el('label', '', '服务器地址'));
    const serverInput = el('input', 'input') as HTMLInputElement;
    serverInput.value = resolved.url;
    serverInput.spellcheck = false;
    serverRow.appendChild(serverInput);
    serverRow.appendChild(el('span', 'tag', `来源：${WS_SOURCE_TEXT[resolved.source]}`));
    const serverBtn = el('button', 'btn btn-ghost', '应用') as HTMLButtonElement;
    serverBtn.onclick = () => h.applyServer(serverInput.value.trim());
    serverRow.appendChild(serverBtn);
    if (resolved.source === 'manual') {
      const resetBtn = el('button', 'btn btn-ghost', '恢复自动') as HTMLButtonElement;
      resetBtn.title = '清除手动填写的地址，恢复自动推导';
      resetBtn.onclick = () => h.resetServer();
      serverRow.appendChild(resetBtn);
    }
    screen.appendChild(serverRow);
  }
  root.appendChild(screen);
}
