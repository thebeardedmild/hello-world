// Shared tuning constants for the game world, units, and buildings.

const MAP_W = 40;
const MAP_H = 25;

const TICK_RATE = 10; // server ticks per second
const TICK_MS = 1000 / TICK_RATE;

const PLAYER_COLORS = [
  '#e6194b', '#3cb44b', '#4363d8', '#f58231',
  '#911eb4', '#42d4f4', '#f032e6', '#bfef45',
];

// 3-corner+ spawn layout, expands outward for more players.
const SPAWN_POINTS = [
  { x: 4, y: 4 },
  { x: MAP_W - 5, y: MAP_H - 5 },
  { x: MAP_W - 5, y: 4 },
  { x: 4, y: MAP_H - 5 },
  { x: Math.floor(MAP_W / 2), y: 3 },
  { x: Math.floor(MAP_W / 2), y: MAP_H - 4 },
  { x: 4, y: Math.floor(MAP_H / 2) },
  { x: MAP_W - 5, y: Math.floor(MAP_H / 2) },
];

const RESOURCE_TYPES = ['wood', 'food', 'gold'];

const RESOURCE_NODE = {
  wood: { amount: 150 },
  food: { amount: 150 },
  gold: { amount: 400 },
};

const STARTING_RESOURCES = { wood: 150, food: 200, gold: 100 };

const UNIT_TYPES = {
  villager: {
    name: 'Villager', hp: 25, attack: 3, defense: 0, attackCooldown: 2,
    range: 0.5, speed: 2.2, gatherRate: 3, carryCapacity: 10,
    cost: { food: 50 }, trainTime: 15, radius: 0.35,
  },
  militia: {
    name: 'Militia', hp: 45, attack: 7, defense: 1, attackCooldown: 1.5,
    range: 0.6, speed: 2.0, cost: { food: 60, gold: 20 }, trainTime: 20, radius: 0.35,
  },
  archer: {
    name: 'Archer', hp: 30, attack: 5, defense: 0, attackCooldown: 1.3,
    range: 4, speed: 2.0, cost: { wood: 40, gold: 30 }, trainTime: 22, radius: 0.35,
  },
};

const BUILDING_TYPES = {
  townCenter: {
    name: 'Town Center', hp: 600, size: 3, cost: {}, buildTime: 0,
    trains: ['villager'], dropOff: ['wood', 'food', 'gold'], popBonus: 5,
  },
  house: {
    name: 'House', hp: 150, size: 1, cost: { wood: 30 }, buildTime: 20,
    trains: [], popBonus: 5,
  },
  barracks: {
    name: 'Barracks', hp: 300, size: 2, cost: { wood: 100 }, buildTime: 30,
    trains: ['militia'], popBonus: 0,
  },
  archeryRange: {
    name: 'Archery Range', hp: 300, size: 2, cost: { wood: 120 }, buildTime: 35,
    trains: ['archer'], popBonus: 0,
  },
};

const MAX_POP_CAP = 100;
const MAX_TRAIN_QUEUE = 5;

module.exports = {
  MAP_W, MAP_H, TICK_RATE, TICK_MS, PLAYER_COLORS, SPAWN_POINTS,
  RESOURCE_TYPES, RESOURCE_NODE, STARTING_RESOURCES,
  UNIT_TYPES, BUILDING_TYPES, MAX_POP_CAP, MAX_TRAIN_QUEUE,
};
