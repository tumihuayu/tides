import {
  ACTION_NAME,
  CARD_BY_ID,
  GOOD_ICON,
  GOOD_NAME,
  GOODS,
  MODE_NAME,
  PHASE_NAME,
  PORTS,
  PORT_NAME,
  SCORE_KEY_NAME,
  TIDE_NAME,
  TIDE_ORDER,
} from './data';
import type { AppActions, AppState } from './ui';
import { clear, el, openModal, toast } from './ui';
import type {
  Card,
  Contract,
  Good,
  PlayerStats,
  PublicPlayer,
  RevealPlay,
  ScoreEntry,
} from './types';

function myPortId(s: AppState): string | null {
  if (!s.publicState || !s.playerId) return null;
  for (const p of s.publicState.ports) {
    if (p.ships.includes(s.playerId)) return p.id;
  }
  return null;
}

function adjacentPorts(portId: string | null): string[] {
  if (!portId) return PORTS.map((p) => p.id);
  const info = PORTS.find((p) => p.id === portId);
  return info ? info.adj : PORTS.map((p) => p.id);
}

function goodLabel(g: string): string {
  return `${GOOD_ICON[g] ?? ''} ${GOOD_NAME[g] ?? g}`;
}

function contractText(c: Contract): string {
  const req = c.requires.map((r) => `${GOOD_NAME[r.good]}×${r.count}`).join(' + ');
  const coins = c.reward_coins > 0 ? `，金币+${c.reward_coins}` : '';
  return `${c.name}｜需求：${req}｜奖励：${c.reward_vp}分${coins}`;
}

function fulfillable(c: Contract, cargo: string[]): boolean {
  const pool = [...cargo];
  for (const r of c.requires) {
    for (let i = 0; i < r.count; i += 1) {
      let idx = pool.indexOf(r.good);
      if (idx < 0) idx = pool.indexOf('wild');
      if (idx < 0) return false;
      pool.splice(idx, 1);
    }
  }
  return true;
}

function renderTideTrack(parent: HTMLElement, s: AppState): void {
  const track = el('div', 'tide-track');
  for (const t of TIDE_ORDER) {
    const cell = el('div', 'tide-cell' + (s.publicState?.tide === t ? ' active' : ''), TIDE_NAME[t]);
    track.appendChild(cell);
  }
  parent.appendChild(track);
}

function renderPorts(parent: HTMLElement, s: AppState): void {
  const ps = s.publicState;
  if (!ps) return;
  const zone = el('div', 'ports-zone');
  for (const port of PORTS) {
    const st = ps.ports.find((p) => p.id === port.id);
    const card = el('div', 'port-card');
    card.appendChild(el('div', 'port-name', port.name));
    const ships = el('div', 'port-row');
    ships.appendChild(el('span', 'port-label', '船只：'));
    if (st && st.ships.length > 0) {
      for (const pid of st.ships) {
        const pl = ps.players.find((x) => x.id === pid);
        ships.appendChild(el('span', 'ship-tag' + (pid === s.playerId ? ' me' : ''), `⛵${pl?.name ?? pid}`));
      }
    } else {
      ships.appendChild(el('span', 'port-empty', '无'));
    }
    card.appendChild(ships);
    const posts = el('div', 'port-row');
    posts.appendChild(el('span', 'port-label', '商站：'));
    if (st && st.posts.length > 0) {
      for (const po of st.posts) {
        const pl = ps.players.find((x) => x.id === po.player_id);
        posts.appendChild(el('span', 'post-tag' + (po.player_id === s.playerId ? ' me' : ''), `🏛${pl?.name ?? po.player_id}`));
      }
    } else {
      posts.appendChild(el('span', 'port-empty', '无'));
    }
    card.appendChild(posts);
    zone.appendChild(card);
  }
  parent.appendChild(zone);
}

function renderMarket(parent: HTMLElement, s: AppState): void {
  const ps = s.publicState;
  if (!ps) return;
  const box = el('div', 'panel market');
  box.appendChild(el('h3', '', '货物市价'));
  for (const g of GOODS) {
    const row = el('div', 'market-row');
    row.appendChild(el('span', `good-dot good-${g}`));
    row.appendChild(el('span', 'market-good', GOOD_NAME[g]));
    row.appendChild(el('span', 'market-price', `${ps.market[g]} 金币`));
    box.appendChild(row);
  }
  parent.appendChild(box);
}

function renderContracts(parent: HTMLElement, s: AppState): void {
  const ps = s.publicState;
  if (!ps) return;
  const box = el('div', 'panel contracts');
  box.appendChild(el('h3', '', '公开订单'));
  if (ps.public_contracts.length === 0) {
    box.appendChild(el('div', 'port-empty', '暂无'));
  }
  for (const c of ps.public_contracts) {
    box.appendChild(el('div', 'contract-item', contractText(c)));
  }
  box.appendChild(el('h3', '', '我的隐藏订单'));
  const hidden = s.privateState?.hidden_contracts ?? [];
  if (hidden.length === 0) {
    box.appendChild(el('div', 'port-empty', '暂无'));
  }
  for (const c of hidden) {
    box.appendChild(el('div', 'contract-item hidden-contract', contractText(c)));
  }
  parent.appendChild(box);
}

function optionGroup(title: string): { wrap: HTMLElement; group: HTMLElement } {
  const wrap = el('div', 'opt-group');
  wrap.appendChild(el('div', 'opt-title', title));
  const group = el('div', 'opt-btns');
  wrap.appendChild(group);
  return { wrap, group };
}

function pickOne(group: HTMLElement, label: string, onPick: () => void): HTMLButtonElement {
  const b = el('button', 'btn btn-opt', label) as HTMLButtonElement;
  b.onclick = () => {
    group.querySelectorAll('.btn-opt').forEach((n) => n.classList.remove('picked'));
    b.classList.add('picked');
    onPick();
  };
  group.appendChild(b);
  return b;
}

function buildTradeFields(body: HTMLElement, onChange: (t: Record<string, unknown> | null) => void): void {
  let kind: 'buy' | 'sell' | null = null;
  let good: Good | null = null;
  let count = 1;
  const emit = (): void => {
    onChange(kind && good ? { kind, good, count: kind === 'sell' ? 1 : count } : null);
  };

  const countG = optionGroup('数量（买入最多 2）');
  pickOne(countG.group, '1', () => {
    count = 1;
    emit();
  });
  pickOne(countG.group, '2', () => {
    count = 2;
    emit();
  });

  const kindG = optionGroup('买 / 卖');
  pickOne(kindG.group, '买入', () => {
    kind = 'buy';
    countG.wrap.classList.remove('hidden');
    emit();
  });
  pickOne(kindG.group, '卖出（1 件）', () => {
    kind = 'sell';
    countG.wrap.classList.add('hidden');
    emit();
  });
  body.appendChild(kindG.wrap);

  const goodG = optionGroup('货物');
  for (const g of GOODS) {
    pickOne(goodG.group, goodLabel(g), () => {
      good = g;
      emit();
    });
  }
  body.appendChild(goodG.wrap);

  body.appendChild(countG.wrap);
}

function startCardFlow(s: AppState, a: AppActions, card: Card): void {
  if (s.phase !== 'select' || s.iSubmitted) return;
  const body = el('div', 'mode-select');
  const info = el('div', 'modal-card-info', `${card.name}｜行动：${ACTION_NAME[card.action]}｜货物：${GOOD_NAME[card.cargo]}｜潮纹：${card.tide}`);
  body.appendChild(info);
  const btns = el('div', 'opt-btns');
  const actBtn = el('button', 'btn btn-tide', '执行行动') as HTMLButtonElement;
  actBtn.onclick = () => {
    h.close();
    startTargetFlow(s, a, card);
  };
  const cargoBtn = el('button', 'btn btn-ghost', `留作货物（${GOOD_NAME[card.cargo]}）`) as HTMLButtonElement;
  cargoBtn.onclick = () => {
    h.close();
    a.submitCard(card.uid, 'cargo');
  };
  const tideBtn = el('button', 'btn btn-ghost', `推进潮汐（+${card.tide}）`) as HTMLButtonElement;
  tideBtn.onclick = () => {
    h.close();
    a.submitCard(card.uid, 'tide');
  };
  btns.appendChild(actBtn);
  btns.appendChild(cargoBtn);
  btns.appendChild(tideBtn);
  body.appendChild(btns);
  const h = openModal(`打出「${card.name}」`, body);
}

function startTargetFlow(s: AppState, a: AppActions, card: Card): void {
  const body = el('div', 'target-select');
  let target: Record<string, unknown> | null = null;
  const myPort = myPortId(s);

  switch (card.action) {
    case 'sail': {
      const g = optionGroup(`选择目的港（当前：${myPort ? PORT_NAME[myPort] : '未知'}，仅相邻）`);
      for (const pid of adjacentPorts(myPort)) {
        pickOne(g.group, PORT_NAME[pid] ?? pid, () => {
          target = { to_port: pid };
        });
      }
      body.appendChild(g.wrap);
      break;
    }
    case 'trade': {
      buildTradeFields(body, (t) => {
        target = t;
      });
      break;
    }
    case 'deliver': {
      const cargo = s.privateState?.cargo ?? [];
      const all = [...(s.publicState?.public_contracts ?? []), ...(s.privateState?.hidden_contracts ?? [])];
      const ok = all.filter((c) => fulfillable(c, cargo));
      if (ok.length === 0) {
        body.appendChild(el('div', 'port-empty', '当前没有可交付的订单（货物不足）'));
        break;
      }
      const g = optionGroup('选择要交付的订单');
      for (const c of ok) {
        pickOne(g.group, contractText(c), () => {
          target = { contract_id: c.id };
        });
      }
      body.appendChild(g.wrap);
      break;
    }
    case 'post': {
      target = { port: myPort };
      body.appendChild(el('div', 'modal-card-info', `在当前港口（${myPort ? PORT_NAME[myPort] : '未知'}）设立商站`));
      break;
    }
    case 'tidecraft': {
      const g = optionGroup('选择秘术效果');
      pickOne(g.group, '窥视（查看下一张牌）', () => {
        target = { op: 'peek' };
      });
      pickOne(g.group, '推移潮汐 +1', () => {
        target = { op: 'shift', delta: 1 };
      });
      pickOne(g.group, '推移潮汐 -1', () => {
        target = { op: 'shift', delta: -1 };
      });
      body.appendChild(g.wrap);
      break;
    }
    case 'tailwind': {
      let toPort: string | null = null;
      let trade: Record<string, unknown> | null = null;
      const sync = (): void => {
        target = toPort && trade ? { to_port: toPort, ...trade } : null;
      };
      const g = optionGroup(`航行至（当前：${myPort ? PORT_NAME[myPort] : '未知'}，仅相邻）`);
      for (const pid of adjacentPorts(myPort)) {
        pickOne(g.group, PORT_NAME[pid] ?? pid, () => {
          toPort = pid;
          sync();
        });
      }
      body.appendChild(g.wrap);
      buildTradeFields(body, (t) => {
        trade = t;
        sync();
      });
      break;
    }
  }

  openModal(
    `行动：${ACTION_NAME[card.action]}`,
    body,
    () => {
      if (!target) {
        toast('请先完成目标选择', 'error');
        return false;
      }
      a.submitCard(card.uid, 'action', target);
      return true;
    },
    '确认打出',
  );
}

function renderHand(parent: HTMLElement, s: AppState, a: AppActions): void {
  const bar = el('div', 'hand-bar');
  const status = el('div', 'my-status');
  const me: PublicPlayer | undefined = s.publicState?.players.find((p) => p.id === s.playerId);
  status.appendChild(el('span', 'coins', `金币：${me?.coins ?? 0}`));
  status.appendChild(el('span', 'vp', `分数：${me?.vp ?? 0}`));
  const cargo = el('span', 'cargo-list');
  cargo.appendChild(el('span', 'port-label', '货物区：'));
  const cg = s.privateState?.cargo ?? [];
  if (cg.length === 0) cargo.appendChild(el('span', 'port-empty', '空'));
  for (const g of cg) {
    const tag = el('span', `cargo-tag good-${g}`);
    tag.appendChild(el('span', `good-dot good-${g}`));
    tag.appendChild(document.createTextNode(GOOD_NAME[g] ?? g));
    cargo.appendChild(tag);
  }
  status.appendChild(cargo);
  bar.appendChild(status);

  const hand = el('div', 'hand');
  const canPlay = s.phase === 'select' && !s.iSubmitted;
  for (const c of s.privateState?.hand ?? []) {
    const card = el('div', `card action-${c.action}` + (canPlay ? '' : ' disabled'));
    card.appendChild(el('div', 'card-name', c.name));
    card.appendChild(el('div', 'card-action', ACTION_NAME[c.action] ?? c.action));
    const meta = el('div', 'card-meta');
    const cargoSpan = el('span', 'card-cargo');
    cargoSpan.appendChild(el('span', `good-dot good-${c.cargo}`));
    cargoSpan.appendChild(document.createTextNode(GOOD_NAME[c.cargo] ?? c.cargo));
    meta.appendChild(cargoSpan);
    meta.appendChild(el('span', 'card-tide', `潮纹 ${c.tide > 0 ? '~'.repeat(c.tide) : '0'}`));
    card.appendChild(meta);
    if (canPlay) {
      card.onclick = () => startCardFlow(s, a, c);
    }
    hand.appendChild(card);
  }
  bar.appendChild(hand);
  parent.appendChild(bar);
}

function renderPlayersRow(parent: HTMLElement, s: AppState): void {
  const ps = s.publicState;
  if (!ps) return;
  const row = el('div', 'players-row');
  for (const p of ps.players) {
    const chip = el('div', 'player-chip' + (p.id === s.playerId ? ' me' : '') + (p.connected ? '' : ' offline'));
    chip.appendChild(el('span', 'chip-name', p.name));
    if (p.is_bot) {
      chip.appendChild(el('span', p.difficulty === 'hard' ? 'tag tag-bot-hard' : 'tag tag-bot', p.difficulty === 'hard' ? '人机·困难' : '人机·简单'));
    } else if (p.auto_pilot) {
      chip.appendChild(el('span', 'tag tag-autopilot', '托管中'));
    }
    chip.appendChild(el('span', 'chip-info', `${p.coins}金 ${p.vp}分 货${p.cargo_count}`));
    chip.appendChild(el('span', p.submitted ? 'chip-sub ok' : 'chip-sub', p.submitted ? '已提交' : '思考中'));
    row.appendChild(chip);
  }
  parent.appendChild(row);
}

function renderLog(parent: HTMLElement, s: AppState): void {
  const box = el('div', 'panel action-log');
  box.appendChild(el('h3', '', '行动日志'));
  const list = el('div', 'log-list');
  for (const entry of s.logs) {
    list.appendChild(el('div', 'log-entry', entry));
  }
  box.appendChild(list);
  parent.appendChild(box);
  window.setTimeout(() => {
    list.scrollTop = list.scrollHeight;
  }, 0);
}

function confirmLeaveGame(a: AppActions): void {
  const body = el('div', 'leave-confirm');
  body.appendChild(el('div', 'modal-card-info', '退出将被判定为本局失败（末名），本局由 AI 托管打完，无法重新加入。'));
  openModal(
    '退出对战？',
    body,
    () => {
      a.leaveGame();
      return true;
    },
    '确认退出',
  );
}

export function renderGame(root: HTMLElement, s: AppState, a: AppActions): void {
  clear(root);
  const ps = s.publicState;
  const layout = el('div', 'game-layout');

  if (s.roomMode === 'tutorial_practice') {
    const notice = el('div', 'panel practice-notice');
    notice.appendChild(el('strong', '', '新手陪练 · tutorial_practice'));
    notice.appendChild(el('span', '', ' 正式 4 轮 × 3 回合规则；本局不计入正式战绩、天梯或排行榜。'));
    layout.appendChild(notice);
  }

  const top = el('div', 'game-top');
  renderTideTrack(top, s);
  const info = el('div', 'game-info');
  info.appendChild(el('span', 'round-info', `轮次 ${ps?.round ?? '-'} / 4 · 回合 ${ps?.turn ?? '-'} / 3`));
  info.appendChild(el('span', 'phase-info', PHASE_NAME[s.phase ?? ''] ?? '等待中'));
  const timer = el('span', 'phase-timer');
  timer.id = 'phase-timer';
  info.appendChild(timer);
  if (s.phase === 'select' || s.phase === 'resolve') {
    const leaveBtn = el('button', 'btn btn-danger btn-small', '退出对战') as HTMLButtonElement;
    leaveBtn.onclick = () => confirmLeaveGame(a);
    info.appendChild(leaveBtn);
  }
  top.appendChild(info);
  renderPlayersRow(top, s);
  layout.appendChild(top);

  const mid = el('div', 'game-mid');
  const left = el('div', 'game-left');
  renderMarket(left, s);
  renderLog(left, s);
  mid.appendChild(left);
  const center = el('div', 'game-center');
  renderPorts(center, s);
  mid.appendChild(center);
  const right = el('div', 'game-right');
  renderContracts(right, s);
  mid.appendChild(right);
  layout.appendChild(mid);

  renderHand(layout, s, a);
  root.appendChild(layout);
}

export function showWaitingMask(show: boolean, s: AppState): void {
  const root = document.getElementById('overlay-root');
  if (!root) return;
  const old = document.getElementById('mask-waiting');
  if (old) old.remove();
  if (!show) return;
  const ps = s.publicState;
  const total = ps?.players.length ?? 0;
  const submitted = ps?.players.filter((p) => p.submitted).length ?? 0;
  const mask = el('div', 'mask');
  mask.id = 'mask-waiting';
  const box = el('div', 'mask-box');
  box.appendChild(el('div', 'mask-title', '已提交，等待其他玩家…'));
  box.appendChild(el('div', 'mask-count', `已提交 ${submitted} / ${total}`));
  box.appendChild(el('div', 'mask-spinner'));
  mask.appendChild(box);
  root.appendChild(mask);
}

export function showReveal(plays: RevealPlay[], s: AppState): void {
  const root = document.getElementById('overlay-root');
  if (!root) return;
  const old = document.getElementById('mask-reveal');
  if (old) old.remove();
  const mask = el('div', 'mask');
  mask.id = 'mask-reveal';
  const box = el('div', 'mask-box reveal-box');
  box.appendChild(el('div', 'mask-title', '亮牌！'));
  for (const p of plays) {
    const pl = s.publicState?.players.find((x) => x.id === p.player_id);
    const card = CARD_BY_ID.get(p.card_id);
    const row = el('div', 'reveal-row');
    row.appendChild(el('span', 'reveal-player', pl?.name ?? p.player_id));
    row.appendChild(el('span', 'reveal-card', card ? card.name : p.card_id));
    row.appendChild(el('span', 'reveal-mode', MODE_NAME[p.mode] ?? p.mode));
    box.appendChild(row);
  }
  mask.appendChild(box);
  root.appendChild(mask);
  window.setTimeout(() => mask.remove(), 2600);
}

let settlementRetry: (() => void) | null = null;

function settlementCells(box: HTMLElement): void {
  const rateCell = el('div', 'go-cell');
  rateCell.appendChild(el('div', 'go-cell-label', '近七天胜率'));
  const rate = el('div', 'go-cell-val', '…');
  rate.id = 'go-winrate';
  const rateSub = el('div', 'go-cell-sub');
  rateSub.id = 'go-winrate-sub';
  rateCell.appendChild(rate);
  rateCell.appendChild(rateSub);
  const streakCell = el('div', 'go-cell');
  streakCell.appendChild(el('div', 'go-cell-label', '连胜场次'));
  const streak = el('div', 'go-cell-val', '…');
  streak.id = 'go-streak';
  streakCell.appendChild(streak);
  box.appendChild(rateCell);
  box.appendChild(streakCell);
}

export function settlementStatsLoading(): void {
  const box = document.getElementById('go-stats');
  if (!box) return;
  clear(box);
  settlementCells(box);
}

export function updateSettlementStats(stats: PlayerStats | null): void {
  const box = document.getElementById('go-stats');
  if (!box) return;
  clear(box);
  settlementCells(box);
  const games7d = stats?.games_7d ?? 0;
  const wins7d = stats?.wins_7d ?? 0;
  const rate = document.getElementById('go-winrate');
  const rateSub = document.getElementById('go-winrate-sub');
  const streak = document.getElementById('go-streak');
  if (rate) rate.textContent = games7d > 0 ? `${Math.round((wins7d / games7d) * 100)}%` : '—';
  if (rateSub) rateSub.textContent = games7d > 0 ? `${wins7d}胜/${games7d}场` : '近 7 天暂无对局';
  const winStreak = stats?.win_streak ?? 0;
  if (streak) {
    streak.textContent = winStreak > 0 ? `连胜 ${winStreak} 场` : '暂无连胜';
    streak.classList.toggle('gold', winStreak >= 2);
  }
  if (stats) {
    const myRow = document.getElementById('go-row-me');
    if (myRow && !document.getElementById('go-ladder-after')) {
      const line = el('div', 'go-ladder-after', `结算后天梯 ${stats.ladder}`);
      line.id = 'go-ladder-after';
      myRow.appendChild(line);
    }
  }
}

export function settlementStatsFailed(): void {
  const box = document.getElementById('go-stats');
  if (!box) return;
  clear(box);
  const note = el('div', 'go-stats-note');
  note.appendChild(el('span', '', '战绩统计加载失败'));
  const retry = el('button', 'btn btn-ghost btn-small', '重试') as HTMLButtonElement;
  retry.onclick = () => {
    settlementStatsLoading();
    settlementRetry?.();
  };
  note.appendChild(retry);
  box.appendChild(note);
}

export function showGameOver(scores: ScoreEntry[], s: AppState, a: AppActions, opts?: { onRetryStats?: () => void }): void {
  settlementRetry = opts?.onRetryStats ?? null;
  const root = document.getElementById('overlay-root');
  if (!root) return;
  const old = document.getElementById('mask-gameover');
  if (old) old.remove();
  const mask = el('div', 'mask');
  mask.id = 'mask-gameover';
  const box = el('div', 'mask-box gameover-box');
  const eligible = s.statsEligible;
  const meScore = scores.find((x) => x.player_id === s.playerId);

  if (!eligible) {
    box.appendChild(el('div', 'go-title go-title-end', '对局结束'));
  } else {
    const win = meScore?.rank === 1;
    box.appendChild(el('div', `go-title ${win ? 'go-title-win' : 'go-title-lose'}`, win ? '胜利' : '失败'));
    if (meScore) {
      const sub = el('div', 'go-subtitle');
      const d = meScore.ladder_delta;
      const delta = d === null || d === undefined ? '—' : d > 0 ? `+${d}` : `${d}`;
      sub.appendChild(el('span', '', `#${meScore.rank ?? '-'} · ${meScore.total} 分 · 天梯 ${delta}`));
      if (s.publicState?.players.some((p) => p.is_bot)) {
        sub.appendChild(el('span', 'tag', '人机局'));
      }
      box.appendChild(sub);
    }
  }

  const statsBox = el('div', 'go-stats');
  statsBox.id = 'go-stats';
  if (!eligible || s.accountStatus !== 'authenticated') {
    statsBox.appendChild(el('div', 'go-stats-note', '本局不计入正式战绩'));
  } else {
    settlementCells(statsBox);
  }
  box.appendChild(statsBox);

  const sorted = [...scores].sort((x, y) => y.total - x.total);
  sorted.forEach((sc, idx) => {
    const pl = s.publicState?.players.find((x) => x.id === sc.player_id);
    const isMe = sc.player_id === s.playerId;
    const isFirst = sc.rank === 1 || ((sc.rank === null || sc.rank === undefined) && idx === 0);
    const row = el('div', 'score-row' + (isFirst ? ' winner' : '') + (isMe ? ' me' : ''));
    if (isMe) row.id = 'go-row-me';
    const head = el('div', 'score-head');
    const nameSpan = el('span', 'score-name', `${isFirst ? '👑 ' : ''}${pl?.name ?? sc.player_id}`);
    if (sc.rage_quit) {
      nameSpan.appendChild(el('span', 'tag tag-autopilot', '退出'));
    }
    if (pl?.is_bot) {
      nameSpan.appendChild(el('span', pl.difficulty === 'hard' ? 'tag tag-bot-hard' : 'tag tag-bot', pl.difficulty === 'hard' ? '人机·困难' : '人机·简单'));
    } else if (pl?.auto_pilot) {
      nameSpan.appendChild(el('span', 'tag tag-autopilot', '托管完成'));
    }
    head.appendChild(nameSpan);
    const right = el('span', 'score-right');
    if (sc.rank !== null && sc.rank !== undefined) {
      right.appendChild(el('span', 'score-rank', `#${sc.rank}`));
    }
    if (sc.ladder_delta === null || sc.ladder_delta === undefined) {
      right.appendChild(el('span', 'score-delta delta-null', '-'));
    } else if (sc.ladder_delta > 0) {
      right.appendChild(el('span', 'score-delta delta-pos', `+${sc.ladder_delta}`));
    } else if (sc.ladder_delta < 0) {
      right.appendChild(el('span', 'score-delta delta-neg', `${sc.ladder_delta}`));
    } else {
      right.appendChild(el('span', 'score-delta delta-null', '0'));
    }
    right.appendChild(el('span', 'score-total', `${sc.total} 分`));
    head.appendChild(right);
    row.appendChild(head);
    const bd = el('div', 'score-breakdown');
    if (sc.breakdown && typeof sc.breakdown === 'object') {
      for (const [k, v] of Object.entries(sc.breakdown)) {
        const label = SCORE_KEY_NAME[k] ?? k;
        const val = typeof v === 'object' ? JSON.stringify(v) : String(v);
        bd.appendChild(el('div', 'score-item', `${label}：${val}`));
      }
    }
    row.appendChild(bd);
    box.appendChild(row);
  });
  const back = el('button', 'btn btn-gold btn-wide', '返回大厅') as HTMLButtonElement;
  back.onclick = () => {
    mask.remove();
    a.backToLobby();
  };
  box.appendChild(back);
  mask.appendChild(box);
  root.appendChild(mask);
}
