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

  -- Track client/player losses too? (false keeps client slots fresh)
  trackClientLosses = false,

  -- Internal state container
  state = {
    deadUnits = {},
    deadStatics = {},
  },

  _saveDebounce = false,
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

  local path = self:getStatePath()
  if not path then return false end
  local f, err = io.open(path, "w")
  if not f then
    log("Failed to open state for write: " .. tostring(err))
    return false
  end
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
    log("No saved state found for key '" .. self:getKey() .. "'")
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
  self.state = tbl
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
  for name, _ in pairs(self.state.deadUnits or {}) do
    local u = Unit.getByName(name)
    if u and u:isExist() then
      u:destroy()
      removed = removed + 1
    end
  end
  for name, _ in pairs(self.state.deadStatics or {}) do
    local s = StaticObject.getByName(name)
    if s and s:isExist() then
      s:destroy()
      removed = removed + 1
    end
  end
  return removed
end

function Persistence:applyStateWithRetries(retries, interval)
  retries = retries or 30
  interval = interval or 5
  local attempt = 0
  local function tick()
    attempt = attempt + 1
    local removed = Persistence:applyStateOnce()
    if attempt < retries then
      timer.scheduleFunction(tick, {}, timer.getTime() + interval)
    end
    if removed > 0 then
      log("Applied state: removed " .. tostring(removed) .. " objects (attempt " .. tostring(attempt) .. ")")
    end
  end
  timer.scheduleFunction(tick, {}, timer.getTime() + 2)
end

-- Event handler to record losses and handle start
Persistence._handler = {}
function Persistence._handler:onEvent(event)
  if not event or not event.id then return end

  if event.id == world.event.S_EVENT_MISSION_START then
    -- Load and apply saved state soon after start
    if Persistence:ioAvailable() then
      Persistence:load()
      Persistence:applyStateWithRetries(30, 5)
    else
      trigger.action.outText("Persistence disabled: enable lfs/io in Saved Games\\DCS...\\Scripts\\MissionScripting.lua (comment sanitizeModule for 'io' and 'lfs').", 20)
    end

    -- Start autosave loop
    if Persistence.autosaveSeconds and Persistence.autosaveSeconds > 0 and Persistence:ioAvailable() then
      local function loop()
        Persistence:save(true)
        return timer.getTime() + Persistence.autosaveSeconds
      end
      timer.scheduleFunction(function() return loop() end, {}, timer.getTime() + Persistence.autosaveSeconds)
    end
    return
  end

  if event.id == world.event.S_EVENT_DEAD then
    local obj = event.initiator
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
  missionCommands.addCommand("Reset state (wipe)", root, function()
    if not Persistence:ioAvailable() then
      trigger.action.outText("Persistence disabled: enable lfs/io in MissionScripting.lua", 10)
      return
    end
    Persistence:reset()
  end)
  missionCommands.addCommand("Show key", root, function() trigger.action.outText("Persistence key: " .. Persistence:getKey(), 10) end)
end

if Persistence:ioAvailable() then
  log("Initialized. Saving to: " .. Persistence:getStatePath())
else
  log("Initialized with persistence DISABLED (no lfs/io).")
end
