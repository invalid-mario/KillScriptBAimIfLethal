---@type Agent
local LocalAgent
local lastSeeTargetTime = -10000.0
local HalfFov = 1.0
local HalfFovCos = -1.0
---@type Item
local CurrentItem
local IgnoreLastSeeTargetTimer = false
local DEG2RAD = math.pi / 180.0

local EReflexAimMode = {
 None = 1,
 OnlyHead = 2,
 Head = 4,
 Body = 8,
 HeadOrLethal = 16,
}

local NetworkState = {
 PenetrationThresholdPercent = 50,
 SuccessfulHitsThreshold = 5,
 AimMode = EReflexAimMode.Head,
 IsFocusing = false,
}

Network:OnTableReceived(function(table)
 NetworkState = table
end)

local function now_time()
 return Time.Seconds
end

local function IsAgentAlive(agent)
 return agent and agent.Health and agent.Health.IsAlive == true
end

---
---@param target Agent
---@return number
local function GetAimDot(target, A, firePos)
 local tgtA = target.Aim
 if not (A and tgtA) then return -1.0 end
 local toTgt = (tgtA.Position - firePos).normalized
 return A.Direction:Dot(toTgt)
end

---
---@param hitbox Hitbox
---@param firearm FirearmItem
---@param penetrationThresholdPercent integer
---@param firePos Vector3
---@param targetOwnerId integer
---@return boolean
local function TrySinglePointHitFirearm(hitbox, firearm, penetrationThresholdPercent, firePos, targetOwnerId)
 local dir = (hitbox.Position - firePos).normalized
 local hits = firearm:HitscanFirearm(firePos, dir)
 local hl = hits.Length
 for i = 1, hl do
  local h = hits[i]
  local hb = h and h.Hitbox
  if hb and hb.Agent and hb.Agent.ID == targetOwnerId and h.EntryPower * 100 >= penetrationThresholdPercent then
   return true
  end
 end
 return false
end

---
---@param hitbox Hitbox
---@param raycastPos Vector3
---@return Vector3[]
local function GetHitboxPointsByRaycast(hitbox, raycastPos)
 if not hitbox.IsVisible then
  return {}
 end

 local center = hitbox.Position

 if hitbox.IsSphere then
  local forward = center - raycastPos
  if forward.sqrMagnitude <= 0.000001 then
   return { center }
  end

  forward = forward.normalized

  local right = forward:Cross(Vector3.up)
  if right.sqrMagnitude <= 0.000001 then
   right = forward:Cross(Vector3.forward)
  end

  right = right.normalized
  local up = right:Cross(forward).normalized

  local radius = hitbox.Radius
  if radius <= 0 then
   return {}
  end

  radius = radius * 0.95
  local halfRadius = radius * 0.5

  return {
   center,
   center - right * radius,
   center - right * halfRadius,
   center + right * halfRadius,
   center + right * radius,
   center + up * radius,
   center + up * halfRadius,
   center - up * halfRadius,
   center - up * radius,
  }
 end

 local rotation = hitbox.Rotation
 local smallSize = hitbox.Size * 0.475
 local xs = { -smallSize.x, 0, smallSize.x }
 local ys = { -smallSize.y, 0, smallSize.y }
 local points = {}

 for i = 1, #xs do
  for j = 1, #ys do
   local localPoint = Vector3.new(xs[i], ys[j], 0)
   local worldPoint = center + rotation * localPoint
   points[#points + 1] = worldPoint
  end
 end

 return points
end

---
---@param hitbox Hitbox
---@param firearm FirearmItem
---@param penetrationThresholdPercent integer
---@param firePos Vector3
---@param targetOwnerId integer
---@return boolean
---@return Vector3 | nil
local function TryMultiPointHitFirearm(hitbox, firearm, penetrationThresholdPercent, firePos, targetOwnerId)
 local acc = Vector3.zero
 local cnt = 0
 local pointsOnHitbox = GetHitboxPointsByRaycast(hitbox, firePos)

 for i = 1, #pointsOnHitbox do
  local p = pointsOnHitbox[i]
  local dir = (p - firePos).normalized
  local hits = firearm:HitscanFirearm(firePos, dir)
  local hl = hits.Length
  for j = 1, hl do
   local h = hits[j]
   local hb = h and h.Hitbox
   if hb and hb.Agent and hb.Agent.ID == targetOwnerId and h.EntryPower * 100 >= penetrationThresholdPercent then
    acc = acc + p
    cnt = cnt + 1
    break
   end
  end
 end

 if cnt == 0 then return false, nil end
 return true, (acc / cnt)
end

---
---@param hb Hitbox
---@param firearm FirearmItem
---@param firePos Vector3
---@param entryPoint Vector3
---@return boolean
local function IsHitLethal(hb, firearm, firePos, entryPoint)
 if not hb or not hb.Agent or not hb.Agent.Health or not firearm or not firearm.Config then return false end

 local target = hb.Agent
 local currentHealth = target.Health.CurrentHealthPrecise
 if currentHealth == nil then currentHealth = target.Health.CurrentHealth end
 if currentHealth == nil then return false end

 local config = firearm.Config
 local distance = (entryPoint - firePos).magnitude
 
 local baseDamage = config.Damage
 local distantDamage = config.DamageDistant
 local falloffBegin = config.DamageFalloffBegin
 local falloffEnd = config.DamageFalloffEnd
 
 local damage = baseDamage
 if falloffEnd and falloffBegin and falloffEnd > falloffBegin then
  if distance >= falloffEnd then
   damage = distantDamage
  elseif distance > falloffBegin then
   local t = (distance - falloffBegin) / (falloffEnd - falloffBegin)
   damage = baseDamage + (distantDamage - baseDamage) * t
  end
 end
 
 local multiplier = 1.0
 if hb.BodyPart == EHitboxBodyPart.Head and config.HeadDamageFactor then
  multiplier = config.HeadDamageFactor
 elseif hb.BodyPart == EHitboxBodyPart.Leg and config.LegsDamageFactor then
  multiplier = config.LegsDamageFactor
 end
 
 return (damage * multiplier) >= currentHealth
end

---
---@param target Agent
---@param mode integer
---@param firearm FirearmItem
---@param penetrationThresholdPercent integer
---@param firePos Vector3
---@return Hitbox | nil
---@return Vector3 | nil
local function FindTargetHitboxAndAimPositionFirearm(target, mode, firearm, penetrationThresholdPercent, firePos)
 local list = target:GetHitboxes()
 local len = list.Length
 if len == 0 then return nil, nil end
 local targetOwnerId = target.ID

 local function CheckHitbox(hb)
  if not hb then return false, nil end
  if CpuLimit.RemainingCpuTime >= 0.45 then
   local ok, mp = TryMultiPointHitFirearm(hb, firearm, penetrationThresholdPercent, firePos, targetOwnerId)
   if ok then return true, mp end
  else
   if TrySinglePointHitFirearm(hb, firearm, penetrationThresholdPercent, firePos, targetOwnerId) then
    return true, hb.Position
   end
  end
  return false, nil
 end

 -- НОВАЯ ЛОГИКА: Сначала проверяем тело
 local bodyHitbox = list[2]
 local bodyOk, bodyPos = CheckHitbox(bodyHitbox)
 
 if bodyOk then
  if mode == EReflexAimMode.HeadOrLethal then
   -- Если тело видно, проверяем его летальность
   if IsHitLethal(bodyHitbox, firearm, firePos, bodyPos) then
    -- Если выстрел летален, немедленно возвращаем тело как цель, игнорируя голову
    return bodyHitbox, bodyPos
   end
  elseif mode == EReflexAimMode.Body then
   return bodyHitbox, bodyPos
  end
 end

 -- Если тело не летально (или не видно), проверяем голову для всех режимов кроме Body
 if mode ~= EReflexAimMode.Body then
  local headHitbox = list[1]
  local headOk, headPos = CheckHitbox(headHitbox)
  if headOk then
   return headHitbox, headPos
  end
 end

 -- Fallback в зависимости от режима
 if mode == EReflexAimMode.OnlyHead or mode == EReflexAimMode.HeadOrLethal then
  return nil, nil
 end

 local length = len
 if mode == EReflexAimMode.Head then
  length = len - 4
 end

 for i = 3, length do
  local hb = list[i]
  if hb then
   local ok, pos = CheckHitbox(hb)
   if ok then return hb, pos end
  end
 end
 
 return nil, nil
end

---
---@param target Agent
---@param mode integer
---@param melee MeleeItem
---@param firePos Vector3
---@return Hitbox|nil
---@return Vector3|nil
local function FindTargetHitboxAndAimPositionMelee(target, mode, melee, firePos)
 local list = target:GetHitboxes()
 local len = list.Length
 if len == 0 then return nil, nil end
 local targetOwnerId = target.ID
 for i = 1, len do
  local candidateHitbox = list[i]
  local dir = (candidateHitbox.Position - firePos).normalized
  local hit = melee:HitscanMelee(firePos, dir, 5.0)
  local actualHitbox = hit and hit.Hitbox
  if actualHitbox and actualHitbox.Agent and actualHitbox.Agent.ID == targetOwnerId then
   return actualHitbox, hit.EntryPoint
  end
 end
 return nil, nil
end

local function FindTargetHitboxAndAimPosition(target, mode, item, firePos, penetrationThresholdPercent)
 if not item then return nil, nil end
 if item.IsFirearm then
  return FindTargetHitboxAndAimPositionFirearm(target, mode, item.AsFirearmItem, penetrationThresholdPercent,
 firePos)
 elseif item.IsMelee then
  return FindTargetHitboxAndAimPositionMelee(target, mode, item.AsMeleeItem, firePos)
 end
 return nil, nil
end

---
---@param aimMode integer
---@param successfulHitsThreshold integer
---@param penetrationThresholdPercent integer
---@param firearm FirearmItem
---@param myTeam Team
---@param firePos Vector3
---@return integer
local function GetSuccessfulHits(aimMode, successfulHitsThreshold, penetrationThresholdPercent, firearm, myTeam, firePos)
 if not firearm then return 0 end
 local wantHeadOnly = (aimMode == EReflexAimMode.OnlyHead)
 local wantLethalBody = (aimMode == EReflexAimMode.HeadOrLethal)
 local score = 0
 local projDirs = firearm:GetPredictedHits()
 local attempts = projDirs.Length

 for attempt = 1, attempts do
  local remainingAttempts = attempts - attempt + 1
  if score + remainingAttempts < successfulHitsThreshold then
   return score
  end

  local hits = projDirs[attempt]
  local hl = hits.Length
  for hitIndex = 1, hl do
   local h = hits[hitIndex]
   local hb = h and h.Hitbox
   if hb and h.EntryPower * 100 >= penetrationThresholdPercent then
    local victim = hb.Agent
    if IsAgentAlive(victim) and victim.IsVisible then
     if victim.Team == myTeam then
      score = score - 1
     else
      local isHead = (hb.BodyPart == EHitboxBodyPart.Head)
      local isLethal = false
      if not isHead and wantLethalBody then
       isLethal = IsHitLethal(hb, firearm, firePos, h.EntryPoint)
      end
      
      if (not wantHeadOnly and not wantLethalBody) or isHead or isLethal then
       score = score + 1
       if score >= successfulHitsThreshold then
        return score
       end
       break
      end
     end
    end
   end
  end
 end

 return score
end

---@type Agent | nil
local CurrentAimTarget

---
---@param mode integer
---@param item Item
---@param firePos Vector3
---@param penetrationThresholdPercent integer
---@return Hitbox | nil
local function UpdateAimTarget(mode, item, firePos, penetrationThresholdPercent)
 local A = LocalAgent.Aim

 local bestHitbox = nil
 ---@type Vector3
 local bestAimPos = nil
 local bestDot = HalfFovCos
 local currentTarget = A.Target
 local currentId = -1
 if currentTarget then
  currentId = currentTarget.ID
 end

 local defusing = LocalAgent.Interactor.IsDefusing

 if mode ~= EReflexAimMode.None and (not defusing) and (not NetworkState.IsFocusing) then
  local bestIsCurrent = false

  if CurrentAimTarget then
   if IsAgentAlive(CurrentAimTarget) and CurrentAimTarget.IsVisible then
    local c = GetAimDot(CurrentAimTarget, A, firePos)
    if c > HalfFovCos then
     local hb, pos = FindTargetHitboxAndAimPosition(CurrentAimTarget, mode, item, firePos,
 penetrationThresholdPercent)
     if hb and pos then
      bestIsCurrent = true
      bestDot = c
      bestHitbox = hb
      bestAimPos = pos
     end
    end
   end
  end

  if CpuLimit.RemainingCpuTime >= 0.7 then
   if not bestIsCurrent then
    local allEnemy = Agents:GetEnemies()
    local len = allEnemy.Length

    for i = 1, len do
     local agent = allEnemy[i]
     if IsAgentAlive(agent) and agent.IsVisible then
      local isCur = (agent.ID == currentId)
      local c = GetAimDot(agent, A, firePos)
      if c > HalfFovCos or isCur then
       local hb, pos = FindTargetHitboxAndAimPosition(agent, mode, item, firePos,
 penetrationThresholdPercent)
       if hb and pos then
        if isCur then
         bestHitbox = hb
         bestAimPos = pos
         break
        end
        if (isCur and not bestIsCurrent) or (isCur == bestIsCurrent and c > bestDot) then
         bestIsCurrent = isCur
         bestDot = c
         bestHitbox = hb
         bestAimPos = pos
        end
       end
      end
     end

     if CpuLimit.RemainingCpuTime <= 0.2 then
      break
     end
    end
   end
  end
 end

 if not bestHitbox then
  local tgtDead = currentTarget and (not IsAgentAlive(currentTarget)) or false
  if ((IgnoreLastSeeTargetTimer or ((lastSeeTargetTime + Config.LastSeeTargetTimer) < now_time())) and not AgentInput:IsButtonDown(EInputButton.Fire))
 or mode == EReflexAimMode.None or tgtDead or NetworkState.IsFocusing then
   LocalAgent.Aim:ResetAimTarget()
   CurrentAimTarget = nil
  end
  return nil
 else
  LocalAgent.Aim:SetAimTarget(bestAimPos, bestHitbox.Agent)
  lastSeeTargetTime = now_time()
  CurrentAimTarget = bestHitbox.Agent
  return bestHitbox
 end
end

local function UpdateReflexes()
 CurrentItem = LocalAgent.Inventory.CurrentItem
 if not CurrentItem or CurrentItem.IsBridgeCharge or CurrentItem.IsThrowable then
  LocalAgent.Aim:ResetAimTarget()
  CurrentAimTarget = nil
  return
 end

 local penetrationThresholdPercent = NetworkState.PenetrationThresholdPercent
 local A = LocalAgent.Aim
 local firePos = A.Position

 if CurrentItem.IsFirearm then
  local firearm = CurrentItem.AsFirearmItem
  local threshold = NetworkState.SuccessfulHitsThreshold
  if threshold > 0 and not firearm.IsReloading and firearm.ClipAmmo > 0 then
   local percent = GetSuccessfulHits(NetworkState.AimMode, threshold,
 penetrationThresholdPercent, firearm, LocalAgent.Team, firePos)
   if percent >= threshold then
    AgentInput:SetButtonState(EInputButton.Fire, true)
   end
  end
 end

 IgnoreLastSeeTargetTimer = CurrentItem.IsMelee

 UpdateAimTarget(NetworkState.AimMode, CurrentItem, firePos, penetrationThresholdPercent)
end

function Tick()
 LocalAgent = Agents:GetLocalAgent()
 if not LocalAgent then return end
 HalfFov = Config.AimFov * 0.5
 HalfFovCos = math.cos(HalfFov * DEG2RAD)
 UpdateReflexes()
end

print("[AIM]Module inited")

Scheduler:OnTick(Tick)