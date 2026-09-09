import type { AppActions, AppState } from './ui';
import { clear, el } from './ui';
import type { LeaderboardBoard, PlayerBrief } from './types';

const BOARD_NAME: Record<LeaderboardBoard, string> = {
  ladder: '天梯榜',
  wins: '胜场榜',
};

function botTag(p: PlayerBrief): HTMLElement {
  if (p.difficulty === 'hard') return el('span', 'tag tag-bot-hard', '人机·困难');
  return el('span', 'tag tag-bot', '人机·简单');
}

function renderLeaderboardPanel(body: HTMLElement, s: AppState, a: AppActions): void {
  const tabs = el('div', 'opt-btns lb-tabs');
  for (const b of ['ladder', 'wins'] as LeaderboardBoard[]) {
    const tab = el('button', 'btn btn-opt' + (s.lbBoard === b ? ' picked' : ''), BOARD_NAME[b]) as HTMLButtonElement;
    tab.onclick = () => a.setBoard(b);
    tabs.appendChild(tab);
  }
  body.appendChild(tabs);

  if (s.lbLoading) {
    body.appendChild(el('p', 'room-empty', '加载中…'));
    return;
  }
  const lb = s.leaderboard;
  if (!lb || lb.board !== s.lbBoard) {
    body.appendChild(el('p', 'room-empty', '加载中…'));
    return;
  }
  const selfLine = el('p', 'lb-self');
  selfLine.textContent =
    lb.self_rank !== null ? `我的名次：第 ${lb.self_rank} 名` : '我尚未上榜（需至少完成 5 场计分对局）';
  body.appendChild(selfLine);
  if (lb.entries.length === 0) {
    body.appendChild(el('p', 'room-empty', '榜单暂无数据'));
    return;
  }
  const table = el('table', 'lb-table');
  const thead = el('tr', 'lb-head');
  for (const h of ['名次', '昵称', '天梯分', '场次', '胜场', '胜率']) {
    thead.appendChild(el('th', '', h));
  }
  table.appendChild(thead);
  for (const e of lb.entries) {
    const tr = el('tr', e.rank === lb.self_rank ? 'lb-self-row' : '');
    tr.appendChild(el('td', '', `${e.rank}`));
    tr.appendChild(el('td', 'lb-name', e.name));
    tr.appendChild(el('td', '', `${e.ladder}`));
    tr.appendChild(el('td', '', `${e.games}`));
    tr.appendChild(el('td', '', `${e.wins}`));
    const rate = e.win_rate > 1 ? e.win_rate : e.win_rate * 100;
    tr.appendChild(el('td', '', `${Math.round(rate)}%`));
    table.appendChild(tr);
  }
  body.appendChild(table);
}

function renderPanelOverlay(root: HTMLElement, s: AppState, a: AppActions): void {
  if (s.panel === 'none') return;
  const mask = el('div', 'mask panel-mask');
  const box = el('div', 'mask-box panel-box');
  const head = el('div', 'room-head panel-head');
  head.appendChild(el('div', 'mask-title', '排行榜'));
  const closeBtn = el('button', 'btn btn-ghost btn-small', '关闭') as HTMLButtonElement;
  closeBtn.onclick = () => a.closePanel();
  head.appendChild(closeBtn);
  box.appendChild(head);
  const body = el('div', 'panel-body');
  renderLeaderboardPanel(body, s, a);
  box.appendChild(body);
  mask.appendChild(box);
  root.appendChild(mask);
}

function renderTopbar(s: AppState, a: AppActions): HTMLElement {
  const bar = el('div', 'lobby-topbar');
  bar.appendChild(el('span', 'lobby-account', s.accountName));
  const manualBtn = el('button', 'btn btn-icon', '?') as HTMLButtonElement;
  manualBtn.type = 'button';
  manualBtn.title = '游戏说明';
  manualBtn.onclick = () => a.openManual('lobby');
  bar.appendChild(manualBtn);
  const logoutBtn = el('button', 'btn btn-danger btn-small', '登出') as HTMLButtonElement;
  logoutBtn.type = 'button';
  logoutBtn.onclick = () => a.logoutAccount();
  bar.appendChild(logoutBtn);
  return bar;
}

function renderMyStatsCard(s: AppState): HTMLElement {
  const card = el('div', 'panel lobby-mystats');
  card.appendChild(el('h2', '', '个人战绩'));

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
    ['战斗场次', `${st.games}`],
    ['胜利次数', `${st.wins}`],
    ['胜率', winRate],
  ];
  for (const [label, val] of items) {
    const cell = el('div', 'stats-cell');
    cell.appendChild(el('div', 'stats-val', val));
    cell.appendChild(el('div', 'stats-label', label));
    grid.appendChild(cell);
  }
  card.appendChild(grid);
  return card;
}

export function renderLobby(root: HTMLElement, s: AppState, a: AppActions): void {
  clear(root);
  const wrap = el('div', 'lobby');
  wrap.appendChild(renderTopbar(s, a));
  wrap.appendChild(el('h1', 'game-logo', '潮汐商会'));
  wrap.appendChild(el('p', 'game-sub', '2-4 人 · 轻中策卡牌桌游'));

  if (!s.roomId) {
    wrap.appendChild(renderMyStatsCard(s));

    const navRow = el('div', 'room-btns lobby-stats-btns');
    const profileBtn = el('button', 'btn btn-primary', '个人中心') as HTMLButtonElement;
    profileBtn.onclick = () => a.openProfile();
    navRow.appendChild(profileBtn);
    const lbBtn = el('button', 'btn btn-ghost', '排行榜') as HTMLButtonElement;
    lbBtn.onclick = () => a.openPanel('leaderboard');
    navRow.appendChild(lbBtn);
    wrap.appendChild(navRow);

    const entry = el('div', 'panel lobby-entry');
    entry.appendChild(el('h2', '', '进入商会'));
    const nameRow = el('div', 'form-row');
    nameRow.appendChild(el('label', '', '昵称'));
    const nameInput = el('input', 'input') as HTMLInputElement;
    nameInput.maxLength = 12;
    nameInput.placeholder = '输入你的昵称';
    nameInput.value = s.playerName;
    nameRow.appendChild(nameInput);
    entry.appendChild(nameRow);

    const createBtn = el('button', 'btn btn-primary btn-wide', '创建房间') as HTMLButtonElement;
    createBtn.onclick = () => {
      const name = nameInput.value.trim();
      if (!name) {
        nameInput.focus();
        return;
      }
      a.createRoom(name);
    };
    entry.appendChild(createBtn);

    entry.appendChild(el('div', 'divider', '或'));

    const joinRow = el('div', 'form-row');
    joinRow.appendChild(el('label', '', '房间码'));
    const roomInput = el('input', 'input') as HTMLInputElement;
    roomInput.maxLength = 8;
    roomInput.placeholder = '如 A7Q2';
    joinRow.appendChild(roomInput);
    entry.appendChild(joinRow);
    const joinBtn = el('button', 'btn btn-secondary btn-wide', '加入房间') as HTMLButtonElement;
    joinBtn.onclick = () => {
      const name = nameInput.value.trim();
      const room = roomInput.value.trim().toUpperCase();
      if (!name || !room) return;
      a.joinRoom(name, room);
    };
    entry.appendChild(joinBtn);
    wrap.appendChild(entry);

    const online = el('div', 'panel lobby-online');
    const onlineHead = el('div', 'room-head');
    onlineHead.appendChild(el('h2', '', '在线房间'));
    const refreshBtn = el('button', 'btn btn-ghost', '刷新') as HTMLButtonElement;
    refreshBtn.onclick = () => a.refreshRooms();
    onlineHead.appendChild(refreshBtn);
    online.appendChild(onlineHead);

    const joinable = (r: { phase: string; player_count: number; max_players: number }) =>
      r.phase === 'lobby' && r.player_count < r.max_players;
    const phaseText = (phase: string): string => {
      if (phase === 'lobby') return '等待中';
      if (phase === 'game_over') return '已结束';
      return '游戏中';
    };

    if (s.roomList.length === 0) {
      online.appendChild(el('p', 'room-empty', '暂无在线房间，点击刷新或创建一个吧'));
    } else {
      const rlist = el('ul', 'player-list room-list');
      for (const r of s.roomList) {
        const li = el('li', 'player-item room-row');
        li.appendChild(el('span', 'room-code', r.room_id));
        li.appendChild(el('span', 'room-host', `房主 ${r.host_name}`));
        li.appendChild(el('span', 'room-count', `${r.player_count}/${r.max_players}`));
        li.appendChild(el('span', joinable(r) ? 'tag tag-ready' : 'tag', phaseText(r.phase)));
        const joinBtn2 = el('button', 'btn btn-secondary btn-small', '加入') as HTMLButtonElement;
        joinBtn2.disabled = !joinable(r);
        joinBtn2.onclick = () => {
          const name = nameInput.value.trim();
          if (!name) {
            nameInput.focus();
            return;
          }
          a.joinRoom(name, r.room_id);
        };
        li.appendChild(joinBtn2);
        rlist.appendChild(li);
      }
      online.appendChild(rlist);
    }
    wrap.appendChild(online);
  } else {
    const room = el('div', 'panel lobby-room');
    const head = el('div', 'room-head');
    head.appendChild(el('h2', '', `房间 ${s.roomId}`));
    head.appendChild(el('span', 'room-hint', '把房间码告诉好友即可加入'));
    room.appendChild(head);

    const me = s.players.find((p) => p.id === s.playerId);
    const list = el('ul', 'player-list');
    for (const p of s.players) {
      const li = el('li', 'player-item');
      const nameSpan = el('span', 'player-name', p.name + (p.id === s.playerId ? '（我）' : ''));
      li.appendChild(nameSpan);
      const tags = el('span', 'player-tags');
      if (p.host) tags.appendChild(el('span', 'tag tag-host', '房主'));
      if (p.is_bot) {
        tags.appendChild(botTag(p));
      } else {
        tags.appendChild(el('span', p.ready ? 'tag tag-ready' : 'tag', p.ready ? '已准备' : '未准备'));
        tags.appendChild(el('span', p.connected ? 'tag tag-online' : 'tag tag-offline', p.connected ? '在线' : '离线'));
        if (p.auto_pilot) tags.appendChild(el('span', 'tag tag-autopilot', '托管中'));
      }
      if (p.is_bot && me?.host) {
        const removeBtn = el('button', 'btn btn-ghost btn-small', '移除') as HTMLButtonElement;
        removeBtn.title = '将该人机移出房间';
        removeBtn.onclick = () => a.removeBot(p.id);
        tags.appendChild(removeBtn);
      }
      li.appendChild(tags);
      list.appendChild(li);
    }
    room.appendChild(list);

    const btns = el('div', 'room-btns');
    const readyBtn = el('button', 'btn btn-secondary', me?.ready ? '取消准备' : '准备') as HTMLButtonElement;
    readyBtn.onclick = () => a.setReady(!(me?.ready ?? false));
    btns.appendChild(readyBtn);
    if (me?.host) {
      if (s.players.length < 4) {
        const addEasyBtn = el('button', 'btn btn-secondary', '添加人机·简单') as HTMLButtonElement;
        addEasyBtn.title = '添加一名简单人机补位（加入即视为已准备）';
        addEasyBtn.onclick = () => a.addBot('easy');
        btns.appendChild(addEasyBtn);
        const addHardBtn = el('button', 'btn btn-secondary', '添加人机·困难') as HTMLButtonElement;
        addHardBtn.title = '困难人机很强，建议从1台开始';
        addHardBtn.onclick = () => a.addBot('hard');
        btns.appendChild(addHardBtn);
      }
      const allReady =
        s.players.length >= 2 &&
        s.players.length <= 4 &&
        s.players.every((p) => p.is_bot || p.ready);
      const startBtn = el('button', 'btn btn-primary', '开始游戏') as HTMLButtonElement;
      startBtn.disabled = !allReady;
      startBtn.title = allReady ? '' : '需要 2-4 人（含人机）且全员已准备';
      startBtn.onclick = () => a.startGame();
      btns.appendChild(startBtn);
    }
    room.appendChild(btns);
    wrap.appendChild(room);
  }
  root.appendChild(wrap);
  renderPanelOverlay(root, s, a);
}
