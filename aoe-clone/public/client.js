(() => {
  let TILE = 28;
  const MIN_TILE = 14;
  const MAX_TILE = 48;
  const TICK_MS = 100;

  const joinScreen = document.getElementById('joinScreen');
  const joinBox = document.getElementById('joinBox');
  const nameInput = document.getElementById('nameInput');
  const joinBtn = document.getElementById('joinBtn');
  const joinError = document.getElementById('joinError');
  const gameEl = document.getElementById('game');
  const canvas = document.getElementById('canvas');
  const ctx = canvas.getContext('2d');
  const selectionInfo = document.getElementById('selectionInfo');
  const actionsEl = document.getElementById('actions');
  const playerListEl = document.getElementById('playerList');

  const RESOURCE_COLORS = { wood: '#8a5a2b', food: '#c93b3b', gold: '#d9b23c' };

  let ws = null;
  let myId = null;
  let staticInfo = null; // { mapWidth, mapHeight, unitTypes, buildingTypes }
  let prevState = null;
  let curState = null;
  let lastStateAt = 0;

  const camera = { x: 0, y: 0 };
  const selectedUnitIds = new Set();
  let selectedBuildingId = null;
  let pendingBuild = null; // buildingType string while placing

  let dragStart = null; // {x,y} screen coords, while left-button held
  let dragCurrent = null;

  // ---------- Networking ----------

  function connect(name) {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${proto}://${location.host}`);
    ws.onopen = () => ws.send(JSON.stringify({ type: 'join', name }));
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'welcome') {
        myId = msg.playerId;
        staticInfo = { mapWidth: msg.mapWidth, mapHeight: msg.mapHeight, unitTypes: msg.unitTypes, buildingTypes: msg.buildingTypes };
        joinScreen.classList.add('hidden');
        gameEl.classList.remove('hidden');
        resizeCanvas();
        if (canvas.width < 500) TILE = 18;
        centerCameraOnSelf();
        requestAnimationFrame(loop);
      } else if (msg.type === 'state') {
        prevState = curState;
        curState = msg;
        lastStateAt = performance.now();
        updateHud();
      }
    };
    ws.onclose = () => {
      joinError.textContent = 'Disconnected from server.';
      joinScreen.classList.remove('hidden');
      gameEl.classList.add('hidden');
    };
    ws.onerror = () => { joinError.textContent = 'Could not connect to server.'; };
  }

  function sendCommand(cmd) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'command', cmd }));
  }

  joinBtn.addEventListener('click', doJoin);
  nameInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') doJoin(); });
  function doJoin() {
    const name = nameInput.value.trim() || `Player${Math.floor(Math.random() * 1000)}`;
    joinError.textContent = '';
    connect(name);
  }

  function centerCameraOnSelf() {
    if (!curState) return;
    const myUnits = curState.units.filter((u) => u.ownerId === myId);
    const myBuildings = curState.buildings.filter((b) => b.ownerId === myId);
    const anchor = myBuildings[0] || myUnits[0];
    if (anchor) {
      camera.x = anchor.x - visibleTilesW() / 2;
      camera.y = anchor.y - visibleTilesH() / 2;
    }
  }

  // ---------- Camera / coordinate helpers ----------

  function visibleTilesW() { return canvas.width / TILE; }
  function visibleTilesH() { return canvas.height / TILE; }

  function clampCamera() {
    if (!staticInfo) return;
    const maxX = Math.max(0, staticInfo.mapWidth - visibleTilesW());
    const maxY = Math.max(0, staticInfo.mapHeight - visibleTilesH());
    camera.x = Math.max(0, Math.min(maxX, camera.x));
    camera.y = Math.max(0, Math.min(maxY, camera.y));
  }

  function worldToScreen(x, y) { return { x: (x - camera.x) * TILE, y: (y - camera.y) * TILE }; }
  function screenToWorld(x, y) { return { x: camera.x + x / TILE, y: camera.y + y / TILE }; }

  function resizeCanvas() {
    canvas.width = canvas.clientWidth;
    canvas.height = canvas.clientHeight;
    clampCamera();
  }
  window.addEventListener('resize', resizeCanvas);
  window.addEventListener('orientationchange', () => setTimeout(resizeCanvas, 200));

  // ---------- Keyboard panning ----------

  const keys = new Set();
  window.addEventListener('keydown', (e) => {
    keys.add(e.key.toLowerCase());
    if (e.key === 'Escape') { pendingBuild = null; renderActions(); }
  });
  window.addEventListener('keyup', (e) => keys.delete(e.key.toLowerCase()));

  function updateCameraFromKeys(dt) {
    const speed = 12 * dt;
    if (keys.has('arrowleft') || keys.has('a')) camera.x -= speed;
    if (keys.has('arrowright') || keys.has('d')) camera.x += speed;
    if (keys.has('arrowup') || keys.has('w')) camera.y -= speed;
    if (keys.has('arrowdown') || keys.has('s')) camera.y += speed;
    clampCamera();
  }

  // ---------- Entity lookup helpers ----------

  function entityAt(worldX, worldY) {
    if (!curState) return null;
    for (const u of curState.units) {
      if (Math.hypot(u.x - worldX, u.y - worldY) < 0.5) return { kind: 'unit', obj: u };
    }
    for (const b of curState.buildings) {
      const bt = staticInfo.buildingTypes[b.type];
      const half = bt.size / 2;
      if (Math.abs(b.x - worldX) < half && Math.abs(b.y - worldY) < half) return { kind: 'building', obj: b };
    }
    for (const r of curState.resources) {
      if (Math.hypot(r.x - worldX, r.y - worldY) < 0.5) return { kind: 'resource', obj: r };
    }
    return null;
  }

  // ---------- Pointer input (mouse + touch share the same select/command logic) ----------

  let pinch = null; // {startDist, startTile, startWorldMid}

  canvas.addEventListener('contextmenu', (e) => e.preventDefault());

  // Mouse (desktop)
  canvas.addEventListener('mousedown', (e) => {
    const rect = canvas.getBoundingClientRect();
    const sx = e.clientX - rect.left;
    const sy = e.clientY - rect.top;
    if (e.button === 0) {
      if (pendingBuild) {
        placeBuildingAt(sx, sy);
        return;
      }
      dragStart = { x: sx, y: sy };
      dragCurrent = { x: sx, y: sy };
    } else if (e.button === 2) {
      const world = screenToWorld(sx, sy);
      issueContextCommand(entityAt(world.x, world.y), world);
    }
  });

  canvas.addEventListener('mousemove', (e) => {
    if (!dragStart) return;
    const rect = canvas.getBoundingClientRect();
    dragCurrent = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  });

  window.addEventListener('mouseup', (e) => {
    if (e.button !== 0 || !dragStart) return;
    finishPointer();
    dragStart = null;
    dragCurrent = null;
  });

  // Touch (mobile / iOS) — one finger selects/drags/commands, two fingers pinch-zoom + pan.
  canvas.addEventListener('touchstart', (e) => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    if (e.touches.length === 1) {
      pinch = null;
      const sx = e.touches[0].clientX - rect.left;
      const sy = e.touches[0].clientY - rect.top;
      if (pendingBuild) {
        placeBuildingAt(sx, sy);
        return;
      }
      dragStart = { x: sx, y: sy };
      dragCurrent = { x: sx, y: sy };
    } else if (e.touches.length === 2) {
      dragStart = null;
      dragCurrent = null;
      pinch = beginPinch(e.touches, rect);
    }
  }, { passive: false });

  canvas.addEventListener('touchmove', (e) => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    if (pinch && e.touches.length === 2) {
      updatePinch(e.touches, rect);
    } else if (dragStart && e.touches.length === 1) {
      dragCurrent = { x: e.touches[0].clientX - rect.left, y: e.touches[0].clientY - rect.top };
    }
  }, { passive: false });

  canvas.addEventListener('touchend', (e) => {
    e.preventDefault();
    if (pinch) {
      if (e.touches.length < 2) pinch = null;
      return;
    }
    if (dragStart && dragCurrent) finishPointer();
    dragStart = null;
    dragCurrent = null;
  }, { passive: false });

  canvas.addEventListener('touchcancel', () => {
    pinch = null;
    dragStart = null;
    dragCurrent = null;
  });

  function touchDist(touches) {
    return Math.hypot(touches[0].clientX - touches[1].clientX, touches[0].clientY - touches[1].clientY);
  }
  function touchMid(touches, rect) {
    return {
      x: (touches[0].clientX + touches[1].clientX) / 2 - rect.left,
      y: (touches[0].clientY + touches[1].clientY) / 2 - rect.top,
    };
  }
  function beginPinch(touches, rect) {
    const mid = touchMid(touches, rect);
    return { startDist: touchDist(touches), startTile: TILE, startWorldMid: screenToWorld(mid.x, mid.y) };
  }
  function updatePinch(touches, rect) {
    const ratio = touchDist(touches) / pinch.startDist;
    TILE = Math.max(MIN_TILE, Math.min(MAX_TILE, pinch.startTile * ratio));
    const mid = touchMid(touches, rect);
    camera.x = pinch.startWorldMid.x - mid.x / TILE;
    camera.y = pinch.startWorldMid.y - mid.y / TILE;
    clampCamera();
  }

  function finishPointer() {
    const dx = Math.abs(dragCurrent.x - dragStart.x);
    const dy = Math.abs(dragCurrent.y - dragStart.y);
    if (dx < 6 && dy < 6) {
      handleTap(dragStart.x, dragStart.y);
    } else {
      handleDragSelect(dragStart, dragCurrent);
    }
  }

  // Tapping/clicking one of your own units or buildings selects it. Tapping anything
  // else while you have a selection issues the context-appropriate command (this is
  // what right-click does on desktop, and doubles as "tap to command" on touch).
  function handleTap(sx, sy) {
    const world = screenToWorld(sx, sy);
    const hit = entityAt(world.x, world.y);

    if (hit && hit.kind === 'unit' && hit.obj.ownerId === myId) {
      selectedUnitIds.clear();
      selectedBuildingId = null;
      selectedUnitIds.add(hit.obj.id);
      renderActions();
      return;
    }
    if (hit && hit.kind === 'building' && hit.obj.ownerId === myId) {
      selectedUnitIds.clear();
      selectedBuildingId = hit.obj.id;
      renderActions();
      return;
    }
    if (selectedUnitIds.size > 0 || selectedBuildingId) {
      issueContextCommand(hit, world);
      return;
    }
    deselectAll();
  }

  function handleDragSelect(start, end) {
    const w1 = screenToWorld(Math.min(start.x, end.x), Math.min(start.y, end.y));
    const w2 = screenToWorld(Math.max(start.x, end.x), Math.max(start.y, end.y));
    selectedUnitIds.clear();
    selectedBuildingId = null;
    for (const u of curState.units) {
      if (u.ownerId === myId && u.x >= w1.x && u.x <= w2.x && u.y >= w1.y && u.y <= w2.y) {
        selectedUnitIds.add(u.id);
      }
    }
    renderActions();
  }

  function issueContextCommand(hit, world) {
    if (selectedUnitIds.size > 0) {
      const ids = [...selectedUnitIds];
      if (hit && hit.kind === 'resource') {
        sendCommand({ action: 'gather', unitIds: ids, resourceId: hit.obj.id });
      } else if (hit && (hit.kind === 'unit' || hit.kind === 'building') && hit.obj.ownerId !== myId) {
        sendCommand({ action: 'attack', unitIds: ids, targetId: hit.obj.id });
      } else {
        sendCommand({ action: 'move', unitIds: ids, x: world.x, y: world.y });
      }
      return;
    }
    if (selectedBuildingId) {
      const b = curState.buildings.find((bb) => bb.id === selectedBuildingId);
      if (b && b.ownerId === myId && !hit) {
        sendCommand({ action: 'setRally', buildingId: b.id, x: world.x, y: world.y });
      }
    }
  }

  function deselectAll() {
    selectedUnitIds.clear();
    selectedBuildingId = null;
    renderActions();
  }

  function placeBuildingAt(sx, sy) {
    const world = screenToWorld(sx, sy);
    const ids = [...selectedUnitIds];
    if (ids.length === 0) { pendingBuild = null; renderActions(); return; }
    sendCommand({ action: 'build', unitIds: ids, buildingType: pendingBuild, x: world.x, y: world.y });
    pendingBuild = null;
    renderActions();
  }

  // ---------- HUD ----------

  function myPlayer() {
    return curState ? curState.players.find((p) => p.id === myId) : null;
  }

  function updateHud() {
    const p = myPlayer();
    if (p) {
      document.getElementById('resWood').textContent = Math.floor(p.resources.wood);
      document.getElementById('resFood').textContent = Math.floor(p.resources.food);
      document.getElementById('resGold').textContent = Math.floor(p.resources.gold);
      document.getElementById('resPop').textContent = `${p.population}/${p.popCap}`;
    }
    playerListEl.innerHTML = '';
    for (const pl of curState.players) {
      const tag = document.createElement('div');
      tag.className = 'playerTag' + (pl.eliminated ? ' eliminated' : '');
      tag.innerHTML = `<span class="swatch" style="background:${pl.color}"></span>${pl.name}`;
      playerListEl.appendChild(tag);
    }
    renderActions();
  }

  function renderActions() {
    if (!curState || !staticInfo) return;
    actionsEl.innerHTML = '';
    const ownSelectedUnits = curState.units.filter((u) => selectedUnitIds.has(u.id));
    const villagerSelected = ownSelectedUnits.some((u) => u.type === 'villager');

    if (ownSelectedUnits.length > 0) {
      selectionInfo.textContent = summarizeUnits(ownSelectedUnits);
      actionsEl.appendChild(makeBtn('Stop', () => sendCommand({ action: 'stop', unitIds: [...selectedUnitIds] })));
      actionsEl.appendChild(makeBtn('Deselect', deselectAll));
    }

    if (villagerSelected) {
      for (const [key, bt] of Object.entries(staticInfo.buildingTypes)) {
        if (key === 'townCenter') continue;
        const costStr = Object.entries(bt.cost).map(([k, v]) => `${v}${k[0]}`).join(' ');
        const btn = makeBtn(`Build ${bt.name} (${costStr || 'free'})`, () => {
          pendingBuild = key;
          renderActions();
        });
        if (pendingBuild === key) btn.classList.add('active');
        actionsEl.appendChild(btn);
      }
      if (pendingBuild) {
        const hint = document.createElement('div');
        hint.textContent = 'Tap the map to place the building.';
        actionsEl.appendChild(hint);
        actionsEl.appendChild(makeBtn('Cancel', () => { pendingBuild = null; renderActions(); }));
      }
    }

    if (selectedBuildingId) {
      const b = curState.buildings.find((bb) => bb.id === selectedBuildingId);
      if (b) {
        const bt = staticInfo.buildingTypes[b.type];
        selectionInfo.textContent = `${bt.name} — HP ${Math.ceil(b.hp)}/${b.maxHp}` +
          (b.constructed ? '' : ` (building ${Math.floor(b.buildProgress * 100)}%)`) +
          (b.trainQueue.length ? ` — queue: ${b.trainQueue.length}` : '');
        actionsEl.appendChild(makeBtn('Deselect', deselectAll));
        if (b.ownerId === myId && b.constructed) {
          for (const unitKey of bt.trains) {
            const ut = staticInfo.unitTypes[unitKey];
            const costStr = Object.entries(ut.cost).map(([k, v]) => `${v}${k[0]}`).join(' ');
            actionsEl.appendChild(makeBtn(`Train ${ut.name} (${costStr})`, () => {
              sendCommand({ action: 'train', buildingId: b.id, unitType: unitKey });
            }));
          }
        }
      }
    }

    if (ownSelectedUnits.length === 0 && !selectedBuildingId) {
      selectionInfo.textContent = 'Nothing selected';
    }
  }

  function makeBtn(label, onClick) {
    const btn = document.createElement('button');
    btn.className = 'actionBtn';
    btn.textContent = label;
    btn.addEventListener('click', onClick);
    return btn;
  }

  function summarizeUnits(units) {
    const counts = {};
    for (const u of units) counts[u.type] = (counts[u.type] || 0) + 1;
    const parts = Object.entries(counts).map(([type, n]) => `${n} ${staticInfo.unitTypes[type].name}${n > 1 ? 's' : ''}`);
    return parts.join(', ');
  }

  // ---------- Rendering ----------

  function lerp(a, b, t) { return a + (b - a) * t; }

  function interpolatedUnits() {
    if (!curState) return [];
    if (!prevState) return curState.units;
    const prevMap = new Map(prevState.units.map((u) => [u.id, u]));
    const t = Math.max(0, Math.min(1, (performance.now() - lastStateAt) / TICK_MS));
    return curState.units.map((u) => {
      const pu = prevMap.get(u.id);
      if (!pu) return u;
      return { ...u, x: lerp(pu.x, u.x, t), y: lerp(pu.y, u.y, t) };
    });
  }

  function draw() {
    ctx.fillStyle = '#3a5320';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    drawGrid();

    if (!curState || !staticInfo) return;

    for (const r of curState.resources) drawResource(r);
    for (const b of curState.buildings) drawBuilding(b);
    for (const u of interpolatedUnits()) drawUnit(u);

    if (dragStart && dragCurrent) {
      ctx.strokeStyle = '#e8c96a';
      ctx.lineWidth = 1;
      ctx.strokeRect(
        Math.min(dragStart.x, dragCurrent.x), Math.min(dragStart.y, dragCurrent.y),
        Math.abs(dragCurrent.x - dragStart.x), Math.abs(dragCurrent.y - dragStart.y),
      );
    }
  }

  function drawGrid() {
    ctx.strokeStyle = 'rgba(255,255,255,0.05)';
    ctx.lineWidth = 1;
    const startX = Math.floor(camera.x);
    const startY = Math.floor(camera.y);
    for (let x = startX; x <= camera.x + visibleTilesW() + 1; x++) {
      const sx = worldToScreen(x, 0).x;
      ctx.beginPath(); ctx.moveTo(sx, 0); ctx.lineTo(sx, canvas.height); ctx.stroke();
    }
    for (let y = startY; y <= camera.y + visibleTilesH() + 1; y++) {
      const sy = worldToScreen(0, y).y;
      ctx.beginPath(); ctx.moveTo(0, sy); ctx.lineTo(canvas.width, sy); ctx.stroke();
    }
  }

  function drawResource(r) {
    const p = worldToScreen(r.x, r.y);
    if (p.x < -TILE || p.y < -TILE || p.x > canvas.width + TILE || p.y > canvas.height + TILE) return;
    ctx.fillStyle = RESOURCE_COLORS[r.type];
    ctx.beginPath();
    ctx.arc(p.x, p.y, TILE * 0.32, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = 'rgba(0,0,0,0.4)';
    ctx.stroke();
  }

  function playerColor(ownerId) {
    const pl = curState.players.find((p) => p.id === ownerId);
    return pl ? pl.color : '#888';
  }

  function drawBuilding(b) {
    const bt = staticInfo.buildingTypes[b.type];
    const topLeft = worldToScreen(b.x - bt.size / 2, b.y - bt.size / 2);
    const size = bt.size * TILE;
    if (topLeft.x + size < 0 || topLeft.y + size < 0 || topLeft.x > canvas.width || topLeft.y > canvas.height) return;

    ctx.fillStyle = b.constructed ? playerColor(b.ownerId) : shadeColor(playerColor(b.ownerId), 0.5);
    ctx.fillRect(topLeft.x, topLeft.y, size, size);
    ctx.strokeStyle = selectedBuildingId === b.id ? '#fff' : 'rgba(0,0,0,0.5)';
    ctx.lineWidth = selectedBuildingId === b.id ? 2 : 1;
    ctx.strokeRect(topLeft.x, topLeft.y, size, size);

    drawHpBar(topLeft.x, topLeft.y - 6, size, b.hp / b.maxHp);
    if (!b.constructed) {
      ctx.fillStyle = '#fff';
      ctx.font = '11px sans-serif';
      ctx.fillText(`${Math.floor(b.buildProgress * 100)}%`, topLeft.x + 2, topLeft.y + size / 2);
    }
  }

  function drawUnit(u) {
    const p = worldToScreen(u.x, u.y);
    if (p.x < -TILE || p.y < -TILE || p.x > canvas.width + TILE || p.y > canvas.height + TILE) return;
    const r = TILE * 0.3;
    ctx.fillStyle = playerColor(u.ownerId);
    ctx.beginPath();
    ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = selectedUnitIds.has(u.id) ? '#fff' : 'rgba(0,0,0,0.5)';
    ctx.lineWidth = selectedUnitIds.has(u.id) ? 2 : 1;
    ctx.stroke();

    if (u.type !== 'villager') {
      ctx.fillStyle = 'rgba(0,0,0,0.6)';
      ctx.beginPath();
      ctx.arc(p.x, p.y, r * 0.4, 0, Math.PI * 2);
      ctx.fill();
    }
    if (u.carryAmount > 0) {
      ctx.fillStyle = RESOURCE_COLORS[u.carryType] || '#fff';
      ctx.fillRect(p.x - 3, p.y - r - 6, 6, 4);
    }
    drawHpBar(p.x - r, p.y - r - 8, r * 2, u.hp / u.maxHp);
  }

  function drawHpBar(x, y, w, ratio) {
    if (ratio >= 1) return;
    ctx.fillStyle = 'rgba(0,0,0,0.6)';
    ctx.fillRect(x, y, w, 3);
    ctx.fillStyle = ratio > 0.5 ? '#6b8f3f' : ratio > 0.25 ? '#d9b23c' : '#c93b3b';
    ctx.fillRect(x, y, w * Math.max(0, ratio), 3);
  }

  function shadeColor(hex, factor) {
    const n = parseInt(hex.slice(1), 16);
    const r = Math.floor(((n >> 16) & 255) * factor);
    const g = Math.floor(((n >> 8) & 255) * factor);
    const b = Math.floor((n & 255) * factor);
    return `rgb(${r},${g},${b})`;
  }

  // ---------- Main loop ----------

  let lastFrame = performance.now();
  function loop(now) {
    const dt = Math.min(0.1, (now - lastFrame) / 1000);
    lastFrame = now;
    updateCameraFromKeys(dt);
    draw();
    requestAnimationFrame(loop);
  }
})();
