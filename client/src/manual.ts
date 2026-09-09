import { clear, el } from './ui';

export interface ManualHandlers {
  close(): void;
}

interface ManualSection { title: string; body: string[]; table?: [string, string][]; }

const SECTIONS: ManualSection[] = [
  {
    title: '一、游戏目标',
    body: ['2-4 名玩家扮演潮汐群岛的商会船长，进行 4 轮 × 3 回合（共 12 回合）的贸易竞争。终局总分最高者获胜。'],
  },
  {
    title: '二、开局',
    body: ['每人 5 张手牌、3 金币，船停在东鳞港。公开 3 张订单，每人再秘密获得 1 张隐藏订单。市场初始价格：盐鳞 3、灯油 3、丝贝 4。潮汐从「涨潮」开始。'],
  },
  {
    title: '三、每回合做什么',
    body: [
      '1. 选牌（45 秒）：所有人同时选 1 张手牌并声明用途。超时未选，系统自动将第 1 张手牌以「推潮」打出。',
      '2. 结算：按座位顺序依次结算，随后推进潮汐、触发事件、每人补 1 张牌。',
    ],
  },
  {
    title: '四、卡牌的三种用途',
    body: [
      '行动：执行卡牌行动面（见下）。',
      '存货：放入货物仓，变成对应货物；万用货物（wild）可充当任意货物。',
      '推潮：弃置卡牌，按潮纹值推进公共潮汐轨道（wild 潮纹为 0，不推进）。',
    ],
  },
  {
    title: '五、六种行动',
    body: [
      '扬帆：付航行费（基础 1 金币）移动到相邻港口，四港成环。',
      '市集交易：买货（一次最多 2 件同种，每件买入后价格 +1）或卖货（固定 1 件，卖出后价格 -1）。',
      '交付订单：交出订单所需全部货物，获得 VP 与金币；订单涉及的每种货物价格 -1。',
      '设立商站：付 2 金币在当前港口放 1 枚商站，每港每人限 1 枚，不可移动。',
      '潮汐秘术：二选一——窥探事件堆顶，或将潮汐轨道前进/后退 1 格。',
      '顺风：先扬帆到相邻港，再在新港追加一次交易（全牌库仅 4 张）。',
    ],
  },
  {
    title: '六、潮汐四档（循环：低潮→涨潮→满潮→退潮）',
    body: ['潮汐进入新档位时触发对应事件（如暗礁每人 -1 金币、商队启程每人 +1 金币、海雾无事发生等）。'],
    table: [
      ['低潮', '航行费 +1；买货每件 -1（最低 1）'],
      ['涨潮', '交付订单额外 +1 VP'],
      ['满潮', '航行免费；卖货每件售价 +1（可突破价格上限）'],
      ['退潮', '航行费 +1；交付隐藏订单额外 +1 VP'],
    ],
  },
  {
    title: '七、市场',
    body: ['三种货物价格区间 1-6，越界会被钳制。买货抬价、卖货与交付压价，价格变动在当笔结算之后生效。'],
  },
  {
    title: '八、订单',
    body: ['公开订单 3 张，先交先得，不补新单；隐藏订单仅本人可见，交付时公开。万用货物可替代任意货物。订单在任意港口均可交付。'],
  },
  {
    title: '九、商站与终局计分',
    body: [
      '终局按四港商站数量结算多数分：第 1 名 4 分、第 2 名 2 分、第 3 名 1 分；并列平分（向下取整）。',
      '总分 = 订单 VP + 商站多数分 + 剩余货物每件 1 分（上限 5）+ 金币每 3 枚换 1 分（上限 4）。',
      '平分依次比较：订单 VP → 商站分 → 金币 → 共享胜利。',
    ],
  },
  {
    title: '十、断线与超时',
    body: ['选牌超时自动推潮第 1 张手牌；断线 60 秒内可重连恢复，不会阻塞其他玩家。'],
  },
];

export function renderManual(root: HTMLElement, h: ManualHandlers): void {
  clear(root);
  const mask = el('div', 'manual-mask');
  const box = el('section', 'manual-box');
  const head = el('div', 'manual-head');
  head.appendChild(el('h2', 'manual-title', '《潮汐商会》游戏说明'));
  const closeBtn = el('button', 'btn btn-ghost btn-small', '返回') as HTMLButtonElement;
  closeBtn.type = 'button'; closeBtn.onclick = h.close;
  head.appendChild(closeBtn);
  box.appendChild(head);

  const body = el('div', 'manual-body');
  for (const sec of SECTIONS) {
    const section = el('section', 'manual-section');
    section.appendChild(el('h3', 'manual-h', sec.title));
    for (const line of sec.body) section.appendChild(el('p', 'manual-p', line));
    if (sec.table) {
      const table = el('table', 'manual-table');
      for (const [k, v] of sec.table) {
        const tr = el('tr', '');
        tr.appendChild(el('td', 'manual-tide', k));
        tr.appendChild(el('td', '', v));
        table.appendChild(tr);
      }
      section.appendChild(table);
    }
    body.appendChild(section);
  }
  box.appendChild(body);

  const foot = el('div', 'manual-foot');
  const backBtn = el('button', 'btn btn-primary', '返回') as HTMLButtonElement;
  backBtn.type = 'button'; backBtn.onclick = h.close;
  foot.appendChild(backBtn);
  box.appendChild(foot);

  mask.appendChild(box);
  root.appendChild(mask);
}
