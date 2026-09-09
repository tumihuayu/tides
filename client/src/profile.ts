import type { AppActions, AppState } from './ui';
import { clear, el, tsToMs } from './ui';
import type { RecentGame } from './types';

export const pwdDraft = {
  oldPw: '',
  newPw: '',
  confirmPw: '',
  error: null as string | null,
  busy: false,
};

export function resetPwdDraft(): void {
  pwdDraft.oldPw = '';
  pwdDraft.newPw = '';
  pwdDraft.confirmPw = '';
  pwdDraft.error = null;
  pwdDraft.busy = false;
}

function fmtDelta(delta: number | null | undefined): { text: string; cls: string } {
  if (delta === null || delta === undefined) return { text: '-', cls: 'delta-null' };
  if (delta > 0) return { text: `+${delta}`, cls: 'delta-pos' };
  if (delta < 0) return { text: `${delta}`, cls: 'delta-neg' };
  return { text: '0', cls: 'delta-null' };
}

function fmtTs(ts: number): string {
  const d = new Date(tsToMs(ts));
  const pad = (n: number): string => String(n).padStart(2, '0');
  return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function renderRecent(parent: HTMLElement, recent: RecentGame[]): void {
  parent.appendChild(el('h3', '', '最近 10 场'));
  if (recent.length === 0) {
    parent.appendChild(el('p', 'room-empty', '暂无对局记录'));
    return;
  }
  const list = el('ul', 'player-list recent-list');
  for (const r of recent) {
    const li = el('li', 'player-item recent-row');
    li.appendChild(el('span', 'recent-rank', `第${r.rank}名`));
    li.appendChild(el('span', 'recent-total', `${r.total} 分`));
    const d = fmtDelta(r.ladder_delta);
    li.appendChild(el('span', `recent-delta ${d.cls}`, d.text));
    const tags = el('span', 'player-tags');
    tags.appendChild(el('span', 'tag', `${r.room_size}人局`));
    if (r.has_bot) tags.appendChild(el('span', 'tag tag-bot', '人机局'));
    li.appendChild(tags);
    li.appendChild(el('span', 'recent-ts', fmtTs(r.ts)));
    list.appendChild(li);
  }
  parent.appendChild(list);
}

function renderInfoCard(s: AppState): HTMLElement {
  const card = el('div', 'panel profile-card profile-info');
  card.appendChild(el('div', 'profile-glow'));
  card.appendChild(el('h2', 'profile-card-title', '个人信息'));
  card.appendChild(el('p', 'profile-account', `账号：${s.accountName}`));

  if (s.myStatsLoading) {
    card.appendChild(el('p', 'room-empty', '战绩加载中…'));
    return card;
  }
  const st = s.myStats;
  if (!st) {
    card.appendChild(el('p', 'room-empty', '暂无战绩记录，完成一局对战后自动建档。'));
    return card;
  }
  const winRate = st.games > 0 ? `${Math.round((st.wins / st.games) * 100)}%` : '-';
  const grid = el('div', 'stats-grid');
  const items: [string, string][] = [
    ['总局数', `${st.games}`],
    ['胜场', `${st.wins}`],
    ['胜率', winRate],
    ['场均总分', `${st.avg_total}`],
    ['天梯分', `${st.ladder}`],
    ['历史最高', `${st.ladder_max}`],
  ];
  for (const [label, val] of items) {
    const cell = el('div', 'stats-cell');
    cell.appendChild(el('div', 'stats-val', val));
    cell.appendChild(el('div', 'stats-label', label));
    grid.appendChild(cell);
  }
  card.appendChild(grid);
  renderRecent(card, st.recent ?? []);
  return card;
}

function renderPasswordCard(a: AppActions): HTMLElement {
  const card = el('div', 'panel profile-card');
  card.appendChild(el('h2', 'profile-card-title', '修改密码'));
  card.appendChild(el('p', 'profile-hint', '修改成功后所有登录会话将失效，需使用新密码重新登录。'));

  if (pwdDraft.error) card.appendChild(el('div', 'form-error', pwdDraft.error));

  const form = el('div', 'modal-fields');
  const oldPw = el('input', 'input') as HTMLInputElement;
  oldPw.type = 'password'; oldPw.placeholder = '当前密码'; oldPw.maxLength = 256;
  oldPw.value = pwdDraft.oldPw;
  oldPw.oninput = () => { pwdDraft.oldPw = oldPw.value; };
  const newPw = el('input', 'input') as HTMLInputElement;
  newPw.type = 'password'; newPw.placeholder = '新密码（8-256 位）'; newPw.maxLength = 256;
  newPw.value = pwdDraft.newPw;
  newPw.oninput = () => { pwdDraft.newPw = newPw.value; };
  const confirmPw = el('input', 'input') as HTMLInputElement;
  confirmPw.type = 'password'; confirmPw.placeholder = '确认新密码'; confirmPw.maxLength = 256;
  confirmPw.value = pwdDraft.confirmPw;
  confirmPw.oninput = () => { pwdDraft.confirmPw = confirmPw.value; };
  form.append(oldPw, newPw, confirmPw);
  card.appendChild(form);

  const submit = el('button', 'btn btn-primary btn-wide', pwdDraft.busy ? '正在提交…' : '确认修改') as HTMLButtonElement;
  submit.type = 'button';
  submit.disabled = pwdDraft.busy;
  submit.onclick = () => a.changePassword(oldPw.value, newPw.value, confirmPw.value);
  card.appendChild(submit);
  return card;
}

function renderManualCard(a: AppActions): HTMLElement {
  const card = el('div', 'panel profile-card');
  card.appendChild(el('h2', 'profile-card-title', '游戏说明'));
  card.appendChild(el('p', 'profile-hint', '完整规则文档：目标、行动、潮汐、市场、订单与终局计分，可随时查阅。'));
  const openBtn = el('button', 'btn btn-ghost btn-wide', '查看游戏说明') as HTMLButtonElement;
  openBtn.type = 'button';
  openBtn.onclick = () => a.openManual('profile');
  card.appendChild(openBtn);
  return card;
}

export function renderProfile(root: HTMLElement, s: AppState, a: AppActions): void {
  clear(root);
  const screen = el('div', 'profile-screen');
  const topbar = el('div', 'profile-topbar');
  const backBtn = el('button', 'btn btn-ghost btn-small', '← 返回首页') as HTMLButtonElement;
  backBtn.type = 'button';
  backBtn.onclick = () => a.gotoLobby();
  topbar.appendChild(backBtn);
  topbar.appendChild(el('h1', 'profile-title', '个人中心'));
  screen.appendChild(topbar);

  const grid = el('div', 'profile-grid');
  grid.appendChild(renderInfoCard(s));
  const side = el('div', 'profile-side');
  side.appendChild(renderPasswordCard(a));
  side.appendChild(renderManualCard(a));
  grid.appendChild(side);
  screen.appendChild(grid);
  root.appendChild(screen);
}
