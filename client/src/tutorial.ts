import { clear, el } from './ui';

export interface TutorialHandlers {
  next(): void;
  previous(): void;
  back(): void;
  finish(): void;
  register(): void;
}

interface TutorialPage { eyebrow: string; title: string; copy: string[]; }

const PAGES: TutorialPage[] = [
  {
    eyebrow: '01 / 03 · 这是什么',
    title: '潮汐群岛的商会船长',
    copy: [
      '你是潮汐群岛四大商会的船长。四个轮回里，驾船穿梭于东鳞港、碎星礁、雾门与白汐城之间，低买高卖、交付订单、设立商站。',
      '四轮之后，财富与声望最高的商会获胜。',
    ],
  },
  {
    eyebrow: '02 / 03 · 一张牌三种用法',
    title: '手牌，是行动也是资源',
    copy: [
      '每回合你打出一张手牌，三选一——',
      '① 执行卡牌行动（扬帆、交易、交付、设站、秘术、顺风）；',
      '② 留存为货物，拿去卖钱或交付订单；',
      '③ 弃置推动潮汐，改变所有人的航行费与价格。',
    ],
  },
  {
    eyebrow: '03 / 03 · 怎么赢',
    title: '盯紧潮位，抢下订单',
    copy: [
      '订单给 VP 和金币，商站在终局按港口多数计分，剩余货物与金币也折算成分。',
      '盯紧潮位：涨潮交付多得分，满潮航行免费、卖货加价。总分最高者胜。',
    ],
  },
];

export function renderTutorial(root: HTMLElement, page: number, h: TutorialHandlers): void {
  clear(root);
  const screen = el('div', 'tutorial-screen');
  const box = el('section', 'tutorial-box');
  const close = el('button', 'tutorial-close', '×') as HTMLButtonElement;
  close.type = 'button'; close.title = '返回登录'; close.onclick = h.back; box.appendChild(close);

  const idx = Math.max(0, Math.min(page, PAGES.length - 1));
  const current = PAGES[idx];
  box.appendChild(el('div', 'tutorial-eyebrow', current.eyebrow));
  box.appendChild(el('h2', 'tutorial-title', current.title));
  for (const line of current.copy) box.appendChild(el('p', 'tutorial-lead', line));

  const dots = el('div', 'tutorial-dots');
  for (let i = 0; i < PAGES.length; i += 1) dots.appendChild(el('span', i === idx ? 'active' : ''));
  box.appendChild(dots);

  const actions = el('div', 'tutorial-actions');
  const back = el('button', 'btn btn-ghost btn-small', '返回登录') as HTMLButtonElement;
  back.type = 'button'; back.onclick = h.back; actions.appendChild(back);
  if (idx > 0) {
    const prev = el('button', 'btn btn-ghost btn-small', '上一步') as HTMLButtonElement;
    prev.type = 'button'; prev.onclick = h.previous; actions.appendChild(prev);
  }
  if (idx < PAGES.length - 1) {
    const next = el('button', 'btn btn-primary btn-small', '下一步') as HTMLButtonElement;
    next.type = 'button'; next.onclick = h.next; actions.appendChild(next);
  } else {
    const register = el('button', 'btn btn-ghost btn-small', '注册账号') as HTMLButtonElement;
    register.type = 'button'; register.onclick = h.register; actions.appendChild(register);
    const done = el('button', 'btn btn-primary btn-small', '完成，返回登录') as HTMLButtonElement;
    done.type = 'button'; done.onclick = h.finish; actions.appendChild(done);
  }
  box.appendChild(actions);
  screen.appendChild(box);
  root.appendChild(screen);
}
