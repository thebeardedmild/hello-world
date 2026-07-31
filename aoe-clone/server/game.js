const {
  PLAYER_COLORS, PLAY_RADIUS_M, MAX_COMMAND_RADIUS_M,
  RESOURCE_TYPES, RESOURCE_NODE, STARTING_RESOURCES,
  RESOURCE_GATHER_RANGE_M, DROPOFF_RANGE_M, BUILD_RANGE_M,
  UNIT_TYPES, BUILDING_TYPES, MAX_POP_CAP, MAX_TRAIN_QUEUE,
} = require('./config');
const { toLocal, toLatLng } = require('./latlng');

function dist(ax, ay, bx, by) {
  return Math.hypot(ax - bx, ay - by);
}

class Game {
  constructor() {
    this.players = new Map();
    this.units = new Map();
    this.buildings = new Map();
    this.resourceNodes = new Map();
    this.nextId = 1;
    this.tick = 0;
    this.origin = null; // {lat, lng} — set by the first player to join
  }

  genId() {
    return this.nextId++;
  }

  // ---------- World setup ----------

  // Scatters a small cluster of wood/food/gold nodes near a local point —
  // called once for the match origin and again near each new player's spawn
  // so everyone has something close by to gather.
  addStartingResourceCluster(center) {
    const offsets = [
      { type: 'wood', dx: 10, dy: -10 },
      { type: 'wood', dx: 14, dy: -6 },
      { type: 'food', dx: -10, dy: 8 },
      { type: 'gold', dx: -12, dy: -10 },
    ];
    for (const o of offsets) this.addResourceNode(o.type, center.x + o.dx, center.y + o.dy);
  }

  seedNeutralResources() {
    const rng = mulberry32(1337);
    const clusterCount = 14;
    for (let i = 0; i < clusterCount; i++) {
      const type = RESOURCE_TYPES[Math.floor(rng() * RESOURCE_TYPES.length)];
      const angle = rng() * Math.PI * 2;
      const radius = 25 + rng() * PLAY_RADIUS_M;
      const cx = Math.cos(angle) * radius;
      const cy = Math.sin(angle) * radius;
      const nodesInCluster = type === 'gold' ? 1 : 2 + Math.floor(rng() * 3);
      for (let n = 0; n < nodesInCluster; n++) {
        const x = cx + (rng() - 0.5) * 20;
        const y = cy + (rng() - 0.5) * 20;
        this.addResourceNode(type, x, y);
      }
    }
  }

  addResourceNode(type, x, y) {
    const id = this.genId();
    this.resourceNodes.set(id, {
      id, type, x, y, amount: RESOURCE_NODE[type].amount, maxAmount: RESOURCE_NODE[type].amount,
    });
    return id;
  }

  getStaticInfo() {
    return { unitTypes: UNIT_TYPES, buildingTypes: BUILDING_TYPES, playRadiusM: PLAY_RADIUS_M };
  }

  // ---------- Players ----------

  // Returns { playerId, distanceFromOriginM } or null if lat/lng are invalid.
  addPlayer(name, lat, lng, ws) {
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;

    const isFirst = this.origin === null;
    if (isFirst) {
      this.origin = { lat, lng };
      this.seedNeutralResources();
    }

    const id = this.genId();
    const color = PLAYER_COLORS[this.players.size % PLAYER_COLORS.length];
    const local = toLocal(lat, lng, this.origin);
    const player = {
      id, name: String(name).slice(0, 20) || `Player${id}`, ws, color,
      resources: { ...STARTING_RESOURCES }, eliminated: false,
    };
    this.players.set(id, player);
    this.spawnStartingBase(player, local);
    if (!isFirst) this.addStartingResourceCluster(local);

    return { playerId: id, distanceFromOriginM: Math.round(dist(0, 0, local.x, local.y)) };
  }

  spawnStartingBase(player, center) {
    const tcId = this.genId();
    const tcType = BUILDING_TYPES.townCenter;
    this.buildings.set(tcId, {
      id: tcId, ownerId: player.id, type: 'townCenter', x: center.x, y: center.y,
      hp: tcType.hp, maxHp: tcType.hp, constructed: true, buildProgress: 1,
      trainQueue: [], rally: { x: center.x + 15, y: center.y + 15 },
    });
    for (let i = 0; i < 3; i++) {
      const uid = this.genId();
      const ut = UNIT_TYPES.villager;
      this.units.set(uid, {
        id: uid, ownerId: player.id, type: 'villager',
        x: center.x - 6 + i * 6, y: center.y + 8,
        hp: ut.hp, maxHp: ut.hp, carryType: null, carryAmount: 0,
        order: null, cooldown: 0,
      });
    }
  }

  removePlayer(id) {
    for (const [uid, u] of this.units) if (u.ownerId === id) this.units.delete(uid);
    for (const [bid, b] of this.buildings) if (b.ownerId === id) this.buildings.delete(bid);
    this.players.delete(id);
  }

  // ---------- Commands ----------

  handleCommand(playerId, cmd) {
    const player = this.players.get(playerId);
    if (!player || !cmd || typeof cmd.action !== 'string') return;
    switch (cmd.action) {
      case 'move': return this.cmdMove(player, cmd);
      case 'gather': return this.cmdGather(player, cmd);
      case 'build': return this.cmdBuild(player, cmd);
      case 'train': return this.cmdTrain(player, cmd);
      case 'attack': return this.cmdAttack(player, cmd);
      case 'stop': return this.cmdStop(player, cmd);
      case 'setRally': return this.cmdSetRally(player, cmd);
      default: return;
    }
  }

  ownedUnits(player, ids) {
    if (!Array.isArray(ids)) return [];
    return ids.map((id) => this.units.get(id)).filter((u) => u && u.ownerId === player.id);
  }

  // Converts a command's lat/lng into a local point clamped to the play area,
  // or null if the coordinates are missing/invalid.
  targetLocal(cmd) {
    if (!Number.isFinite(cmd.lat) || !Number.isFinite(cmd.lng)) return null;
    const p = toLocal(cmd.lat, cmd.lng, this.origin);
    const d = dist(0, 0, p.x, p.y);
    if (d > MAX_COMMAND_RADIUS_M) {
      const scale = MAX_COMMAND_RADIUS_M / d;
      return { x: p.x * scale, y: p.y * scale };
    }
    return p;
  }

  cmdMove(player, cmd) {
    const units = this.ownedUnits(player, cmd.unitIds);
    const target = this.targetLocal(cmd);
    if (!target) return;
    for (const u of units) u.order = { type: 'move', targetPos: target };
  }

  cmdGather(player, cmd) {
    const node = this.resourceNodes.get(cmd.resourceId);
    if (!node) return;
    const units = this.ownedUnits(player, cmd.unitIds).filter((u) => u.type === 'villager');
    for (const u of units) u.order = { type: 'gather', targetId: node.id };
  }

  cmdBuild(player, cmd) {
    const buildingType = BUILDING_TYPES[cmd.buildingType];
    if (!buildingType || cmd.buildingType === 'townCenter') return;
    const target = this.targetLocal(cmd);
    if (!target) return;
    const villagers = this.ownedUnits(player, cmd.unitIds).filter((u) => u.type === 'villager');
    if (villagers.length === 0) return;

    for (const [k, amt] of Object.entries(buildingType.cost)) {
      if ((player.resources[k] || 0) < amt) return; // can't afford
    }
    const half = buildingType.size / 2;
    for (const b of this.buildings.values()) {
      const otherHalf = BUILDING_TYPES[b.type].size / 2;
      if (Math.abs(b.x - target.x) < half + otherHalf && Math.abs(b.y - target.y) < half + otherHalf) return;
    }

    for (const [k, amt] of Object.entries(buildingType.cost)) player.resources[k] -= amt;
    const bid = this.genId();
    this.buildings.set(bid, {
      id: bid, ownerId: player.id, type: cmd.buildingType, x: target.x, y: target.y,
      hp: Math.ceil(buildingType.hp * 0.1), maxHp: buildingType.hp,
      constructed: false, buildProgress: 0, trainQueue: [],
      rally: { x: target.x, y: target.y + buildingType.size },
    });
    for (const u of villagers) u.order = { type: 'build', targetId: bid };
  }

  cmdTrain(player, cmd) {
    const building = this.buildings.get(cmd.buildingId);
    if (!building || building.ownerId !== player.id || !building.constructed) return;
    const bt = BUILDING_TYPES[building.type];
    if (!bt.trains.includes(cmd.unitType)) return;
    if (building.trainQueue.length >= MAX_TRAIN_QUEUE) return;
    const ut = UNIT_TYPES[cmd.unitType];
    for (const [k, amt] of Object.entries(ut.cost)) {
      if ((player.resources[k] || 0) < amt) return;
    }
    const { used, cap } = this.populationFor(player.id);
    if (used + building.trainQueue.length >= cap) return;
    for (const [k, amt] of Object.entries(ut.cost)) player.resources[k] -= amt;
    building.trainQueue.push({ unitType: cmd.unitType, timeRemaining: ut.trainTime });
  }

  cmdAttack(player, cmd) {
    const units = this.ownedUnits(player, cmd.unitIds);
    const targetIsUnit = this.units.has(cmd.targetId);
    const targetIsBuilding = this.buildings.has(cmd.targetId);
    if (!targetIsUnit && !targetIsBuilding) return;
    const target = targetIsUnit ? this.units.get(cmd.targetId) : this.buildings.get(cmd.targetId);
    if (target.ownerId === player.id) return;
    for (const u of units) {
      if (u.type === 'villager') continue;
      u.order = { type: 'attack', targetId: cmd.targetId, targetKind: targetIsUnit ? 'unit' : 'building' };
    }
  }

  cmdStop(player, cmd) {
    for (const u of this.ownedUnits(player, cmd.unitIds)) u.order = null;
  }

  cmdSetRally(player, cmd) {
    const building = this.buildings.get(cmd.buildingId);
    if (!building || building.ownerId !== player.id) return;
    const target = this.targetLocal(cmd);
    if (!target) return;
    building.rally = target;
  }

  // ---------- Simulation ----------

  populationFor(playerId) {
    let used = 0;
    for (const u of this.units.values()) if (u.ownerId === playerId) used++;
    let cap = 0;
    for (const b of this.buildings.values()) {
      if (b.ownerId === playerId && b.constructed) cap += BUILDING_TYPES[b.type].popBonus;
    }
    return { used, cap: Math.min(cap, MAX_POP_CAP) };
  }

  nearestDropOff(playerId, x, y, resourceType) {
    let best = null;
    let bestDist = Infinity;
    for (const b of this.buildings.values()) {
      if (b.ownerId !== playerId || !b.constructed) continue;
      const bt = BUILDING_TYPES[b.type];
      if (!bt.dropOff || !bt.dropOff.includes(resourceType)) continue;
      const d = dist(b.x, b.y, x, y);
      if (d < bestDist) { bestDist = d; best = b; }
    }
    return best;
  }

  moveToward(entity, tx, ty, speed, dt) {
    const d = dist(entity.x, entity.y, tx, ty);
    if (d < 0.05) return true;
    const step = Math.min(d, speed * dt);
    entity.x += ((tx - entity.x) / d) * step;
    entity.y += ((ty - entity.y) / d) * step;
    return step >= d;
  }

  update(dt) {
    if (!this.origin) return; // no match in progress yet
    this.tick++;
    this.updateUnits(dt);
    this.updateBuildings(dt);
    this.checkEliminations();
  }

  updateUnits(dt) {
    for (const unit of this.units.values()) {
      if (!unit.order) continue;
      const ut = UNIT_TYPES[unit.type];
      switch (unit.order.type) {
        case 'move': {
          const arrived = this.moveToward(unit, unit.order.targetPos.x, unit.order.targetPos.y, ut.speed, dt);
          if (arrived) unit.order = null;
          break;
        }
        case 'gather': this.updateGather(unit, ut, dt); break;
        case 'build': this.updateBuild(unit, ut, dt); break;
        case 'return': this.updateReturn(unit, ut, dt); break;
        case 'attack': this.updateAttack(unit, ut, dt); break;
        default: unit.order = null;
      }
    }
  }

  updateGather(unit, ut, dt) {
    const node = this.resourceNodes.get(unit.order.targetId);
    if (!node) { unit.order = null; return; }
    const d = dist(unit.x, unit.y, node.x, node.y);
    if (d > RESOURCE_GATHER_RANGE_M) {
      this.moveToward(unit, node.x, node.y, ut.speed, dt);
      return;
    }
    if (unit.carryType && unit.carryType !== node.type) unit.carryAmount = 0;
    unit.carryType = node.type;
    const gathered = Math.min(ut.gatherRate * dt, node.amount, ut.carryCapacity - unit.carryAmount);
    unit.carryAmount += gathered;
    node.amount -= gathered;
    if (node.amount <= 0) this.resourceNodes.delete(node.id);
    if (unit.carryAmount >= ut.carryCapacity || node.amount <= 0) {
      unit.order = { type: 'return', resumeTargetId: node.amount > 0 ? node.id : null, resumeType: node.type };
    }
  }

  updateReturn(unit, ut, dt) {
    const drop = this.nearestDropOff(unit.ownerId, unit.x, unit.y, unit.carryType);
    if (!drop) { unit.order = null; return; }
    const d = dist(unit.x, unit.y, drop.x, drop.y);
    if (d > BUILDING_TYPES[drop.type].size / 2 + DROPOFF_RANGE_M) {
      this.moveToward(unit, drop.x, drop.y, ut.speed, dt);
      return;
    }
    const player = this.players.get(unit.ownerId);
    if (player && unit.carryType) {
      player.resources[unit.carryType] = (player.resources[unit.carryType] || 0) + unit.carryAmount;
    }
    unit.carryAmount = 0;
    if (unit.order.resumeTargetId && this.resourceNodes.has(unit.order.resumeTargetId)) {
      unit.order = { type: 'gather', targetId: unit.order.resumeTargetId };
    } else {
      unit.carryType = null;
      unit.order = null;
    }
  }

  updateBuild(unit, ut, dt) {
    const building = this.buildings.get(unit.order.targetId);
    if (!building) { unit.order = null; return; }
    if (building.constructed) { unit.order = null; return; }
    const bt = BUILDING_TYPES[building.type];
    const d = dist(unit.x, unit.y, building.x, building.y);
    if (d > bt.size / 2 + BUILD_RANGE_M) {
      this.moveToward(unit, building.x, building.y, ut.speed, dt);
      return;
    }
    building.buildProgress = clamp01(building.buildProgress + dt / bt.buildTime);
    building.hp = Math.ceil(bt.hp * (0.1 + 0.9 * building.buildProgress));
    if (building.buildProgress >= 1) {
      building.constructed = true;
      building.hp = bt.hp;
      unit.order = null;
    }
  }

  updateAttack(unit, ut, dt) {
    const map = unit.order.targetKind === 'unit' ? this.units : this.buildings;
    const target = map.get(unit.order.targetId);
    if (!target || target.hp <= 0) { unit.order = null; return; }
    const targetSize = unit.order.targetKind === 'building' ? BUILDING_TYPES[target.type].size / 2 : 1;
    const d = dist(unit.x, unit.y, target.x, target.y);
    if (d > ut.range + targetSize) {
      this.moveToward(unit, target.x, target.y, ut.speed, dt);
      return;
    }
    unit.cooldown = (unit.cooldown || 0) - dt;
    if (unit.cooldown <= 0) {
      const defense = unit.order.targetKind === 'unit' ? UNIT_TYPES[target.type].defense : 0;
      const dmg = Math.max(1, ut.attack - defense);
      target.hp -= dmg;
      unit.cooldown = ut.attackCooldown;
      if (target.hp <= 0) {
        map.delete(target.id);
        unit.order = null;
      }
    }
  }

  updateBuildings(dt) {
    for (const building of this.buildings.values()) {
      if (!building.constructed || building.trainQueue.length === 0) continue;
      const player = this.players.get(building.ownerId);
      if (!player) continue;
      const item = building.trainQueue[0];
      item.timeRemaining -= dt;
      if (item.timeRemaining <= 0) {
        building.trainQueue.shift();
        this.spawnUnit(building, item.unitType);
      }
    }
  }

  spawnUnit(building, unitType) {
    const bt = BUILDING_TYPES[building.type];
    const ut = UNIT_TYPES[unitType];
    const uid = this.genId();
    const angle = Math.random() * Math.PI * 2;
    const spawnR = bt.size / 2 + 2;
    this.units.set(uid, {
      id: uid, ownerId: building.ownerId, type: unitType,
      x: building.x + Math.cos(angle) * spawnR,
      y: building.y + Math.sin(angle) * spawnR,
      hp: ut.hp, maxHp: ut.hp, carryType: null, carryAmount: 0,
      order: building.rally ? { type: 'move', targetPos: { ...building.rally } } : null,
      cooldown: 0,
    });
  }

  checkEliminations() {
    for (const player of this.players.values()) {
      if (player.eliminated) continue;
      let hasBase = false;
      for (const b of this.buildings.values()) {
        if (b.ownerId === player.id) { hasBase = true; break; }
      }
      if (!hasBase) {
        let hasVillager = false;
        for (const u of this.units.values()) {
          if (u.ownerId === player.id) { hasVillager = true; break; }
        }
        if (!hasVillager) player.eliminated = true;
      }
    }
  }

  // ---------- Serialization ----------

  getState() {
    if (!this.origin) return { tick: this.tick, players: [], units: [], buildings: [], resources: [] };
    const origin = this.origin;
    const players = [...this.players.values()].map((p) => {
      const { used, cap } = this.populationFor(p.id);
      return {
        id: p.id, name: p.name, color: p.color, resources: p.resources,
        population: used, popCap: cap, eliminated: p.eliminated,
      };
    });
    return {
      tick: this.tick,
      players,
      units: [...this.units.values()].map((u) => {
        const { lat, lng } = toLatLng(u.x, u.y, origin);
        return {
          id: u.id, ownerId: u.ownerId, type: u.type, lat, lng,
          hp: u.hp, maxHp: u.maxHp, carryType: u.carryType, carryAmount: u.carryAmount,
        };
      }),
      buildings: [...this.buildings.values()].map((b) => {
        const { lat, lng } = toLatLng(b.x, b.y, origin);
        return {
          id: b.id, ownerId: b.ownerId, type: b.type, lat, lng,
          hp: b.hp, maxHp: b.maxHp, constructed: b.constructed, buildProgress: b.buildProgress,
          trainQueue: b.trainQueue.map((q) => ({ unitType: q.unitType, timeRemaining: q.timeRemaining })),
        };
      }),
      resources: [...this.resourceNodes.values()].map((r) => {
        const { lat, lng } = toLatLng(r.x, r.y, origin);
        return { id: r.id, type: r.type, lat, lng, amount: r.amount, maxAmount: r.maxAmount };
      }),
    };
  }
}

function clamp01(v) {
  return Math.max(0, Math.min(1, v));
}

function mulberry32(seed) {
  let a = seed;
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

module.exports = { Game };
