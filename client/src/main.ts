import './styles.css';
import { Net, clearAccountSession, clearCredentials, clearWsUrl, defaultWsUrl, loadAccountSession, loadCredentials, normalizeWsUrl, resolveWsUrl, saveAccountSession, saveCredentials, saveWsUrl } from './net';
import type { AppActions, AppState, ModalHandle } from './ui';
import { openModal, toast, tsToMs, el } from './ui';
import { renderLobby } from './lobby';
import { renderProfile, pwdDraft, resetPwdDraft } from './profile';
import { renderManual } from './manual';
import { renderGame, settlementStatsFailed, showGameOver, showReveal, showWaitingMask, updateSettlementStats } from './game';
import type { Phase, PlayerBrief, PlayerStats, PrivateState, PublicState, RevealPlay, RoomBrief, ScoreEntry } from './types';
import type { LeaderboardEntry, LeaderboardBoard } from './types';
import { renderTutorial } from './tutorial';
import { renderEntry } from './entry';

const state: AppState = {
  screen: loadAccountSession() ? 'lobby' : 'entry',
  playerName: localStorage.getItem('tides_name') ?? '',
  accountName: '',
  accountStatus: 'signed_out',
  accountNotice: null,
  roomId: null,
  playerId: null,
  players: [],
  publicState: null,
  privateState: null,
  phase: null,
  deadlineTs: null,
  iSubmitted: false,
  logs: [],
  roomList: [],
  panel: 'none',
  myStats: null,
  myStatsLoading: false,
  lbBoard: 'ladder',
  leaderboard: null,
  lbLoading: false,
  manualOpen: false,
  manualFrom: 'lobby',
  tutorialPage: 0,
  roomMode: 'normal',
  statsEligible: true,
  practiceStarting: false,
};

const net = new Net(defaultWsUrl());
let reconnectPending = false;
let pendingRegistration: { username: string; password: string } | null = null;
let settleStatsPending = false;
let settleStatsTimer: number | null = null;

function clearSettleStatsTimer(): void {
  if (settleStatsTimer !== null) {
    clearTimeout(settleStatsTimer);
    settleStatsTimer = null;
  }
}

function requestSettlementStats(): void {
  clearSettleStatsTimer();
  settleStatsPending = true;
  settleStatsTimer = window.setTimeout(() => {
    settleStatsPending = false;
    settleStatsTimer = null;
    settlementStatsFailed();
  }, 5000);
  if (net.send('get_my_stats', {}) === null) {
    clearSettleStatsTimer();
    settleStatsPending = false;
    settlementStatsFailed();
  }
}

const entryRoot = document.getElementById('screen-entry') as HTMLElement;
const tutorialRoot = document.getElementById('screen-tutorial') as HTMLElement;
const lobbyRoot = document.getElementById('screen-lobby') as HTMLElement;
const profileRoot = document.getElementById('screen-profile') as HTMLElement;
const gameRoot = document.getElementById('screen-game') as HTMLElement;
const overlayRoot = document.getElementById('overlay-root') as HTMLElement;
const banner = document.getElementById('banner') as HTMLElement;

interface AuthModalRef {
  handle: ModalHandle;
  showError(msg: string | null): void;
  clearPasswords(): void;
}
let authModal: AuthModalRef | null = null;

function closeAuthModal(): void {
  authModal?.handle.close();
  authModal = null;
}

function render(): void {
  entryRoot.classList.add('hidden');
  tutorialRoot.classList.add('hidden');
  lobbyRoot.classList.add('hidden');
  profileRoot.classList.add('hidden');
  gameRoot.classList.add('hidden');

  if (state.accountStatus !== 'authenticated') {
    if (state.screen === 'tutorial') {
      tutorialRoot.classList.remove('hidden');
      renderTutorial(tutorialRoot, state.tutorialPage, {
        next: actions.tutorialNext,
        previous: actions.tutorialPrevious,
        back: actions.tutorialBack,
        finish: actions.tutorialFinish,
        register: actions.registerFromTutorial,
      });
    } else {
      if (state.screen !== 'entry') state.screen = 'entry';
      entryRoot.classList.remove('hidden');
      renderEntry(entryRoot, {
        tutorial: () => {
          state.screen = 'tutorial';
          state.tutorialPage = 0;
          render();
        },
        login: () => openAccountModal('login'),
        register: () => openAccountModal('register'),
        applyServer: actions.applyServer,
        resetServer: actions.resetServer,
      });
    }
  } else if (state.screen === 'game') {
    gameRoot.classList.remove('hidden');
    renderGame(gameRoot, state, actions);
  } else if (state.screen === 'profile') {
    profileRoot.classList.remove('hidden');
    renderProfile(profileRoot, state, actions);
  } else {
    if (state.screen !== 'lobby') state.screen = 'lobby';
    lobbyRoot.classList.remove('hidden');
    renderLobby(lobbyRoot, state, actions);
  }

  if (state.manualOpen) {
    renderManual(overlayRoot, { close: actions.closeManual });
  } else {
    const settlementMask = document.getElementById('mask-gameover');
    overlayRoot.replaceChildren();
    if (settlementMask) overlayRoot.appendChild(settlementMask);
  }
}

function clearRoomState(): void {
  reconnectPending = false;
  clearCredentials();
  state.roomId = null;
  state.playerId = null;
  state.players = [];
  state.publicState = null;
  state.privateState = null;
  state.phase = null;
  state.deadlineTs = null;
  state.iSubmitted = false;
  state.logs = [];
  state.roomMode = 'normal';
  state.statsEligible = true;
  state.practiceStarting = false;
  net.roomId = null;
  net.playerId = null;
}

function requestMyStats(): void {
  if (state.accountStatus !== 'authenticated') return;
  state.myStatsLoading = true;
  net.send('get_my_stats', {});
}

function setAuthenticated(session: string, accountName: string): void {
  saveAccountSession(session);
  pendingRegistration = null;
  closeAuthModal();
  state.accountName = accountName;
  state.accountStatus = 'authenticated';
  state.accountNotice = null;
  state.screen = 'lobby';
  requestMyStats();
  render();
}

function backToEntry(notice: string | null): void {
  clearAccountSession();
  clearRoomState();
  pendingRegistration = null;
  resetPwdDraft();
  closeAuthModal();
  state.accountName = '';
  state.accountStatus = 'signed_out';
  state.accountNotice = null;
  state.myStats = null;
  state.myStatsLoading = false;
  state.manualOpen = false;
  state.panel = 'none';
  state.screen = 'entry';
  if (notice) toast(notice, 'success');
  render();
}

function openAccountModal(mode: 'login' | 'register'): void {
  const body = document.createElement('div');
  const errorBar = el('div', 'form-error hidden');
  body.appendChild(errorBar);
  const fields = document.createElement('div'); fields.className = 'modal-fields';
  const username = document.createElement('input'); username.className = 'input'; username.placeholder = '账号名'; username.maxLength = 24;
  const password = document.createElement('input'); password.className = 'input'; password.placeholder = '密码'; password.type = 'password'; password.maxLength = 64;
  fields.append(username, password);
  let confirm: HTMLInputElement | null = null;
  if (mode === 'register') {
    confirm = document.createElement('input'); confirm.className = 'input'; confirm.placeholder = '确认密码'; confirm.type = 'password'; confirm.maxLength = 64;
    fields.appendChild(confirm);
  }
  body.appendChild(fields);
  let modal: ModalHandle | null = null;
  const showError = (msg: string | null): void => {
    errorBar.classList.toggle('hidden', msg === null);
    errorBar.textContent = msg ?? '';
  };
  const clearPasswords = (): void => {
    password.value = '';
    if (confirm) confirm.value = '';
  };
  const btns = document.createElement('div'); btns.className = 'modal-btns';
  if (mode === 'login') {
    const loginBtn = document.createElement('button'); loginBtn.className = 'btn btn-primary'; loginBtn.textContent = '登录';
    loginBtn.onclick = () => {
      const u = username.value.trim(); const p = password.value;
      if (!u || !p) {
        showError('请输入账号名和密码。');
        return;
      }
      showError('正在登录…');
      actions.loginAccount(u, p);
    };
    const toRegister = document.createElement('button'); toRegister.className = 'btn btn-ghost'; toRegister.textContent = '没有账号？去注册';
    toRegister.onclick = () => { modal?.close(); authModal = null; openAccountModal('register'); };
    btns.append(loginBtn, toRegister);
  } else {
    const registerBtn = document.createElement('button'); registerBtn.className = 'btn btn-primary'; registerBtn.textContent = '注册';
    registerBtn.onclick = () => {
      const err = validateRegistration(username.value.trim(), password.value, confirm?.value ?? '');
      if (err) {
        showError(err);
        return;
      }
      showError('正在注册…');
      actions.registerAccount(username.value.trim(), password.value, confirm?.value ?? '');
    };
    const toLogin = document.createElement('button'); toLogin.className = 'btn btn-ghost'; toLogin.textContent = '已有账号？去登录';
    toLogin.onclick = () => { modal?.close(); authModal = null; openAccountModal('login'); };
    btns.append(registerBtn, toLogin);
  }
  body.appendChild(btns);
  modal = openModal(mode === 'login' ? '登录' : '注册', body);
  authModal = { handle: modal, showError, clearPasswords };
}

function validateRegistration(username: string, password: string, confirmPassword: string): string | null {
  if (!username) return '请输入账号名。';
  if (username.length < 3 || username.length > 64 || !/^[A-Za-z0-9_-]+$/.test(username)) {
    return '账号名需 3-64 位，仅限字母、数字、下划线、连字符。';
  }
  if (!password) return '请输入密码。';
  if (password.length < 8 || password.length > 256) return '密码需 8-256 位。';
  if (password !== confirmPassword) return '两次输入的密码不一致。';
  return null;
}

const ACCOUNT_ERROR_TEXT: Record<string, string> = {
  invalid_credentials: '账号名或密码错误',
  invalid_credentials_format: '账号名需 3-64 位，仅限字母、数字、下划线、连字符',
  account_exists: '该账号名已被注册',
  name_too_short: '账号名需 3-64 位，仅限字母、数字、下划线、连字符',
  name_too_long: '账号名需 3-64 位，仅限字母、数字、下划线、连字符',
  name_invalid_chars: '账号名需 3-64 位，仅限字母、数字、下划线、连字符',
  password_too_short: '密码需 8-256 位',
  password_too_long: '密码需 8-256 位',
  already_authenticated: '当前连接已登录',
  not_authenticated: '请先登录',
  account_error: '账号服务异常，请稍后重试',
};

const PWD_ERROR_TEXT: Record<string, string> = {
  wrong_old_password: '当前密码错误',
  same_password: '新密码不能与当前密码相同',
  password_too_short: '新密码需 8-256 位',
  password_too_long: '新密码需 8-256 位',
  rate_limited: '操作过于频繁，请稍后再试',
  not_authenticated: '请先登录',
  already_in_room: '请先离开房间后再修改密码',
  account_error: '账号服务异常，请稍后重试',
};

const actions: AppActions = {
  registerFromTutorial() {
    openAccountModal('register');
  },
  registerAccount(_username, password, confirmPassword): boolean {
    const err = validateRegistration(_username, password, confirmPassword);
    if (err) {
      authModal?.showError(err);
      return false;
    }
    if (net.send('register', { account_name: _username, password }) === null) {
      pendingRegistration = null;
      authModal?.showError('网络异常，请稍后重试');
      return false;
    }
    pendingRegistration = { username: _username, password };
    return true;
  },
  loginAccount(_username, _password) {
    if (!_username || !_password) {
      authModal?.showError('请输入账号名和密码。');
      return;
    }
    clearAccountSession();
    if (net.send('login', { account_name: _username, password: _password }) === null) {
      authModal?.showError('网络异常，请稍后重试');
    }
  },
  logoutAccount() {
    if (state.roomId || reconnectPending) {
      toast('账号已在房间中，请先离开房间后再登出', 'error');
      return;
    }
    if (net.send('logout', {}) === null) {
      toast('连接已断开，无法登出，请连接恢复后重试', 'error');
    }
  },
  changePassword(oldPassword, newPassword, confirmPassword) {
    if (!oldPassword) {
      pwdDraft.error = '请输入当前密码';
    } else if (newPassword.length < 8 || newPassword.length > 256) {
      pwdDraft.error = '新密码需 8-256 位';
    } else if (newPassword !== confirmPassword) {
      pwdDraft.error = '两次输入的密码不一致';
    } else if (newPassword === oldPassword) {
      pwdDraft.error = '新密码不能与当前密码相同';
    } else {
      pwdDraft.error = null;
      pwdDraft.busy = true;
      if (net.sendChangePassword(oldPassword, newPassword) === null) {
        pwdDraft.busy = false;
        pwdDraft.error = '网络异常，请稍后重试';
      }
    }
    render();
  },
  createRoom(name) {
    if (state.accountStatus !== 'authenticated') { state.screen = 'entry'; render(); return; }
    if (state.roomId || reconnectPending) {
      toast('已在房间中，无法创建新房间', 'error');
      return;
    }
    state.playerName = name;
    localStorage.setItem('tides_name', name);
    net.send('create_room', { player_name: name });
  },
  joinRoom(name, roomId) {
    if (state.accountStatus !== 'authenticated') { state.screen = 'entry'; render(); return; }
    if (state.roomId || reconnectPending) {
      toast('已在房间中，无法加入其他房间', 'error');
      return;
    }
    state.playerName = name;
    localStorage.setItem('tides_name', name);
    net.send('join_room', { room_id: roomId, player_name: name });
  },
  setReady(ready) {
    net.send('ready', { ready });
  },
  startGame() {
    net.send('start_game', {});
  },
  addBot(difficulty) {
    net.send('add_bot', { difficulty });
  },
  removeBot(playerId) {
    net.send('remove_bot', { player_id: playerId });
  },
  submitCard(cardUid, mode, target) {
    const payload: Record<string, unknown> = { card_uid: cardUid, mode };
    if (target) payload.target = target;
    const id = net.send('submit_card', payload);
    if (id === null) {
      toast('连接已断开，无法提交', 'error');
      return;
    }
    state.iSubmitted = true;
    render();
    showWaitingMask(true, state);
  },
  leaveGame() {
    if (net.send('leave_game', {}) === null) {
      toast('连接已断开，无法退出对战', 'error');
    }
  },
  backToLobby() {
    clearRoomState();
    state.screen = 'lobby';
    requestMyStats();
    render();
    actions.refreshRooms();
  },
  gotoLobby() {
    state.screen = 'lobby';
    render();
    actions.refreshRooms();
  },
  openProfile() {
    if (state.accountStatus !== 'authenticated') { state.screen = 'entry'; render(); return; }
    resetPwdDraft();
    state.screen = 'profile';
    state.myStatsLoading = true;
    net.send('get_my_stats', {});
    render();
  },
  openManual(from) {
    state.manualFrom = from;
    state.manualOpen = true;
    render();
  },
  closeManual() {
    state.manualOpen = false;
    state.screen = state.manualFrom === 'profile' ? 'profile' : 'lobby';
    render();
  },
  applyServer(url) {
    if (!url) return;
    const normalized = normalizeWsUrl(url);
    saveWsUrl(normalized);
    net.url = normalized;
    net.disconnect();
    net.connect();
    toast('已切换服务器地址');
  },
  resetServer() {
    clearWsUrl();
    net.url = resolveWsUrl().url;
    net.disconnect();
    net.connect();
    toast('已恢复自动服务器地址');
    if (state.screen === 'entry') render();
  },
  refreshRooms() {
    if (state.accountStatus !== 'authenticated') return;
    net.send('list_rooms', {});
  },
  openPanel(panel) {
    if (state.accountStatus !== 'authenticated') { state.screen = 'entry'; render(); return; }
    state.panel = panel;
    if (panel === 'leaderboard') {
      state.lbLoading = true;
      net.send('get_leaderboard', { board: state.lbBoard, limit: 100 });
    }
    render();
  },
  closePanel() {
    state.panel = 'none';
    if (state.screen === 'lobby') render();
  },
  setBoard(board) {
    if (state.lbBoard === board && state.leaderboard?.board === board) return;
    state.lbBoard = board;
    state.lbLoading = true;
    net.send('get_leaderboard', { board, limit: 100 });
    if (state.screen === 'lobby') render();
  },
  tutorialNext() { state.tutorialPage = Math.min(2, state.tutorialPage + 1); render(); },
  tutorialPrevious() { state.tutorialPage = Math.max(0, state.tutorialPage - 1); render(); },
  tutorialBack() { state.screen = 'entry'; render(); },
  tutorialFinish() { state.screen = 'entry'; render(); },
};

function onJoined(payload: { room_id: string; player_id: string; token: string }): void {
  reconnectPending = false;
  state.roomId = payload.room_id;
  state.playerId = payload.player_id;
  net.roomId = payload.room_id;
  net.playerId = payload.player_id;
  saveCredentials(payload);
  if (state.roomMode !== 'tutorial_practice') {
    state.roomMode = 'normal';
    state.statsEligible = true;
  }
  toast(`已进入房间 ${payload.room_id}`);
  render();
}

net.on('room_created', onJoined);
net.on('room_joined', onJoined);

net.on('logged_in', (p: { session: string; account_name: string }) => {
  setAuthenticated(p.session, p.account_name);
});
net.on('account_registered', (p: { session?: string; account_id?: string; account_name: string; role_id?: string }) => {
  const registration = pendingRegistration;
  if (p.session) {
    setAuthenticated(p.session, p.account_name);
  } else if (registration && registration.username === p.account_name) {
    actions.loginAccount(registration.username, registration.password);
  } else {
    pendingRegistration = null;
    closeAuthModal();
    toast(`账号 ${p.account_name} 注册成功，请登录。`, 'success');
    render();
  }
});
net.on('logged_out', () => {
  backToEntry('已登出');
});

net.on('password_changed', () => {
  backToEntry('密码已修改，请使用新密码重新登录');
});

net.on('session', (p: { authenticated?: boolean; account_name?: string }) => {
  if (p.authenticated === true && p.account_name) {
    const session = loadAccountSession();
    if (session) setAuthenticated(session, p.account_name);
  } else {
    backToEntry('登录已过期，请重新登录');
  }
  render();
});

net.on('returned_to_lobby', () => {
  clearRoomState();
  if (state.accountStatus === 'authenticated') {
    state.screen = 'lobby';
    requestMyStats();
  }
  render();
});

net.on('room_list', (p: { rooms: RoomBrief[] }) => {
  state.roomList = p.rooms ?? [];
  if (state.screen === 'lobby' && !state.roomId) render();
});

net.on('room_update', (p: { players: PlayerBrief[] }) => {
  state.players = p.players ?? [];
  if (state.publicState) {
    for (const bp of state.players) {
      const pp = state.publicState.players.find((x) => x.id === bp.id);
      if (pp) {
        pp.auto_pilot = bp.auto_pilot;
        pp.connected = bp.connected;
      }
    }
  }
  render();
});

net.on('game_started', (p: { public_state: PublicState; private_state: PrivateState; room_mode?: string; stats_eligible?: boolean }) => {
  state.roomMode = p.room_mode === 'tutorial_practice' ? 'tutorial_practice' : 'normal';
  state.statsEligible = p.stats_eligible !== false;
  state.practiceStarting = false;
  state.publicState = p.public_state;
  state.privateState = p.private_state;
  state.phase = p.public_state?.phase ?? 'select';
  state.screen = 'game';
  state.iSubmitted = false;
  state.logs = [];
  render();
});

net.on('practice_started', (p: { room_id?: string; room_mode?: string; stats_eligible?: boolean }) => {
  state.roomMode = p.room_mode === 'tutorial_practice' ? 'tutorial_practice' : 'normal';
  state.statsEligible = p.stats_eligible !== false;
  if (p.room_id) state.roomId = p.room_id;
  toast('陪练房已创建，正在进入正式规则对局');
  render();
});

net.on('phase_changed', (p: { phase: Phase; deadline_ts?: number }) => {
  state.phase = p.phase;
  state.deadlineTs = p.deadline_ts ?? null;
  if (p.phase === 'select') {
    state.iSubmitted = false;
    showWaitingMask(false, state);
  }
  if (state.screen === 'game') render();
});

net.on('ack', () => {
  // 行动已受理
});

net.on('action_rejected', (p: { reason?: string }) => {
  state.iSubmitted = false;
  showWaitingMask(false, state);
  toast(`行动被拒绝：${p.reason ?? '未知原因'}`, 'error');
  if (state.screen === 'game') render();
});

net.on('reveal_cards', (p: { plays: RevealPlay[] }) => {
  showWaitingMask(false, state);
  showReveal(p.plays ?? [], state);
});

net.on('state_sync', (p: { public_state: PublicState; private_state: PrivateState }) => {
  state.publicState = p.public_state;
  state.privateState = p.private_state;
  if (p.public_state?.phase) state.phase = p.public_state.phase;
  const me = p.public_state?.players.find((x) => x.id === state.playerId);
  if (state.phase === 'select' && me && !me.submitted) {
    state.iSubmitted = false;
    showWaitingMask(false, state);
  } else if (state.iSubmitted) {
    showWaitingMask(true, state);
  }
  if (state.screen === 'game') render();
});

net.on('action_log', (p: { entries: string[] }) => {
  state.logs.push(...(p.entries ?? []));
  if (state.logs.length > 200) state.logs = state.logs.slice(-200);
  if (state.screen === 'game') render();
});

net.on('player_left', (p: { player_id?: string; name?: string; reason?: string }) => {
  const name = p.name ?? p.player_id ?? '玩家';
  toast(p.reason === 'disconnect' ? `${name} 断线，AI 托管中` : `${name} 退出了对战（AI 托管）`, 'info');
  const pp = state.publicState?.players.find((x) => x.id === p.player_id);
  if (pp) {
    pp.connected = false;
    pp.auto_pilot = true;
  }
  const bp = state.players.find((x) => x.id === p.player_id);
  if (bp) {
    bp.connected = false;
    bp.auto_pilot = true;
  }
  if (state.screen === 'game') render();
});

net.on('game_over', (p: { scores: ScoreEntry[]; room_mode?: string; stats_eligible?: boolean }) => {
  if (p.room_mode) state.roomMode = p.room_mode === 'tutorial_practice' ? 'tutorial_practice' : 'normal';
  if (p.stats_eligible !== undefined) state.statsEligible = p.stats_eligible;
  state.phase = 'game_over';
  showWaitingMask(false, state);
  showGameOver(p.scores ?? [], state, actions, { onRetryStats: requestSettlementStats });
  if (state.statsEligible && state.accountStatus === 'authenticated') {
    requestSettlementStats();
  }
  if (state.screen === 'game') render();
});

net.on('my_stats', (p) => {
  state.myStatsLoading = false;
  state.myStats = (p.stats as PlayerStats | null) ?? null;
  if (settleStatsPending) {
    settleStatsPending = false;
    clearSettleStatsTimer();
    updateSettlementStats(state.myStats);
  }
  if (state.screen === 'profile' || state.screen === 'lobby') render();
});

net.on('leaderboard', (p: { board: LeaderboardBoard; entries: LeaderboardEntry[]; self_rank: number | null }) => {
  state.lbLoading = false;
  state.leaderboard = { board: p.board, entries: p.entries ?? [], self_rank: p.self_rank ?? null };
  if (state.screen === 'lobby' && state.panel === 'leaderboard') render();
});

net.on('error', (p: { code?: string; message?: string }) => {
  if (p.code === 'not_in_game' || p.code === 'already_game_over') {
    toast(p.message ?? (p.code === 'not_in_game' ? '当前不在对局中，无法退出' : '对局已结束'), 'error');
    return;
  }
  if (p.code === 'already_in_room' && !pwdDraft.busy) {
    toast('账号已在房间中，不能重复进入其他房间', 'error');
    return;
  }
  if (state.practiceStarting) {
    state.practiceStarting = false;
    render();
  }
  if (pwdDraft.busy && p.code && p.code in PWD_ERROR_TEXT) {
    pwdDraft.busy = false;
    pwdDraft.error = PWD_ERROR_TEXT[p.code];
    if (state.screen === 'profile') render();
    return;
  }
  if (p.code && p.code in ACCOUNT_ERROR_TEXT) {
    pendingRegistration = null;
    const text = ACCOUNT_ERROR_TEXT[p.code];
    if (authModal) {
      authModal.clearPasswords();
      authModal.showError(text);
      return;
    }
    toast(text, 'error');
    render();
    return;
  }
  if (reconnectPending || p.code === 'reconnect_failed' || p.code === 'room_not_found') {
    reconnectPending = false;
    clearCredentials();
    state.roomId = null;
    state.playerId = null;
    net.roomId = null;
    net.playerId = null;
    actions.backToLobby();
  }
  if (p.code === 'invalid_board' || p.code === 'invalid_limit') {
    state.lbLoading = false;
    if (state.screen === 'lobby' && state.panel === 'leaderboard') render();
  }
  toast(p.message ?? `错误：${p.code ?? '未知'}`, 'error');
});

net.onConn((connected) => {
  banner.classList.toggle('hidden', connected);
  if (!connected && settleStatsPending) {
    settleStatsPending = false;
    clearSettleStatsTimer();
    settlementStatsFailed();
  }
  if (!connected && pendingRegistration) {
    pendingRegistration = null;
    authModal?.showError('网络异常，请稍后重试');
  }
  if (!connected && state.practiceStarting) {
    state.practiceStarting = false;
    toast('连接已断开，陪练未开始，可重新尝试', 'error');
    render();
  }
  if (connected && state.accountStatus === 'authenticated' && state.screen === 'lobby' && !state.roomId) {
    actions.refreshRooms();
  }
});

net.setReconnectHook(() => {
  const accountSession = loadAccountSession();
  if (accountSession) net.send('session', { session: accountSession });
  const creds = loadCredentials();
  if (creds) {
    reconnectPending = true;
    net.send('reconnect', { room_id: creds.room_id, player_id: creds.player_id, token: creds.token });
  }
});

window.setInterval(() => {
  const node = document.getElementById('phase-timer');
  if (!node) return;
  if (state.phase !== 'select' || !state.deadlineTs) {
    node.textContent = '';
    return;
  }
  const remain = Math.max(0, Math.ceil((tsToMs(state.deadlineTs) - Date.now()) / 1000));
  node.textContent = `剩余 ${remain}s`;
  node.classList.toggle('urgent', remain <= 10);
}, 500);

render();
net.connect();
