import type {
  BotDifficulty,
  LeaderboardBoard,
  LeaderboardData,
  Phase,
  PlayerBrief,
  PlayerStats,
  PrivateState,
  PublicState,
  RoomBrief,
  RoomMode,
} from './types';

export type LobbyPanel = 'none' | 'leaderboard';
export type AccountStatus = 'signed_out' | 'authenticated';
export type ManualFrom = 'lobby' | 'profile';

export interface AppState {
  screen: 'lobby' | 'game' | 'tutorial' | 'entry' | 'profile';
  playerName: string;
  accountName: string;
  accountStatus: AccountStatus;
  accountNotice: string | null;
  roomId: string | null;
  playerId: string | null;
  players: PlayerBrief[];
  publicState: PublicState | null;
  privateState: PrivateState | null;
  phase: Phase | null;
  deadlineTs: number | null;
  iSubmitted: boolean;
  logs: string[];
  roomList: RoomBrief[];
  panel: LobbyPanel;
  myStats: PlayerStats | null;
  myStatsLoading: boolean;
  lbBoard: LeaderboardBoard;
  leaderboard: LeaderboardData | null;
  lbLoading: boolean;
  manualOpen: boolean;
  manualFrom: ManualFrom;
  tutorialPage: number;
  roomMode: RoomMode;
  statsEligible: boolean;
  practiceStarting: boolean;
}

export interface AppActions {
  registerAccount(username: string, password: string, confirmPassword: string): boolean;
  loginAccount(username: string, password: string): void;
  logoutAccount(): void;
  changePassword(oldPassword: string, newPassword: string, confirmPassword: string): void;
  createRoom(name: string): void;
  joinRoom(name: string, roomId: string): void;
  setReady(ready: boolean): void;
  startGame(): void;
  addBot(difficulty: BotDifficulty): void;
  removeBot(playerId: string): void;
  openPanel(panel: LobbyPanel): void;
  closePanel(): void;
  setBoard(board: LeaderboardBoard): void;
  submitCard(cardUid: string, mode: string, target?: Record<string, unknown>): void;
  leaveGame(): void;
  backToLobby(): void;
  gotoLobby(): void;
  openProfile(): void;
  openManual(from: ManualFrom): void;
  closeManual(): void;
  applyServer(url: string): void;
  resetServer(): void;
  refreshRooms(): void;
  tutorialNext(): void;
  tutorialPrevious(): void;
  tutorialBack(): void;
  tutorialFinish(): void;
  registerFromTutorial(): void;
}

export function el(tag: string, cls?: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

export function clear(node: HTMLElement): void {
  while (node.firstChild) node.removeChild(node.firstChild);
}

export function toast(message: string, kind: 'info' | 'error' | 'success' = 'info'): void {
  const root = document.getElementById('toast-root');
  if (!root) return;
  const t = el('div', `toast toast-${kind}`, message);
  root.appendChild(t);
  window.setTimeout(() => t.classList.add('show'), 10);
  window.setTimeout(() => {
    t.classList.remove('show');
    window.setTimeout(() => t.remove(), 400);
  }, 3200);
}

export interface ModalHandle {
  close(): void;
}

export function openModal(title: string, body: HTMLElement, onConfirm?: () => boolean | void, confirmText = '确认'): ModalHandle {
  const root = document.getElementById('modal-root');
  if (!root) return { close: () => undefined };
  clear(root);
  const backdrop = el('div', 'modal-backdrop');
  const box = el('div', 'modal');
  box.appendChild(el('div', 'modal-title', title));
  box.appendChild(body);
  const btns = el('div', 'modal-btns');
  const handle: ModalHandle = {
    close() {
      clear(root);
    },
  };
  const cancel = el('button', 'btn btn-ghost', '取消') as HTMLButtonElement;
  cancel.onclick = () => handle.close();
  btns.appendChild(cancel);
  if (onConfirm) {
    const ok = el('button', 'btn btn-gold', confirmText) as HTMLButtonElement;
    ok.onclick = () => {
      const r = onConfirm();
      if (r !== false) handle.close();
    };
    btns.appendChild(ok);
  }
  box.appendChild(btns);
  backdrop.appendChild(box);
  root.appendChild(backdrop);
  return handle;
}

export function tsToMs(ts: number): number {
  return ts > 1e12 ? ts : ts * 1000;
}
