import type { ServerMsg } from './types';

const LS_ROOM = 'tides_room_id';
const LS_PLAYER = 'tides_player_id';
const LS_TOKEN = 'tides_token';
const LS_WS = 'tides_ws_url';
const LS_PLAYER_TOKEN = 'tides_player_token';
const LS_ACCOUNT_SESSION = 'tides_account_session';

function uuid(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  const bytes = new Uint8Array(16);
  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0'));
  return `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10, 16).join('')}`;
}

export function getPlayerToken(): string {
  let token = localStorage.getItem(LS_PLAYER_TOKEN);
  if (!token) {
    token = uuid();
    localStorage.setItem(LS_PLAYER_TOKEN, token);
  }
  return token;
}

export interface Credentials {
  room_id: string;
  player_id: string;
  token: string;
}

type MsgHandler = (payload: any, msg: ServerMsg) => void;
type ConnHandler = (connected: boolean) => void;

export type WsUrlSource = 'param' | 'manual' | 'build' | 'auto';

export interface ResolvedWsUrl {
  url: string;
  source: WsUrlSource;
}

function inferWsUrl(): string {
  if (location.protocol === 'https:') return `wss://${location.host}/ws`;
  const host = location.hostname;
  if (host === 'localhost' || host === '127.0.0.1') return 'ws://localhost:9500/ws';
  return `ws://${host}:9500/ws`;
}

export function normalizeWsUrl(url: string): string {
  try {
    const u = new URL(url);
    if (u.pathname === '' || u.pathname === '/') u.pathname = '/ws';
    return u.toString();
  } catch {
    return url;
  }
}

export function resolveWsUrl(): ResolvedWsUrl {
  const q = new URLSearchParams(location.search).get('ws');
  if (q) return { url: normalizeWsUrl(q), source: 'param' };
  const manual = localStorage.getItem(LS_WS);
  if (manual) return { url: normalizeWsUrl(manual), source: 'manual' };
  const built = import.meta.env.VITE_WS_URL as string | undefined;
  if (built) return { url: built, source: 'build' };
  return { url: inferWsUrl(), source: 'auto' };
}

export function defaultWsUrl(): string {
  return resolveWsUrl().url;
}

export function saveWsUrl(url: string): void {
  localStorage.setItem(LS_WS, url);
}

export function clearWsUrl(): void {
  localStorage.removeItem(LS_WS);
}

export function loadCredentials(): Credentials | null {
  const room_id = localStorage.getItem(LS_ROOM);
  const player_id = localStorage.getItem(LS_PLAYER);
  const token = localStorage.getItem(LS_TOKEN);
  if (room_id && player_id && token) return { room_id, player_id, token };
  return null;
}

export function saveCredentials(c: Credentials): void {
  localStorage.setItem(LS_ROOM, c.room_id);
  localStorage.setItem(LS_PLAYER, c.player_id);
  localStorage.setItem(LS_TOKEN, c.token);
}

export function clearCredentials(): void {
  localStorage.removeItem(LS_ROOM);
  localStorage.removeItem(LS_PLAYER);
  localStorage.removeItem(LS_TOKEN);
}

export function loadAccountSession(): string | null { return localStorage.getItem(LS_ACCOUNT_SESSION); }
export function saveAccountSession(token: string): void { localStorage.setItem(LS_ACCOUNT_SESSION, token); }
export function clearAccountSession(): void { localStorage.removeItem(LS_ACCOUNT_SESSION); }

export class Net {
  url: string;
  roomId: string | null = null;
  playerId: string | null = null;
  connected = false;

  private ws: WebSocket | null = null;
  private handlers = new Map<string, Set<MsgHandler>>();
  private connHandlers = new Set<ConnHandler>();
  private reconnectTimer: number | null = null;
  private pingTimer: number | null = null;
  private attempts = 0;
  private manualClose = false;
  private wantReconnect: (() => void) | null = null;

  constructor(url: string) {
    this.url = url;
  }

  on(type: string, fn: MsgHandler): void {
    let set = this.handlers.get(type);
    if (!set) {
      set = new Set();
      this.handlers.set(type, set);
    }
    set.add(fn);
  }

  onConn(fn: ConnHandler): void {
    this.connHandlers.add(fn);
  }

  setReconnectHook(fn: () => void): void {
    this.wantReconnect = fn;
  }

  connect(): void {
    this.manualClose = false;
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    ws.onopen = () => {
      if (this.ws !== ws) return;
      this.connected = true;
      this.attempts = 0;
      this.emitConn();
      if (this.pingTimer !== null) clearInterval(this.pingTimer);
      this.pingTimer = window.setInterval(() => this.send('ping', {}), 20000);
      if (this.wantReconnect) this.wantReconnect();
    };
    ws.onmessage = (ev) => {
      if (this.ws !== ws) return;
      let msg: ServerMsg;
      try {
        msg = JSON.parse(String(ev.data)) as ServerMsg;
      } catch {
        return;
      }
      const set = this.handlers.get(msg.type);
      if (set) for (const fn of set) fn(msg.payload ?? {}, msg);
    };
    ws.onclose = () => {
      if (this.ws !== ws) return;
      this.connected = false;
      if (this.pingTimer !== null) {
        clearInterval(this.pingTimer);
        this.pingTimer = null;
      }
      this.emitConn();
      if (!this.manualClose) this.scheduleReconnect();
    };
    ws.onerror = () => {
      if (this.ws !== ws) return;
      ws.close();
    };
  }

  disconnect(): void {
    this.manualClose = true;
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== null || this.manualClose) return;
    const delay = Math.min(1000 * 2 ** this.attempts, 10000);
    this.attempts += 1;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private emitConn(): void {
    for (const fn of this.connHandlers) fn(this.connected);
  }

  sendChangePassword(oldPassword: string, newPassword: string): string | null {
    return this.send('change_password', { old_password: oldPassword, new_password: newPassword });
  }

  send(type: string, payload: Record<string, unknown>): string | null {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return null;    const msg: Record<string, unknown> = {
      type,
      ts: Math.floor(Date.now() / 1000),
      player_token: getPlayerToken(),
      payload,
    };
    if (this.roomId) msg.room_id = this.roomId;
    if (this.playerId) msg.player_id = this.playerId;
    if (
      type === 'submit_card' ||
      type === 'ready' ||
      type === 'start_game' ||
      type === 'add_bot' ||
      type === 'remove_bot' ||
      type === 'leave_game'
    ) {
      msg.action_id = uuid();
    }
    this.ws.send(JSON.stringify(msg));
    return (msg.action_id as string) ?? 'sent';
  }
}
