// Shared tuning constants for the game world, units, and buildings.
//
// The simulation runs in local meters on a flat tangent-plane approximation
// centered on "origin" (the first player's real GPS position when the match
// starts). Lat/lng only exist at the network boundary — see latlng.js.

const TICK_RATE = 10; // server ticks per second
const TICK_MS = 1000 / TICK_RATE;

const PLAYER_COLORS = [
  '#e6194b', '#3cb44b', '#4363d8', '#f58231',
  '#911eb4', '#42d4f4', '#f032e6', '#bfef45',
];

// Radius (meters) around the match origin that resource clusters scatter across.
const PLAY_RADIUS_M = 200;
// Radius (meters) around origin shown to players as the suggested play area.
const MAX_COMMAND_RADIUS_M = 350; // move/build/rally targets get clamped within this
// Players joining farther than this from the origin get a "you're far away" warning.
const FAR_JOIN_WARNING_M = 1500;

const RESOURCE_TYPES = ['wood', 'food', 'gold'];

const RESOURCE_NODE = {
  wood: { amount: 150 },
  food: { amount: 150 },
  gold: { amount: 400 },
};

const STARTING_RESOURCES = { wood: 150, food: 200, gold: 100 };

// Distances below are in meters — sized to be usable despite typical consumer
// GPS accuracy (roughly 5-15m), not architectural realism.
const RESOURCE_GATHER_RANGE_M = 8;
const DROPOFF_RANGE_M = 6;
const BUILD_RANGE_M = 6;

const UNIT_TYPES = {
  villager: {
    name: 'Villager', hp: 25, attack: 3, defense: 0, attackCooldown: 2,
    range: 2, speed: 3, gatherRate: 3, carryCapacity: 10,
    cost: { food: 50 }, trainTime: 15, radius: 1,
  },
  militia: {
    name: 'Militia', hp: 45, attack: 7, defense: 1, attackCooldown: 1.5,
    range: 2.5, speed: 3, cost: { food: 60, gold: 20 }, trainTime: 20, radius: 1,
  },
  archer: {
    name: 'Archer', hp: 30, attack: 5, defense: 0, attackCooldown: 1.3,
    range: 20, speed: 3, cost: { wood: 40, gold: 30 }, trainTime: 22, radius: 1,
  },
};

const BUILDING_TYPES = {
  townCenter: {
    name: 'Town Center', hp: 600, size: 12, cost: {}, buildTime: 0,
    trains: ['villager'], dropOff: ['wood', 'food', 'gold'], popBonus: 5,
  },
  house: {
    name: 'House', hp: 150, size: 6, cost: { wood: 30 }, buildTime: 20,
    trains: [], popBonus: 5,
  },
  barracks: {
    name: 'Barracks', hp: 300, size: 10, cost: { wood: 100 }, buildTime: 30,
    trains: ['militia'], popBonus: 0,
  },
  archeryRange: {
    name: 'Archery Range', hp: 300, size: 10, cost: { wood: 120 }, buildTime: 35,
    trains: ['archer'], popBonus: 0,
  },
};

const MAX_POP_CAP = 100;
const MAX_TRAIN_QUEUE = 5;

module.exports = {
  TICK_RATE, TICK_MS, PLAYER_COLORS, PLAY_RADIUS_M, MAX_COMMAND_RADIUS_M,
  FAR_JOIN_WARNING_M, RESOURCE_TYPES, RESOURCE_NODE, STARTING_RESOURCES,
  RESOURCE_GATHER_RANGE_M, DROPOFF_RANGE_M, BUILD_RANGE_M,
  UNIT_TYPES, BUILDING_TYPES, MAX_POP_CAP, MAX_TRAIN_QUEUE,
};
