(() => {
  const joinScreen = document.getElementById('joinScreen');
  const nameInput = document.getElementById('nameInput');
  const joinBtn = document.getElementById('joinBtn');
  const joinError = document.getElementById('joinError');
  const joinStatus = document.getElementById('joinStatus');
  const demoBtn = document.getElementById('demoBtn');
  const gameEl = document.getElementById('game');
  const mapEl = document.getElementById('map');
  const selectionInfo = document.getElementById('selectionInfo');
  const actionsEl = document.getElementById('actions');
  const playerListEl = document.getElementById('playerList');
  const farBanner = document.getElementById('farBanner');

  const RESOURCE_COLORS = { wood: '#8a5a2b', food: '#c93b3b', gold: '#d9b23c' };
  const DEMO_LOCATION = { lat: 37.7694, lng: -122.4862 }; // Golden Gate Park, for testing without GPS

  let ws = null;
  let myId = null;
  let staticInfo = null; // { unitTypes, buildingTypes, playRadiusM }
  let curState = null;

  let map = null;
  let myPositionMarker = null;
  const entityLayers = new Map(); // 'u123' | 'b45' | 'r7' -> Leaflet layer

  const selectedUnitIds = new Set();
  let selectedBuildingId = null;
  let pendingBuild = null; // buildingType string while placing
  let selectMode = false;
  let rectStart = null;
  let rectLayer = null;

  // ---------- Join flow ----------

  function getLocation() {
    return new Promise((resolve, reject) => {
      if (!navigator.geolocation) { reject(new Error('Geolocation is not supported by this browser.')); return; }
      navigator.geolocation.getCurrentPosition(
        (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
        (err) => reject(err),
        { enableHighAccuracy: true, timeout: 12000, maximumAge: 5000 },
      );
    });
  }

  joinBtn.addEventListener('click', async () => {
    joinError.textContent = '';
    demoBtn.classList.add('hidden');
    joinStatus.textContent = 'Getting your location…';
    joinBtn.disabled = true;
    try {
      const loc = await getLocation();
      doJoin(loc);
    } catch (err) {
      joinStatus.textContent = '';
      joinError.textContent = `Could not get your location (${err.message || err.code || 'unknown error'}).`;
      demoBtn.classList.remove('hidden');
      joinBtn.disabled = false;
    }
  });

  demoBtn.addEventListener('click', () => {
    joinError.textContent = '';
    doJoin(DEMO_LOCATION, true);
  });

  nameInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') joinBtn.click(); });

  function doJoin(loc, isDemo) {
    const name = nameInput.value.trim() || `Player${Math.floor(Math.random() * 1000)}`;
    joinStatus.textContent = isDemo ? 'Joining with demo location…' : 'Connecting…';
    connect(name, loc);
  }

  // ---------- Networking ----------

  function connect(name, loc) {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${proto}://${location.host}`);
    ws.onopen = () => ws.send(JSON.stringify({ type: 'join', name, lat: loc.lat, lng: loc.lng }));
    ws.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'welcome') {
        myId = msg.playerId;
        staticInfo = { unitTypes: msg.unitTypes, buildingTypes: msg.buildingTypes, playRadiusM: msg.playRadiusM };
        joinScreen.classList.add('hidden');
        gameEl.classList.remove('hidden');
        if (msg.farFromOrigin) {
          farBanner.classList.remove('hidden');
          farBanner.textContent = `You're ~${msg.distanceFromOriginM}m from the play area — your base may be out of reach of everyone else.`;
        }
        initMap(loc, msg.originLat, msg.originLng);
        watchMyPosition();
      } else if (msg.type === 'state') {
        curState = msg;
        updateHud();
        updateEntities();
      } else if (msg.type === 'error') {
        joinStatus.textContent = '';
        joinError.textContent = msg.message;
        joinBtn.disabled = false;
      }
    };
    ws.onclose = () => {
      joinStatus.textContent = '';
      joinError.textContent = 'Disconnected from server.';
      joinScreen.classList.remove('hidden');
      gameEl.classList.add('hidden');
      joinBtn.disabled = false;
    };
    ws.onerror = () => {
      joinStatus.textContent = '';
      joinError.textContent = 'Could not connect to server.';
      joinBtn.disabled = false;
    };
  }

  function sendCommand(cmd) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'command', cmd }));
  }

  function watchMyPosition() {
    if (!navigator.geolocation) return;
    navigator.geolocation.watchPosition(
      (pos) => {
        const ll = [pos.coords.latitude, pos.coords.longitude];
        if (!myPositionMarker) {
          myPositionMarker = L.circleMarker(ll, {
            radius: 8, color: '#3a8bfd', weight: 2, fillColor: '#3a8bfd', fillOpacity: 0.4,
          }).addTo(map).bindTooltip('You', { permanent: false });
        } else {
          myPositionMarker.setLatLng(ll);
        }
      },
      () => {},
      { enableHighAccuracy: true, maximumAge: 5000 },
    );
  }

  // ---------- Map setup ----------

  function initMap(myLoc, originLat, originLng) {
    map = L.map(mapEl, { zoomControl: true, attributionControl: true, tap: true }).setView([myLoc.lat, myLoc.lng], 19);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 21, maxNativeZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(map);
    L.circle([originLat, originLng], {
      radius: staticInfo.playRadiusM, color: '#e8c96a', weight: 1, fillOpacity: 0.04, dashArray: '6 6',
    }).addTo(map);

    map.on('click', (e) => onMapClick(e.latlng));

    // Capture-phase + window-level listeners: while box-selecting, a drag can
    // start or end on top of a rendered unit/resource marker, and Leaflet's
    // own per-layer handlers (bubble phase) would otherwise intercept the
    // event first — capturing on window guarantees the drag always
    // completes regardless of what's under the pointer at release time.
    window.addEventListener('pointerdown', onPointerDown, { capture: true });
    window.addEventListener('pointermove', onPointerMove, { capture: true });
    window.addEventListener('pointerup', onPointerUp, { capture: true });
    window.addEventListener('pointercancel', onPointerCancel, { capture: true });
  }

  // ---------- Selection / commands ----------

  function onEntityClick(kind, obj) {
    // Placement mode wins over normal entity clicks — otherwise tapping
    // anywhere near an existing unit/building/resource (very likely on a
    // crowded map) hits that marker's own click handler first and silently
    // reselects it instead of placing the building, with no feedback.
    if (pendingBuild) {
      placeBuildingAt(L.latLng(obj.lat, obj.lng));
      return;
    }
    if ((kind === 'unit' || kind === 'building') && obj.ownerId === myId) {
      selectedUnitIds.clear();
      selectedBuildingId = null;
      if (kind === 'unit') selectedUnitIds.add(obj.id); else selectedBuildingId = obj.id;
      renderActions();
      restyleSelection();
      return;
    }
    if (selectedUnitIds.size > 0 || selectedBuildingId) {
      issueContextCommand({ kind, obj }, L.latLng(obj.lat, obj.lng));
      return;
    }
    deselectAll();
  }

  function onMapClick(latlng) {
    if (pendingBuild) {
      placeBuildingAt(latlng);
      return;
    }
    if (selectedUnitIds.size > 0 || selectedBuildingId) {
      issueContextCommand(null, latlng);
      return;
    }
    deselectAll();
  }

  function issueContextCommand(hit, latlng) {
    if (selectedUnitIds.size > 0) {
      const ids = [...selectedUnitIds];
      if (hit && hit.kind === 'resource') {
        sendCommand({ action: 'gather', unitIds: ids, resourceId: hit.obj.id });
      } else if (hit && (hit.kind === 'unit' || hit.kind === 'building') && hit.obj.ownerId !== myId) {
        sendCommand({ action: 'attack', unitIds: ids, targetId: hit.obj.id });
      } else {
        sendCommand({ action: 'move', unitIds: ids, lat: latlng.lat, lng: latlng.lng });
      }
      return;
    }
    if (selectedBuildingId) {
      const b = curState.buildings.find((bb) => bb.id === selectedBuildingId);
      if (b && b.ownerId === myId && !hit) {
        sendCommand({ action: 'setRally', buildingId: b.id, lat: latlng.lat, lng: latlng.lng });
      }
    }
  }

  function deselectAll() {
    selectedUnitIds.clear();
    selectedBuildingId = null;
    renderActions();
    restyleSelection();
  }

  function placeBuildingAt(latlng) {
    const ids = [...selectedUnitIds];
    if (ids.length === 0) { pendingBuild = null; renderActions(); return; }
    sendCommand({ action: 'build', unitIds: ids, buildingType: pendingBuild, lat: latlng.lat, lng: latlng.lng });
    pendingBuild = null;
    renderActions();
  }

  // ---------- Box-select mode (Leaflet owns drag/pinch for panning, so this is opt-in) ----------

  function toggleSelectMode() {
    selectMode = !selectMode;
    if (selectMode) map.dragging.disable(); else map.dragging.enable();
    renderActions();
  }

  function onPointerDown(e) {
    if (!selectMode || !map.getContainer().contains(e.target)) return;
    // Prevent Leaflet's own per-marker handling (e.g. a unit's click-to-select)
    // from also reacting to this same press while we're box-selecting.
    e.stopPropagation();
    // Explicit pointer capture is required here: without it, as soon as the
    // drag crosses over one of the many rendered unit/resource markers (SVG
    // paths with their own touch-action), Chromium/WebKit fire `pointercancel`
    // mid-drag and the gesture silently dies — reproduced with plain mouse
    // input too, not just touch. Capturing on the map container pins all
    // subsequent events to it regardless of what's visually underneath.
    const containerEl = map.getContainer();
    if (containerEl.setPointerCapture) {
      try { containerEl.setPointerCapture(e.pointerId); } catch { /* not critical if unsupported */ }
    }
    rectStart = map.mouseEventToLatLng(e);
    rectLayer = L.rectangle([rectStart, rectStart], { color: '#e8c96a', weight: 1, fillOpacity: 0.1 }).addTo(map);
  }

  function onPointerMove(e) {
    if (!selectMode || !rectStart) return;
    e.stopPropagation();
    rectLayer.setBounds(L.latLngBounds([rectStart, map.mouseEventToLatLng(e)]));
  }

  function onPointerUp(e) {
    if (!selectMode || !rectStart) return;
    e.stopPropagation();
    finishBoxSelect(map.mouseEventToLatLng(e));
  }

  function onPointerCancel(e) {
    if (!selectMode || !rectStart) return;
    e.stopPropagation();
    // A real device can legitimately cancel an in-progress gesture (a call
    // coming in, the OS taking over, etc.) — finish the select with whatever
    // the rectangle covered so far rather than leaving state stuck.
    finishBoxSelect(map.mouseEventToLatLng(e));
  }

  function finishBoxSelect(endLatLng) {
    const bounds = L.latLngBounds([rectStart, endLatLng]);
    selectedUnitIds.clear();
    selectedBuildingId = null;
    if (curState) {
      for (const u of curState.units) {
        if (u.ownerId === myId && bounds.contains([u.lat, u.lng])) selectedUnitIds.add(u.id);
      }
    }
    map.removeLayer(rectLayer);
    rectLayer = null;
    rectStart = null;
    selectMode = false;
    map.dragging.enable();
    renderActions();
    restyleSelection();
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
    actionsEl.appendChild(makeBtn(selectMode ? 'Cancel Select' : 'Select', toggleSelectMode, selectMode));

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
        }, pendingBuild === key);
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

  function makeBtn(label, onClick, active) {
    const btn = document.createElement('button');
    btn.className = 'actionBtn' + (active ? ' active' : '');
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

  // ---------- Map entity rendering ----------

  function playerColor(ownerId) {
    const pl = curState.players.find((p) => p.id === ownerId);
    return pl ? pl.color : '#888';
  }

  function updateEntities() {
    const seen = new Set();

    for (const u of curState.units) {
      const key = `u${u.id}`;
      seen.add(key);
      let layer = entityLayers.get(key);
      const isMine = u.ownerId === myId;
      const isSelected = selectedUnitIds.has(u.id);
      const style = {
        radius: u.type === 'villager' ? 6 : 7,
        color: isSelected ? '#fff' : 'rgba(0,0,0,0.6)',
        weight: isSelected ? 3 : 1,
        fillColor: playerColor(u.ownerId),
        fillOpacity: u.type === 'villager' ? 0.85 : 1,
      };
      if (!layer) {
        layer = L.circleMarker([u.lat, u.lng], style).addTo(map);
        layer.on('click', (e) => { L.DomEvent.stopPropagation(e); onEntityClick('unit', layer._data); });
        entityLayers.set(key, layer);
      } else {
        layer.setLatLng([u.lat, u.lng]);
        layer.setStyle(style);
      }
      layer._data = u;
      if (!layer.getTooltip()) layer.bindTooltip('', { direction: 'top', offset: [0, -6] });
      layer.setTooltipContent(
        `${staticInfo.unitTypes[u.type].name}${isMine ? '' : ' (enemy)'} — HP ${Math.ceil(u.hp)}/${u.maxHp}` +
        (u.carryAmount > 0 ? ` — carrying ${Math.floor(u.carryAmount)} ${u.carryType}` : ''),
      );
    }

    for (const b of curState.buildings) {
      const key = `b${b.id}`;
      seen.add(key);
      let layer = entityLayers.get(key);
      const bt = staticInfo.buildingTypes[b.type];
      const isSelected = selectedBuildingId === b.id;
      const style = {
        radius: bt.size / 2,
        color: isSelected ? '#fff' : 'rgba(0,0,0,0.6)',
        weight: isSelected ? 3 : 2,
        fillColor: playerColor(b.ownerId),
        fillOpacity: b.constructed ? 0.55 : 0.25,
      };
      if (!layer) {
        layer = L.circle([b.lat, b.lng], style).addTo(map);
        layer.on('click', (e) => { L.DomEvent.stopPropagation(e); onEntityClick('building', layer._data); });
        layer.bindTooltip('', { direction: 'top' });
        entityLayers.set(key, layer);
      } else {
        layer.setLatLng([b.lat, b.lng]);
        layer.setStyle(style);
      }
      layer._data = b;
      const progressStr = b.constructed ? '' : ` — building ${Math.floor(b.buildProgress * 100)}%`;
      layer.setTooltipContent(`${bt.name} — HP ${Math.ceil(b.hp)}/${b.maxHp}${progressStr}`);
    }

    for (const r of curState.resources) {
      const key = `r${r.id}`;
      seen.add(key);
      let layer = entityLayers.get(key);
      const style = { radius: 5, color: 'rgba(0,0,0,0.4)', weight: 1, fillColor: RESOURCE_COLORS[r.type], fillOpacity: 0.9 };
      if (!layer) {
        layer = L.circleMarker([r.lat, r.lng], style).addTo(map);
        layer.on('click', (e) => { L.DomEvent.stopPropagation(e); onEntityClick('resource', layer._data); });
        layer.bindTooltip('', { direction: 'top' });
        entityLayers.set(key, layer);
      } else {
        layer.setLatLng([r.lat, r.lng]);
      }
      layer._data = r;
      layer.setTooltipContent(`${r.type} — ${Math.floor(r.amount)}/${r.maxAmount}`);
    }

    for (const [key, layer] of entityLayers) {
      if (!seen.has(key)) {
        map.removeLayer(layer);
        entityLayers.delete(key);
      }
    }
  }

  function restyleSelection() {
    if (curState) updateEntities();
  }
})();
