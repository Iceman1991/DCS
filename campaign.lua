-- Campaign utilities for dynamic missions in DCS
-- Feature: spawn a transport aircraft at map edge and land at Kobuleti (Caucasus)

Campaign = Campaign or {}

local function log(msg)
  if env and env.info then env.info("[Campaign] " .. tostring(msg)) end
end

local function out(msg, t)
  if trigger and trigger.action and trigger.action.outText then
    trigger.action.outText("[Campaign] " .. msg, t or 10)
  end
end

local function uniqueGroupName(base)
  local idx = 1
  local name = base
  while Group.getByName(name) do
    idx = idx + 1
    name = string.format("%s_%02d", base, idx)
  end
  return name
end

-- Spawn a C-130 to fly to Kobuleti and land
function Campaign.spawnTransportToKobuleti()
  local theatre = env and env.mission and env.mission.theatre or "unknown"
  if theatre ~= "Caucasus" then
    out("Theatre is '" .. tostring(theatre) .. "' (expected 'Caucasus'). Aborting spawn.", 12)
    return
  end

  local ab = Airbase.getByName("Kobuleti")
  if not ab then
    out("Airbase 'Kobuleti' not found.", 10)
    return
  end
  local abId = ab:getID()
  local p = ab:getPosition().p -- {x, y, z}

  local cruiseAltFt = 22000
  local startAlt = math.floor(cruiseAltFt * 0.3048 + 0.5) -- meters MSL (~22,000 ft)
  local cruiseSpd = 220 -- m/s ~ 427 kts GS

  -- Start ~120 km west of Kobuleti, same latitude
  local startX = p.x - 120000
  local startZ = p.z

  local wp1 = {
    x = startX, y = startZ, alt = startAlt,
    alt_type = "BARO", speed = cruiseSpd, speed_locked = true,
    type = "Turning Point", action = "Turning Point",
    task = { id = "ComboTask", params = { tasks = {} } },
  }

  -- Approach point ~8 km west of the field, lower altitude
  local wp2 = {
    x = p.x - 8000, y = p.z, alt = startAlt,
    alt_type = "BARO", speed = 180, speed_locked = true,
    type = "Turning Point", action = "Turning Point",
    task = { id = "ComboTask", params = { tasks = {} } },
  }

  local wp3 = {
    x = p.x, y = p.z, alt = 0,
    alt_type = "BARO", speed = 70, speed_locked = true,
    type = "Land", action = "Landing", airdromeId = abId,
    task = { id = "ComboTask", params = { tasks = {} } },
  }

  local grpName = uniqueGroupName("CMP_TRNSP_KOBULETI")
  local unitName = grpName .. "-1"

  local group = {
    visible = false,
    task = "Transport",
    uncontrolled = false,
    route = { points = { wp1, wp2, wp3 } },
    units = {
      [1] = {
        name = unitName,
        type = "C-130",
        skill = "High",
        x = startX,
        y = startZ,
        alt = startAlt,
        alt_type = "BARO",
        speed = cruiseSpd,
        heading = 0,
        payload = {},
      }
    },
    name = grpName,
    x = startX,
    y = startZ,
  }

  local ok, err = pcall(function()
    coalition.addGroup(country.id.USA, Group.Category.AIRPLANE, group)
  end)
  if not ok then
    out("Failed to spawn transport: " .. tostring(err), 12)
    return
  end
  -- Apply ROE: Weapons Hold (never attack)
  pcall(function()
    if AI and AI.Option and AI.Option.Air then
      local g = Group.getByName(grpName)
      if g then
        local ctrl = g:getController()
        if ctrl then
          ctrl:setOption(AI.Option.Air.id.ROE, AI.Option.Air.val.ROE.WEAPON_HOLD)
        end
      end
    end
  end)
  out("Spawned transport '" .. grpName .. "' to land at Kobuleti.", 10)
end

-- Optional F10 menu to trigger the spawn
do
  if missionCommands and type(missionCommands.addSubMenu) == "function" then
    local root = missionCommands.addSubMenu("Campaign")
    missionCommands.addCommand("Spawn transport to Kobuleti", root, function()
      Campaign.spawnTransportToKobuleti()
    end)
  end
end
