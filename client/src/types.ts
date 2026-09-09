export type Tide = 'low' | 'rising' | 'full' | 'ebb';
export type Good = 'salt' | 'lamp' | 'silk';
export type CardGood = Good | 'wild';
export type CardAction = 'sail' | 'trade' | 'deliver' | 'post' | 'tidecraft' | 'tailwind';
export type SubmitMode = 'action' | 'cargo' | 'tide';
export type Phase = 'select' | 'resolve' | 'game_over';
export type RoomMode = 'normal' | 'tutorial_practice';

export interface Card {
  uid: string;
  name: string;
  action: CardAction;
  cargo: CardGood;
  tide: number;
}

export interface ContractRequire {
  good: Good;
  count: number;
}

export interface Contract {
  id: string;
  name: string;
  requires: ContractRequire[];
  port: string;
  reward_vp: number;
  reward_coins: number;
  hidden: boolean;
}

export interface PortInfo {
  id: string;
  name: string;
  adj: string[];
}

export type BotDifficulty = 'easy' | 'hard';

export interface PlayerBrief {
  id: string;
  name: string;
  ready: boolean;
  host: boolean;
  connected: boolean;
  is_bot: boolean;
  difficulty: BotDifficulty | null;
  auto_pilot: boolean;
}

export interface PortState {
  id: string;
  ships: string[];
  posts: { player_id: string }[];
}

export interface PublicPlayer {
  id: string;
  name: string;
  coins: number;
  vp: number;
  cargo_count: number;
  submitted: boolean;
  connected: boolean;
  is_bot: boolean;
  difficulty?: BotDifficulty | null;
  auto_pilot?: boolean;
}

export interface PublicState {
  round: number;
  turn: number;
  phase: Phase;
  tide: Tide;
  market: Record<Good, number>;
  ports: PortState[];
  public_contracts: Contract[];
  players: PublicPlayer[];
}

export interface PrivateState {
  hand: Card[];
  cargo: CardGood[];
  hidden_contracts: Contract[];
}

export interface RevealPlay {
  player_id: string;
  card_id: string;
  mode: SubmitMode;
}

export interface ScoreEntry {
  player_id: string;
  total: number;
  rank?: number | null;
  ladder_delta?: number | null;
  breakdown: Record<string, unknown>;
  rage_quit?: boolean;
}

export interface RecentGame {
  ts: number;
  room_size: number;
  has_bot: boolean;
  rank: number;
  total: number;
  ladder_delta: number;
  ladder_after: number;
}

export interface PlayerStats {
  games: number;
  wins: number;
  top2: number;
  avg_total: number;
  ladder: number;
  ladder_max: number;
  win_streak?: number;
  games_7d?: number;
  wins_7d?: number;
  recent: RecentGame[];
}

export type LeaderboardBoard = 'ladder' | 'wins';

export interface LeaderboardEntry {
  rank: number;
  name: string;
  ladder: number;
  games: number;
  wins: number;
  win_rate: number;
}

export interface LeaderboardData {
  board: LeaderboardBoard;
  entries: LeaderboardEntry[];
  self_rank: number | null;
}

export interface RoomBrief {
  room_id: string;
  player_count: number;
  max_players: number;
  phase: string;
  host_name: string;
}

export interface ServerMsg {
  type: string;
  seq?: number;
  payload?: any;
}
