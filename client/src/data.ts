import type { Card, Good, PortInfo, Tide } from './types';

export const PORTS: PortInfo[] = [
  { id: 'east', name: '东鳞港', adj: ['reef', 'white'] },
  { id: 'reef', name: '碎星礁', adj: ['east', 'fog'] },
  { id: 'fog', name: '雾门', adj: ['reef', 'white'] },
  { id: 'white', name: '白汐城', adj: ['fog', 'east'] },
];

export const PORT_NAME: Record<string, string> = Object.fromEntries(PORTS.map((p) => [p.id, p.name]));

export const GOOD_NAME: Record<string, string> = {
  salt: '盐鳞',
  lamp: '灯油',
  silk: '丝贝',
  wild: '万能货物',
};

export const GOOD_ICON: Record<string, string> = {
  salt: '◆',
  lamp: '●',
  silk: '▲',
  wild: '✦',
};

export const GOODS: Good[] = ['salt', 'lamp', 'silk'];

export const TIDE_ORDER: Tide[] = ['low', 'rising', 'full', 'ebb'];

export const TIDE_NAME: Record<Tide, string> = {
  low: '低潮',
  rising: '涨潮',
  full: '满潮',
  ebb: '退潮',
};

export const ACTION_NAME: Record<string, string> = {
  sail: '航行',
  trade: '交易',
  deliver: '交付订单',
  post: '设立商站',
  tidecraft: '潮汐秘术',
  tailwind: '顺风',
};

export const PHASE_NAME: Record<string, string> = {
  select: '选牌阶段',
  resolve: '结算阶段',
  game_over: '对局结束',
};

export const MODE_NAME: Record<string, string> = {
  action: '执行行动',
  cargo: '留作货物',
  tide: '推进潮汐',
};

export const SCORE_KEY_NAME: Record<string, string> = {
  orders: '订单得分',
  contracts: '订单得分',
  contract: '订单得分',
  posts: '商站得分',
  post: '商站得分',
  cargo: '货物得分',
  coins: '金币得分',
  coin: '金币得分',
  vp: '胜利点',
};

const C = (uid: string, name: string, action: Card['action'], cargo: Card['cargo'], tide: number): Card => ({ uid, name, action, cargo, tide });

export const CARD_CATALOG: Card[] = [
  C('C001', '扬帆·1', 'sail', 'salt', 1),
  C('C002', '扬帆·2', 'sail', 'lamp', 1),
  C('C003', '扬帆·3', 'sail', 'silk', 1),
  C('C004', '扬帆·4', 'sail', 'salt', 1),
  C('C005', '扬帆·5', 'sail', 'wild', 0),
  C('C006', '扬帆·6', 'sail', 'lamp', 1),
  C('C007', '扬帆·7', 'sail', 'lamp', 1),
  C('C008', '扬帆·8', 'sail', 'salt', 1),
  C('C009', '扬帆·9', 'sail', 'salt', 1),
  C('C010', '扬帆·10', 'sail', 'salt', 1),
  C('C011', '扬帆·11', 'sail', 'silk', 1),
  C('C012', '扬帆·12', 'sail', 'salt', 1),
  C('C013', '市集交易·1', 'trade', 'lamp', 1),
  C('C014', '市集交易·2', 'trade', 'wild', 0),
  C('C015', '市集交易·3', 'trade', 'salt', 1),
  C('C016', '市集交易·4', 'trade', 'silk', 1),
  C('C017', '市集交易·5', 'trade', 'salt', 1),
  C('C018', '市集交易·6', 'trade', 'lamp', 1),
  C('C019', '市集交易·7', 'trade', 'lamp', 1),
  C('C020', '市集交易·8', 'trade', 'silk', 1),
  C('C021', '市集交易·9', 'trade', 'salt', 1),
  C('C022', '市集交易·10', 'trade', 'lamp', 1),
  C('C023', '市集交易·11', 'trade', 'lamp', 1),
  C('C024', '市集交易·12', 'trade', 'lamp', 1),
  C('C025', '交付订单·1', 'deliver', 'silk', 1),
  C('C026', '交付订单·2', 'deliver', 'silk', 1),
  C('C027', '交付订单·3', 'deliver', 'salt', 1),
  C('C028', '交付订单·4', 'deliver', 'silk', 1),
  C('C029', '交付订单·5', 'deliver', 'wild', 0),
  C('C030', '交付订单·6', 'deliver', 'silk', 1),
  C('C031', '交付订单·7', 'deliver', 'wild', 0),
  C('C032', '交付订单·8', 'deliver', 'salt', 1),
  C('C033', '设立商站·1', 'post', 'silk', 1),
  C('C034', '设立商站·2', 'post', 'salt', 1),
  C('C035', '设立商站·3', 'post', 'lamp', 1),
  C('C036', '设立商站·4', 'post', 'lamp', 1),
  C('C037', '设立商站·5', 'post', 'silk', 1),
  C('C038', '设立商站·6', 'post', 'salt', 1),
  C('C039', '潮汐秘术·1', 'tidecraft', 'salt', 1),
  C('C040', '潮汐秘术·2', 'tidecraft', 'salt', 1),
  C('C041', '潮汐秘术·3', 'tidecraft', 'salt', 1),
  C('C042', '潮汐秘术·4', 'tidecraft', 'lamp', 1),
  C('C043', '潮汐秘术·5', 'tidecraft', 'lamp', 1),
  C('C044', '潮汐秘术·6', 'tidecraft', 'silk', 1),
  C('C045', '顺风·1', 'tailwind', 'lamp', 1),
  C('C046', '顺风·2', 'tailwind', 'silk', 1),
  C('C047', '顺风·3', 'tailwind', 'lamp', 1),
  C('C048', '顺风·4', 'tailwind', 'lamp', 1),
];

export const CARD_BY_ID: Map<string, Card> = new Map(CARD_CATALOG.map((c) => [c.uid, c]));
