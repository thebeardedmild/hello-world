const {
  MAP_W, MAP_H, PLAYER_COLORS, SPAWN_POINTS, RESOURCE_TYPES, RESOURCE_NODE,
  STARTING_RESOURCES, UNIT_TYPES, BUILDING_TYPES, MAX_POP_CAP, MAX_TRAIN_QUEUE,
} = require('./config');

function dist(ax, ay, bx, by) {
  return Math.hypot(ax - bx, ay - by);
}

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

class Game {
  constructor() {
    this.players = new Map();
    this.units = new Map();
    this.buildings = new Map();
    this.resourceNodes = new Map();
    this.nextId = 1;
    this.spawnIndex = 0;
    this.tick = 0;
    this.generateMap();
  }

  genId() {
    return this.nextId++;
  }

  // ---------- World setup ----------

  generateMap() {
    const rng = mulberry32(1337); // deterministic layout so all clients agree on nothing except server truth anyway
    const clusterCount = 26;
    for (let i = 0; i < clusterCount; i++) {
      const type = RESOURCE_TYPES[Math.floor(rng() * RESOURCE_TYPES.length)];
      const cx = 3 + rng() * (MAP_W - 6);
      const cy = 3 + rng() * (MAP_H - 6);
      const nodesInCluster = type === 'gold' ? 1 : 2 + Math.floor(rng() * 3);
      for (let n = 0; n < nodesInCluster; n++) {
        const x = clamp(cx + (rng() - 0.5) * 3, 1, MAP_W - 2);
        const y = clamp(cy + (rng() - 0.5) * 3, 1, MAP_H - 2);
        this.addResourceNode(type, x, y);
      }
    }
    // Guarantee resources near every spawn point.
    for (const sp of SPAWN_POINTS) {
      this.addResourceNode('wood', sp.x + 2.5, sp.y - 2.5);
      this.addResourceNode('wood', sp.x + 3, sp.y - 1.5);
      this.addResourceNode('food', sp.x - 2.5, sp.y + 2);
      this.addResourceNode('gold', sp.x - 3, sp.y - 2.5);
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
    return {
      mapWidth: MAP_W, mapHeight: MAP_H,
      unitTypes: UNIT_TYPES, buildingTypes: BUILDING_TYPES,
    };
  }

  // ---------- Players ----------

  addPlayer(name, ws) {
    const id = this.genId();
    const color = PLAYER_COLORS[this.players.size % PLAYER_COLORS.length];
    const spawn = SPAWN_POINTS[this.spawnIndex % SPAWN_POINTS.length];
    this.spawnIndex++;
    const player = {
      id, name: String(name).slice(0, 20) || `Player${id}`, ws, color,
      resources: { ...STARTING_RESOURCES }, eliminated: false,
    };
    this.players.set(id, player);
    this.spawnStartingBase(player, spawn);
    return id;
  }

  spawnStartingBase(player, spawn) {
    const tcId = this.genId();
    const tcType = BUILDING_TYPES.townCenter;
    this.buildings.set(tcId, {
      id: tcId, ownerId: player.id, type: 'townCenter', x: spawn.x, y: spawn.y,
      hp: tcType.hp, maxHp: tcType.hp, constructed: true, buildProgress: 1,
      trainQueue: [], rally: { x: spawn.x + 3, y: spawn.y + 3 },
    });
    for (let i = 0; i < 3; i++) {
      const uid = this.genId();
      const ut = UNIT_TYPES.villager;
      this.units.set(uid, {
        id: uid, ownerId: player.id, type: 'villager',
        x: spawn.x - 2 + i, y: spawn.y + 2,
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

  cmdMove(player, cmd) {
    const units = this.ownedUnits(player, cmd.unitIds);
    const x = clamp(Number(cmd.x), 0, MAP_W);
    const y = clamp(Number(cmd.y), 0, MAP_H);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    for (const u of units) {
      u.order = { type: 'move', targetPos: { x, y } };
    }
  }

  cmdGather(player, cmd) {
    const node = this.resourceNodes.get(cmd.resourceId);
    if (!node) return;
    const units = this.ownedUnits(player, cmd.unitIds).filter((u) => u.type === 'villager');
    for (const u of units) {
      u.order = { type: 'gather', targetId: node.id };
    }
  }

  cmdBuild(player, cmd) {
    const buildingType = BUILDING_TYPES[cmd.buildingType];
    if (!buildingType || cmd.buildingType === 'townCenter') return;
    const x = clamp(Number(cmd.x), 0, MAP_W);
    const y = clamp(Number(cmd.y), 0, MAP_H);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    const villagers = this.ownedUnits(player, cmd.unitIds).filter((u) => u.type === 'villager');
    if (villagers.length === 0) return;

    for (const [k, amt] of Object.entries(buildingType.cost)) {
      if ((player.resources[k] || 0) < amt) return; // can't afford
    }
    // simple footprint overlap check against existing buildings
    const half = buildingType.size / 2;
    for (const b of this.buildings.values()) {
      const otherType = BUILDING_TYPES[b.type];
      const otherHalf = otherType.size / 2;
      if (Math.abs(b.x - x) < half + otherHalf && Math.abs(b.y - y) < half + otherHalf) return;
    }

    for (const [k, amt] of Object.entries(buildingType.cost)) {
      player.resources[k] -= amt;
    }
    const bid = this.genId();
    this.buildings.set(bid, {
      id: bid, ownerId: player.id, type: cmd.buildingType, x, y,
      hp: Math.ceil(buildingType.hp * 0.1), maxHp: buildingType.hp,
      constructed: false, buildProgress: 0, trainQueue: [],
      rally: { x, y: y + buildingType.size },
    });
    for (const u of villagers) {
      u.order = { type: 'build', targetId: bid };
    }
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
    const x = clamp(Number(cmd.x), 0, MAP_W);
    const y = clamp(Number(cmd.y), 0, MAP_H);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    building.rally = { x, y };
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
    if (d > 0.7) {
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
    if (d > 1.2) {
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
    if (d > bt.size / 2 + 0.8) {
      this.moveToward(unit, building.x, building.y, ut.speed, dt);
      return;
    }
    building.buildProgress = clamp(building.buildProgress + dt / bt.buildTime, 0, 1);
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
    const targetSize = unit.order.targetKind === 'building' ? BUILDING_TYPES[target.type].size / 2 : 0.35;
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
    const spawnR = bt.size / 2 + 0.6;
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
      units: [...this.units.values()].map((u) => ({
        id: u.id, ownerId: u.ownerId, type: u.type, x: u.x, y: u.y,
        hp: u.hp, maxHp: u.maxHp, carryType: u.carryType, carryAmount: u.carryAmount,
      })),
      buildings: [...this.buildings.values()].map((b) => ({
        id: b.id, ownerId: b.ownerId, type: b.type, x: b.x, y: b.y,
        hp: b.hp, maxHp: b.maxHp, constructed: b.constructed, buildProgress: b.buildProgress,
        trainQueue: b.trainQueue.map((q) => ({ unitType: q.unitType, timeRemaining: q.timeRemaining })),
      })),
      resources: [...this.resourceNodes.values()],
    };
  }
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
