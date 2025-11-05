-- Simple mission state persistence for DCS
-- Saves destroyed units/statics and re-applies on next mission start.

-- CONFIG
local Persistence = {
  -- Set a custom key (string) to bind the save file to this mission.
  -- Leave as nil to auto-fingerprint the mission setup.
  missionKey = nil,

  -- Directory (under Saved Games) to store state files
  dirName = "Missions/Persistence",

  -- Auto-save every N seconds (nil/false to disable periodic saving)
  autosaveSeconds = 60,

  -- Apply saved positions for categories (teleport by respawn)
  -- Aircraft/helos now supported (AI only)
  repositionCategories = { vehicle = true, ship = true, plane = true, helicopter = true },

  -- Delay between respawning groups when applying positions (seconds)
  spawnThrottleSeconds = 0.2,

  -- Track client/player losses too? (false keeps client slots fresh)
  trackClientLosses = false,

  -- Internal state container
  state = {
    deadUnits = {},
    deadStatics = {},
    unitPos = {},
  },

  _saveDebounce = false,
  _bootstrapped = false,
  _autosaveStarted = false,
  _templateIndexBuilt = false,
  _groupTemplates = {}, -- [groupName] = { tpl=table, countryId=number, categoryKey=string }
  _unitToGroup = {},    -- [unitName] = groupName
}

-- UTIL: Safe logging
local function log(msg)
  if env and env.info then env.info("[Persistence] " .. tostring(msg)) end
end

-- UTIL: Path helpers
local function joinPath(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then
    return a .. b
  end
  return a .. "/" .. b
end

local function ensureDir(path)
  if not lfs or not lfs.mkdir then return true end
  local ok = lfs.mkdir(path)
  return ok or true -- ignore if exists
end

-- UTIL: Sanitize filename from key
local function sanitizeKey(s)
  s = tostring(s or "mission")
  s = s:gsub("[^%w%._%-]", "_")
  if #s == 0 then s = "mission" end
  return s
end

-- UTIL: Simple stable hash (djb2, 32-bit) for fingerprinting
local function djb2(s)
  local hash = 5381
  for i = 1, #s do
    hash = ((hash * 33) % 4294967296 + s:byte(i)) % 4294967296
  end
  return hash
end

local function tohex32(n)
  return string.format("%08x", n % 4294967296)
end

-- UTIL: Collect sorted group names from a coalition side table
local function collectGroupNames(sideTbl)
  local names = {}
  if not sideTbl or not sideTbl.country then return names end
  for _, country in pairs(sideTbl.country) do
    local branches = {"plane", "helicopter", "vehicle", "ship", "static"}
    for _, branch in ipairs(branches) do
      local b = country[branch]
      if b and b.group then
        for _, g in pairs(b.group) do
          if g and g.name then table.insert(names, tostring(g.name)) end
        end
      end
    end
  end
  table.sort(names)
  return names
end

-- Build a stable fingerprint of the current mission setup
function Persistence:computeFingerprint()
  local theatre = (env and env.mission and env.mission.theatre) or "unknown"
  local generalName = (env and env.mission and env.mission.general and env.mission.general.name) or ""
  local names = {}
  if env and env.mission and env.mission.coalition then
    local sides = {
      env.mission.coalition.blue,
      env.mission.coalition.red,
      env.mission.coalition.neutral,
    }
    for _, side in ipairs(sides) do
      local arr = collectGroupNames(side)
      for _, n in ipairs(arr) do table.insert(names, n) end
    end
  end
  local base = theatre .. "|" .. generalName .. "|" .. table.concat(names, ",")
  local h = djb2(base)
  return "fpv1:" .. tohex32(h)
end

-- UTIL: Serialize a simple table as Lua literal (no cycles)
local function serialize(val, indent)
  indent = indent or ""
  local t = type(val)
  if t == "number" or t == "boolean" then
    return tostring(val)
  elseif t == "string" then
    return string.format("%q", val)
  elseif t == "table" then
    local pieces = {"{"}
    local nextIndent = indent .. "  "
    for k, v in pairs(val) do
      local key
      if type(k) == "string" and k:match("^[_%a][_%w]*$") then
        key = k .. " = "
      else
        key = "[" .. serialize(k, nextIndent) .. "] = "
      end
      table.insert(pieces, "\n" .. nextIndent .. key .. serialize(v, nextIndent) .. ",")
    end
    table.insert(pieces, "\n" .. indent .. "}")
    return table.concat(pieces)
  else
    return "nil"
  end
end

-- UTIL: Deep copy a table (no cycles expected)
local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k,v in pairs(t) do
    r[deepcopy(k)] = deepcopy(v)
  end
  return r
end

-- Build base directory under Saved Games
function Persistence:ioAvailable()
  return type(lfs) == "table" and type(io) == "table" and type(lfs.writedir) == "function" and type(io.open) == "function"
end

function Persistence:getBaseDir()
  if not self:ioAvailable() then return nil end
  local base = lfs.writedir() or "" -- e.g., C:\\Users\\<you>\\Saved Games\\DCS.openbeta\\
  local dir = joinPath(base, self.dirName)
  ensureDir(dir)
  return dir
end

-- Attempt to derive a stable mission key if none provided
local function countSide(sideTbl)
  local total = 0
  if not sideTbl or not sideTbl.country then return 0 end
  for _, country in pairs(sideTbl.country) do
    local branches = {"plane", "helicopter", "vehicle", "ship", "static"}
    for _, branch in ipairs(branches) do
      local b = country[branch]
      if b and b.group then
        for _, g in pairs(b.group) do
          if g.units then total = total + #g.units end
        end
      end
    end
  end
  return total
end

function Persistence:autoKey()
  local theatre = (env and env.mission and env.mission.theatre) or "unknown"
  local generalName = (env and env.mission and env.mission.general and env.mission.general.name) or nil
  local blue = 0
  local red = 0
  local neu = 0
  if env and env.mission and env.mission.coalition then
    blue = countSide(env.mission.coalition.blue)
    red  = countSide(env.mission.coalition.red)
    neu  = countSide(env.mission.coalition.neutral)
  end
  local key = generalName or (theatre .. "_" .. tostring(blue) .. "_" .. tostring(red) .. "_" .. tostring(neu))
  return sanitizeKey(key)
end

function Persistence:getKey()
  return sanitizeKey(self.missionKey or self:autoKey())
end

function Persistence:getStatePath()
  local dir = self:getBaseDir()
  if not dir then return nil end
  local file = self:getKey() .. ".lua"
  return joinPath(dir, file)
end

function Persistence:save(force)
  if not self:ioAvailable() then
    log("File I/O disabled (MissionScripting.lua). Persistence OFF.")
    return false
  end
  -- Debounce frequent saves unless forced
  if not force and self._saveDebounce then return end
  if not force then
    self._saveDebounce = true
    timer.scheduleFunction(function()
      self._saveDebounce = false
      self:save(true)
    end, {}, timer.getTime() + 5)
    return
  end

  -- Update alive unit positions snapshot before writing
  self:captureUnitPositions()

  local path = self:getStatePath()
  if not path then return false end
  local f, err = io.open(path, "w")
  if not f then
    log("Failed to open state for write: " .. tostring(err))
    return false
  end
  -- Attach meta to ensure correct mission on load
  local theatre = (env and env.mission and env.mission.theatre) or "unknown"
  local generalName = (env and env.mission and env.mission.general and env.mission.general.name) or nil
  self.state.meta = {
    key = self:getKey(),
    fp = self:computeFingerprint(),
    theatre = theatre,
    missionName = generalName,
  }
  local payload = "return " .. serialize(self.state)
  f:write(payload)
  f:close()
  log("Saved state to " .. path)
  return true
end

function Persistence:load()
  if not self:ioAvailable() then return false end
  local path = self:getStatePath()
  if not path then return false end
  local f = io.open(path, "r")
  if not f then
    log("No saved state found for key '" .. self:getKey() .. "' (" .. tostring(path) .. ")")
    return false
  end
  local data = f:read("*a")
  f:close()
  local chunk, err = loadstring(data)
  if not chunk then
    log("Failed to parse state file: " .. tostring(err))
    return false
  end
  local ok, tbl = pcall(chunk)
  if not ok or type(tbl) ~= "table" then
    log("State file did not return a table")
    return false
  end
  -- Validate meta to ensure file belongs to this mission
  local expectKey = self:getKey()
  local expectFp = self:computeFingerprint()
  if tbl.meta then
    if tbl.meta.key ~= expectKey then
      log("State meta key mismatch (expected '" .. expectKey .. "', got '" .. tostring(tbl.meta.key) .. "'). Aborting load.")
      return false
    end
    if tbl.meta.fp ~= expectFp then
      log("State fingerprint mismatch (expected '" .. expectFp .. "', got '" .. tostring(tbl.meta.fp) .. "'). Aborting load.")
      return false
    end
  else
    log("State has no meta; proceeding with legacy load based on key only.")
  end
  self.state = tbl
  self.state.deadUnits = self.state.deadUnits or {}
  self.state.deadStatics = self.state.deadStatics or {}
  self.state.unitPos = self.state.unitPos or {}
  log("Loaded state from " .. path)
  return true
end

function Persistence:reset()
  self.state = { deadUnits = {}, deadStatics = {} }
  self:save(true)
  log("State reset and saved.")
end

-- Apply saved removals; retry a few times while mission spawns in
function Persistence:applyStateOnce()
  local removed = 0
  local attemptedUnits, foundUnits = 0, 0
  for name, _ in pairs(self.state.deadUnits or {}) do
    local u = Unit.getByName(name)
    attemptedUnits = attemptedUnits + 1
    if u and u:isExist() then
      foundUnits = foundUnits + 1
      u:destroy()
      removed = removed + 1
    end
  end
  local attemptedStatics, foundStatics = 0, 0
  for name, _ in pairs(self.state.deadStatics or {}) do
    local s = StaticObject.getByName(name)
    attemptedStatics = attemptedStatics + 1
    if s and s:isExist() then
      foundStatics = foundStatics + 1
      s:destroy()
      removed = removed + 1
    end
  end
  return removed, attemptedUnits, foundUnits, attemptedStatics, foundStatics
end

function Persistence:applyStateWithRetries(retries, interval)
  retries = retries or 30
  interval = interval or 5
  local attempt = 0
  local function tick()
    attempt = attempt + 1
    local removed = select(1, Persistence:applyStateOnce())
    if attempt < retries then
      timer.scheduleFunction(tick, {}, timer.getTime() + interval)
    end
    if removed > 0 then
      log("Applied state: removed " .. tostring(removed) .. " objects (attempt " .. tostring(attempt) .. ")")
    end
  end
  timer.scheduleFunction(tick, {}, timer.getTime() + 2)
end

-- Build index of mission templates to allow group respawn with updated positions
function Persistence:buildTemplateIndex()
  if self._templateIndexBuilt then return end
  if not env or not env.mission or not env.mission.coalition then return end
  local catMap = {
    plane = Group.Category.AIRPLANE,
    helicopter = Group.Category.HELICOPTER,
    vehicle = Group.Category.GROUND,
    ship = Group.Category.SHIP,
  }
  local coal = env.mission.coalition
  for _, sideKey in ipairs({"blue","red","neutral"}) do
    local side = coal[sideKey]
    if side and side.country then
      for _, country in pairs(side.country) do
        local cid = country.id
        for catKey, gc in pairs({plane=country.plane, helicopter=country.helicopter, vehicle=country.vehicle, ship=country.ship}) do
          if gc and gc.group then
            for _, g in pairs(gc.group) do
              if g and g.name and g.units then
                local hasClient = false
                for _, u in ipairs(g.units) do
                  if u.skill == "Client" or u.skill == "Player" then hasClient = true break end
                end
                self._groupTemplates[g.name] = { tpl = g, countryId = cid, categoryKey = catKey, hasClient = hasClient }
                for _, u in ipairs(g.units) do
                  if u.name then self._unitToGroup[u.name] = g.name end
                end
              end
            end
          end
        end
      end
    end
  end
  self._templateIndexBuilt = true
end

-- Capture alive units' last positions and headings
function Persistence:captureUnitPositions()
  local vol = { id = world.VolumeType.SPHERE, params = { point = {x = 0, y = 0, z = 0}, radius = 2e6 } }
  local saved = self.state.unitPos or {}
  world.searchObjects(Object.Category.UNIT, vol, function(u)
    if u and u.isExist and u:isExist() then
      local name = u.getName and u:getName()
      if name and name ~= "" and not self.state.deadUnits[name] then
        -- Skip player-occupied units (AI only)
        if u.getPlayerName and u:getPlayerName() then return true end
        local pos = u:getPosition()
        local p = pos.p or u:getPoint()
        local heading = 0
        if pos and pos.x then
          heading = math.atan2(pos.x.z or 0, pos.x.x or 1)
        end
        saved[name] = { x = p.x, y = p.y, z = p.z, heading = heading }
      end
    end
    return true
  end)
  self.state.unitPos = saved
end

-- Apply saved positions by respawning groups based on mission templates
function Persistence:applySavedPositions()
  self:buildTemplateIndex()
  local byGroup = {}
  for uname, pos in pairs(self.state.unitPos or {}) do
    if not self.state.deadUnits[uname] then
      local gname = self._unitToGroup[uname]
      if gname then
        byGroup[gname] = byGroup[gname] or {}
        byGroup[gname][uname] = pos
      end
    end
  end

  -- Build queued operations and process them with a small delay between each
  local ops = {}
  for gname, unitPos in pairs(byGroup) do
    local meta = self._groupTemplates[gname]
    if meta and meta.tpl and meta.countryId then
      local catKey = meta.categoryKey
      -- Skip groups with client/player slots when moving air categories
      if self.repositionCategories[catKey] and not (meta.hasClient and (catKey == 'plane' or catKey == 'helicopter')) then
        table.insert(ops, { gname = gname, unitPos = unitPos, meta = meta })
      end
    end
  end

  local idx = 0
  local function step()
    idx = idx + 1
    local op = ops[idx]
    if not op then return end

    local meta = op.meta
    local gname = op.gname
    local unitPos = op.unitPos

    local catKey = meta.categoryKey
    local catEnum = (catKey == 'plane' and Group.Category.AIRPLANE)
      or (catKey == 'helicopter' and Group.Category.HELICOPTER)
      or (catKey == 'vehicle' and Group.Category.GROUND)
      or (catKey == 'ship' and Group.Category.SHIP)
      or Group.Category.GROUND

    local newG = deepcopy(meta.tpl)
    local keepUnits = {}
    for i, u in ipairs(newG.units or {}) do
      local uName = u.name
      if not self.state.deadUnits[uName] then
        if unitPos[uName] then
          u.x = unitPos[uName].x
          u.y = unitPos[uName].z
          u.heading = unitPos[uName].heading or u.heading or 0
          if catKey == 'plane' or catKey == 'helicopter' then
            -- Set altitude when available for air units
            local alt = unitPos[uName].y
            if alt then
              u.alt = alt
              u.alt_type = u.alt_type or "BARO"
            end
          end
        end
        table.insert(keepUnits, u)
      end
    end
    newG.units = keepUnits

    if #newG.units > 0 then
      local existing = Group.getByName(gname)
      if existing and existing:isExist() then existing:destroy() end
      coalition.addGroup(meta.countryId, catEnum, newG)
      -- Optional: minimal logging to avoid overhead
      -- log("Respawned group '" .. gname .. "' (" .. tostring(#newG.units) .. ")")
    else
      local existing = Group.getByName(gname)
      if existing and existing:isExist() then existing:destroy() end
    end

    return timer.getTime() + (Persistence.spawnThrottleSeconds or 0.2)
  end

  if #ops > 0 then
    timer.scheduleFunction(function() return step() end, {}, timer.getTime() + 0.1)
  end
end

-- Bootstrap: load, announce, apply retries, start autosave
function Persistence:bootstrap()
  if self._bootstrapped then return end
  self._bootstrapped = true

  if not self:ioAvailable() then
    trigger.action.outText("Persistence disabled: enable lfs/io in Saved Games\\DCS...\\Scripts\\MissionScripting.lua (comment sanitizeModule for 'io' and 'lfs').", 20)
    return
  end

  local loaded = self:load()
  local du, ds = 0, 0
  for _ in pairs(self.state.deadUnits or {}) do du = du + 1 end
  for _ in pairs(self.state.deadStatics or {}) do ds = ds + 1 end
  trigger.action.outText(string.format("Persistence: loaded %d units, %d statics. Applying...", du, ds), 10)
  self:applyStateWithRetries(30, 5)

  -- After applying removals, respawn groups with saved positions
  timer.scheduleFunction(function()
    Persistence:applySavedPositions()
  end, {}, timer.getTime() + 6)

  if self.autosaveSeconds and self.autosaveSeconds > 0 and not self._autosaveStarted then
    self._autosaveStarted = true
    local function loop()
      self:save(true)
      return timer.getTime() + self.autosaveSeconds
    end
    timer.scheduleFunction(function() return loop() end, {}, timer.getTime() + self.autosaveSeconds)
  end
end

-- Event handler to record losses and handle start
Persistence._handler = {}
function Persistence._handler:onEvent(event)
  if not event or not event.id then return end

  if event.id == world.event.S_EVENT_MISSION_START then
    -- Load and apply saved state soon after start
    Persistence:bootstrap()
    return
  end

  if event.id == world.event.S_EVENT_DEAD or event.id == world.event.S_EVENT_CRASH then
    local obj = event.target or event.initiator
    if not obj or not obj.getCategory then return end

    -- Skip client/player losses if configured
    if not Persistence.trackClientLosses and obj.getPlayerName and obj:getPlayerName() then
      return
    end

    local cat = obj:getCategory()
    local name = obj.getName and obj:getName() or nil
    if not name or name == "" then return end

    if cat == Object.Category.UNIT then
      Persistence.state.deadUnits[name] = true
      Persistence:save() -- debounced
    elseif cat == Object.Category.STATIC then
      Persistence.state.deadStatics[name] = true
      Persistence:save() -- debounced
    end
  end
end

-- Register handler
world.addEventHandler(Persistence._handler)

-- F10 radio menu for manual control
do
  local root = missionCommands.addSubMenu("Persistence")
  missionCommands.addCommand("Save now", root, function()
    if not Persistence:ioAvailable() then
      trigger.action.outText("Persistence disabled: enable lfs/io in MissionScripting.lua", 10)
      return
    end
    Persistence:save(true)
  end)
  missionCommands.addCommand("Show file name", root, function()
    local p = Persistence:getStatePath() or "state.lua"
    trigger.action.outText("Persistence file: " .. p, 10)
  end)
end

if Persistence:ioAvailable() then
  log("Initialized. Saving to: " .. Persistence:getStatePath())
else
  log("Initialized with persistence DISABLED (no lfs/io).")
end

-- Run bootstrap shortly after script load as a fallback
timer.scheduleFunction(function() Persistence:bootstrap() end, {}, timer.getTime() + 1)
