local MySprites = {
 FovSmall = nil,
 FovMiddle = nil,
 FovBig = nil,
 FovGiant = nil,
}

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

local HINT_NOTIFICATION_DURATION = 1.5

local ALL_AIM_MODE_MASK = EReflexAimMode.None | EReflexAimMode.OnlyHead | EReflexAimMode.Head | EReflexAimMode.Body | EReflexAimMode.HeadOrLethal

local AIMBOT_DOT_MODE_ORDER = {
 EReflexAimMode.OnlyHead,
 EReflexAimMode.Head,
 EReflexAimMode.Body,
 EReflexAimMode.HeadOrLethal,
}

local DefaultParamsForWeapons = {
 LightPistol = { Penetration = 50, Hits = 3, AimMode = EReflexAimMode.Head },
 MediumPistol = { Penetration = 50, Hits = 3, AimMode = EReflexAimMode.Head },
 Revolver = { Penetration = 50, Hits = 5, AimMode = EReflexAimMode.Head },
 Shotgun = { Penetration = 50, Hits = 3, AimMode = EReflexAimMode.Body },
 SMG = { Penetration = 50, Hits = 3, AimMode = EReflexAimMode.Head },
 LightRifle = { Penetration = 50, Hits = 5, AimMode = EReflexAimMode.Head },
 MediumRifle = { Penetration = 50, Hits = 5, AimMode = EReflexAimMode.Head },
 HeavyRifle = { Penetration = 50, Hits = 7, AimMode = EReflexAimMode.Head },
 SniperRifle = { Penetration = 50, Hits = 10, AimMode = EReflexAimMode.OnlyHead },
 MachineGun = { Penetration = 50, Hits = 3, AimMode = EReflexAimMode.Head },
}

---@type FirearmItem | nil
local CurrentFirearm = nil

---@type VisualElement
local AutoaimMask

---@type VisualElement
local AutoaimCircle

local viewportPos
local screenPosOffset

local function LoadSprites()
 MySprites.FovSmall = Textures:GetTexture("FovSmall.png")
 MySprites.FovMiddle = Textures:GetTexture("FovMiddle.png")
 MySprites.FovBig = Textures:GetTexture("FovBig.png")
 MySprites.FovGiant = Textures:GetTexture("FovGiant.png")
end

local function IsAgentAlive(agent)
 if not agent then
  return false
 end

 if DefusalGame then
  local agentStats = agent.Stats
  return agentStats and agentStats.IsAlive == true
 end

 return agent.Health and agent.Health.IsAlive == true
end

---
---@param mask integer bit mask (int)
---@param currentBit integer current bit (power of two, e.g. 1, 2, 4, ...)
---@param maxBits integer how many bits to check in total
---@return integer
function NextBit(mask, currentBit, maxBits)
 local bit = currentBit
 for i = 1, maxBits do
  bit = bit << 1
  if bit > (1 << (maxBits - 1)) then
   bit = 1
  end
  if (mask & bit) ~= 0 then
   return bit
  end
 end
 return currentBit
end

local function Clamp(value, min, max)
 if value < min then
  return min
 end
 if value > max then
  return max
 end
 return value
end

local UiRoot
local AimbotIcon
local ThresholdIcon
local AimbotDotView
local ThresholdDotView
local SwitchAimModeHotkey
local PenetrationUpHotkey
local PenetrationDownHotkey

local function HasAimMode(mask, aimMode)
 return mask ~= nil and (mask & aimMode) ~= 0
end

local function GetAimbotDotState(aimModeMask, aimMode)
 local combatModeCount = 0
 local activeDotValue = -1

 for _, mode in ipairs(AIMBOT_DOT_MODE_ORDER) do
  if HasAimMode(aimModeMask, mode) then
   if mode == aimMode then
    activeDotValue = combatModeCount
   end
   combatModeCount = combatModeCount + 1
  end
 end

 local totalSelectableModeCount = combatModeCount

 if HasAimMode(aimModeMask, EReflexAimMode.None) then
  totalSelectableModeCount = totalSelectableModeCount + 1
 end

 local shouldShowDots = combatModeCount > 0 and totalSelectableModeCount > 1

 if not shouldShowDots or aimMode == EReflexAimMode.None then
  activeDotValue = -1
 end

 return shouldShowDots, combatModeCount, activeDotValue
end

local function UpdateAimbotIcon(aimMode)
 if not AimbotIcon or aimMode == nil then return end

 local classMap = {
  [EReflexAimMode.None] = "icons__aimbot-none",
  [EReflexAimMode.OnlyHead] = "icons__aimbot-only-head",
  [EReflexAimMode.Head] = "icons__aimbot-head-prefer",
  [EReflexAimMode.Body] = "icons__aimbot-only-body",
  [EReflexAimMode.HeadOrLethal] = "icons__aimbot-head-or-lethal"
 }

 local enabledClass = classMap[aimMode] or "icons__aimbot-none"

 for _, class in pairs(classMap) do
  AimbotIcon:EnableInClassList(class, class == enabledClass)
 end

 if AimbotDotView then
  local aimModeMask = Config and Config.AimModeMask or ALL_AIM_MODE_MASK
  local shouldShowDots, dotCount, dotValue = GetAimbotDotState(aimModeMask, aimMode)
  AimbotDotView.style.display = shouldShowDots and DisplayStyle.Flex or DisplayStyle.None

  if AimbotDotView.count ~= dotCount then
   AimbotDotView.count = dotCount
  end
  AimbotDotView.value = dotValue
 end
end

local function UpdateReflexControlsVisibility(hasFirearm)
 local displayStyle = hasFirearm and DisplayStyle.Flex or DisplayStyle.None

 if SwitchAimModeHotkey then
  SwitchAimModeHotkey.style.display = displayStyle
 end

 if PenetrationUpHotkey then
  PenetrationUpHotkey.style.display = displayStyle
 end

 if PenetrationDownHotkey then
  PenetrationDownHotkey.style.display = displayStyle
 end

 if ThresholdDotView then
  ThresholdDotView.style.display = displayStyle
 end

 if not hasFirearm then
  if AimbotDotView then
   AimbotDotView.style.display = DisplayStyle.None
  end
  if ThresholdDotView then
   ThresholdDotView.style.display = DisplayStyle.None
  end
 end
end

local function UpdateThresholdIcon(threshold)
 if not ThresholdIcon or threshold == nil then return end

 local thresholdPercent = threshold * 10

 local classMap = {
  [0] = "icons__threshold-none",
  [10] = "icons__threshold-10",
  [20] = "icons__threshold-20",
  [30] = "icons__threshold-30",
  [40] = "icons__threshold-40",
  [50] = "icons__threshold-50",
  [60] = "icons__threshold-60",
  [70] = "icons__threshold-70",
  [80] = "icons__threshold-80",
  [90] = "icons__threshold-90",
  [100] = "icons__threshold-100",
 }

 local classToEnable = classMap[thresholdPercent] or "icons__threshold-none"

 for _, class in pairs(classMap) do
  ThresholdIcon:EnableInClassList(class, class == classToEnable)
 end

 if ThresholdDotView then
  if threshold == 0 then
   ThresholdDotView.value = -1
  else
   ThresholdDotView.value = threshold - 1
  end
 end
end

---
---@param bit integer
---@return string
local function GetAimModeStr(bit)
 for key, value in pairs(EReflexAimMode) do
  if value == bit then
   return tostring(key)
  end
 end
 return 'E'
end

local function FormatThresholdNotification(prefix, valuePercent, suffix)
 return prefix .. " > " .. tostring(valuePercent) .. "%" .. suffix
end

local function SendReflexHintNotification(message)
 NotificationController:ShowHint(message, HINT_NOTIFICATION_DURATION)
end

local function UpdateAutoaim(sizeX, sizeY)
 local w = math.max(1, sizeX)
 local h = math.max(1, sizeY)

 AutoaimCircle.visible = true

 if w >= 1750 then
  AutoaimCircle.style.backgroundImage = MySprites.FovGiant
 elseif w >= 1200 then
  AutoaimCircle.style.backgroundImage = MySprites.FovBig
 elseif w >= 600 then
  AutoaimCircle.style.backgroundImage = MySprites.FovMiddle
 else
  AutoaimCircle.style.backgroundImage = MySprites.FovSmall
 end

 AutoaimCircle.style.width = w
 AutoaimCircle.style.height = h
 AutoaimCircle.style.left = screenPosOffset.x - (w * 0.5)
 AutoaimCircle.style.top = screenPosOffset.y - (h * 0.5)
end

local function DrawAimFovCircle()
 if viewportPos.z < 0 then return end

 local aimFovDeg = Config.AimFov
 if not aimFovDeg or aimFovDeg <= 0 then return end

 local vfovDeg = Cameras.Main and Cameras.Main.Fov
 if not vfovDeg or vfovDeg <= 0 then return end

 local aimRad = math.rad(aimFovDeg * 0.5)
 local vfovHalfRad = math.rad(vfovDeg * 0.5)

 local tanAim = math.tan(aimRad)
 local tanVHalf = math.tan(vfovHalfRad)

 if tanVHalf == 0 then return end

 local aspect = Cameras.Main.Aspect or (Screen.Width / Screen.Height)
 local hfovHalfRad = math.atan(tanVHalf * aspect)
 local tanHHalf = math.tan(hfovHalfRad)

 local pxRadiusY_fullscreen = (tanAim / tanVHalf) * (Screen.Height * 0.5)
 local pxRadiusX_fullscreen = (tanAim / tanHHalf) * (Screen.Width * 0.5)

 if pxRadiusX_fullscreen < 1 and pxRadiusY_fullscreen < 1 then return end

 local maskW = AutoaimMask and AutoaimMask.width or Screen.Width
 local maskH = AutoaimMask and AutoaimMask.height or Screen.Height

 local scaleX = maskW / Screen.Width
 local scaleY = maskH / Screen.Height

 local pxRadiusX_mask = pxRadiusX_fullscreen * scaleX
 local pxRadiusY_mask = pxRadiusY_fullscreen * scaleY

 local drawW = pxRadiusX_mask * 2
 local drawH = pxRadiusY_mask * 2

 UpdateAutoaim(drawW, drawH)
end

---@type InputAction
local PenetrationHoldAction
---@type InputAction
local PenetrationUpAction
---@type InputAction
local PenetrationDownAction
---@type InputAction
local FocusAction

local needSave = false

local function AdjustThreshold(addValue)
 if addValue == 0 or not CurrentFirearm or UI.IsConsoleVisible or not IsAgentAlive(LocalAgent) then
  return
 end

 if PenetrationHoldAction:IsPressed() then
  local newValue = math.floor(NetworkState.PenetrationThresholdPercent + (addValue * 10))
  newValue = Clamp(newValue, 1, 100)

  if NetworkState.PenetrationThresholdPercent ~= newValue then
   NetworkState.PenetrationThresholdPercent = newValue
   needSave = true
  end

  SendReflexHintNotification(
   FormatThresholdNotification(Localization:GetTranslation('ShootPenetration'), newValue, ""))
 else
  local newValue = math.floor(NetworkState.SuccessfulHitsThreshold + addValue)
  newValue = Clamp(newValue, 0, 10)

  if NetworkState.SuccessfulHitsThreshold ~= newValue then
   NetworkState.SuccessfulHitsThreshold = newValue
   needSave = true
   UpdateThresholdIcon(newValue)
  end

  if newValue == 0 then
   SendReflexHintNotification(
    Localization:GetTranslation('TriggerbotDisabled'))
  else
   SendReflexHintNotification(
    FormatThresholdNotification(
     Localization:GetTranslation('ShootHit'),
     newValue * 10,
     Localization:GetTranslation('ShootHitSuffix')))
  end
 end
end

local function TrySaveNewConfigForWeapon()
 if not CurrentFirearm or UI.IsConsoleVisible or not LocalAgent then
  return
 end

 local name = string.gsub(CurrentFirearm.Name, "", "")

 if not Storage.Weapons then
  Storage.Weapons = {}
 end

 Storage.Weapons[name] = {
  Penetration = NetworkState.PenetrationThresholdPercent,
  Hits = NetworkState.SuccessfulHitsThreshold,
  AimMode = NetworkState.AimMode
 }

 if not Config.AutoSaveConfig then
  SendReflexHintNotification("Settings saved for " .. name)
 end
end

local function SwitchAimMode()
 if not CurrentFirearm or UI.IsConsoleVisible or not LocalAgent then
  return
 end

 local bit = NextBit(Config.AimModeMask, NetworkState.AimMode, 16)

 if bit ~= NetworkState.AimMode then
  NetworkState.AimMode = bit
  needSave = true
  UpdateAimbotIcon(bit)
 end

 SendReflexHintNotification(Localization:GetTranslation('AimMode') .. " " .. GetAimModeStr(bit))
end

local function CheckFocusing()
 if not FocusAction or UI.IsConsoleVisible or not IsAgentAlive(LocalAgent) then
  return
 end

 local turn = FocusAction:IsPressed()
 if NetworkState.IsFocusing ~= turn then
  NetworkState.IsFocusing = turn
  needSave = true
 end
end

local function UpdateAimSettings()
 CheckFocusing()

 if needSave then
  if Config.AutoSaveConfig then
   TrySaveNewConfigForWeapon()
  end
  needSave = false
  Network:SendTable(NetworkState)
 end
end

local function CheckFirearmChanged()
 local currentItem = LocalAgent.Inventory.CurrentItem
 local newItemIsFirearm = currentItem and currentItem.IsFirearm

 if CurrentFirearm and not newItemIsFirearm then
  CurrentFirearm = nil
  return true
 end

 if newItemIsFirearm then
  if CurrentFirearm then
   if currentItem.Name ~= CurrentFirearm.Name then
    CurrentFirearm = currentItem.AsFirearmItem
    return true
   end
  else
   CurrentFirearm = currentItem.AsFirearmItem
   return true
  end
 end

 return false
end

local function TryLoadNewConfigForWeapon()
 if not CurrentFirearm then
  return
 end

 local name = string.gsub(CurrentFirearm.Name, "", "")

 if Storage.Weapons and Storage.Weapons[name] then
  NetworkState.PenetrationThresholdPercent = Storage.Weapons[name].Penetration
  NetworkState.SuccessfulHitsThreshold = Storage.Weapons[name].Hits
  NetworkState.AimMode = Storage.Weapons[name].AimMode
 else
  if DefaultParamsForWeapons[name] then
   NetworkState.PenetrationThresholdPercent = DefaultParamsForWeapons[name].Penetration
   NetworkState.SuccessfulHitsThreshold = DefaultParamsForWeapons[name].Hits
   NetworkState.AimMode = DefaultParamsForWeapons[name].AimMode
  else
   NetworkState.PenetrationThresholdPercent = 50
   NetworkState.SuccessfulHitsThreshold = 5
   NetworkState.AimMode = EReflexAimMode.Head
  end
 end

 Network:SendTable(NetworkState)
end

local function SetUiVisible(visible)
 AutoaimMask.visible = visible

 if not UiRoot then return end

 local rootElement = UI:Q(UiRoot, "Root")
 if rootElement then
  rootElement.visible = visible
 end
end

local function IsSpectatorPov(localAgent)
 local observedAgent = Agents:GetLocalOrSpectatedAgent()

 if not observedAgent then
  return false
 end

 if not localAgent then
  return true
 end

 return observedAgent.ID ~= localAgent.ID
end

function Tick()
 LocalAgent = Agents:GetLocalAgent()

 if not LocalAgent then
  SetUiVisible(false)
  return
 end

 viewportPos = LocalAgent.Aim.DirectionViewportPoint
 screenPosOffset = UI:ViewportToUiPoint(viewportPos)

 if CheckFirearmChanged() then
  TryLoadNewConfigForWeapon()
 end

 if not LocalAgent.IsSpectated then
  UpdateAimSettings()
 end

 if IsAgentAlive(LocalAgent) and
  CurrentFirearm and
  (not DefusalGame or not DefusalGame.IsTeamSwapping) then
  DrawAimFovCircle()
 else
  AutoaimCircle.visible = false
 end

 if NetworkState and CurrentFirearm ~= nil and IsAgentAlive(LocalAgent) then
  if NetworkState.AimMode then
   UpdateAimbotIcon(NetworkState.AimMode)
  else
   UpdateAimbotIcon(EReflexAimMode.None)
  end

  if NetworkState.SuccessfulHitsThreshold then
   UpdateThresholdIcon(NetworkState.SuccessfulHitsThreshold)
  else
   UpdateThresholdIcon(0)
  end
 else
  UpdateAimbotIcon(EReflexAimMode.None)
  UpdateThresholdIcon(0)
 end

 UpdateReflexControlsVisibility(CurrentFirearm ~= nil)

 local shouldUiShow = IsAgentAlive(LocalAgent) and
  (not DefusalGame or not DefusalGame.IsTeamSwapping) and
  not LocalAgent.IsSpectated and
  not IsSpectatorPov(LocalAgent)

 SetUiVisible(shouldUiShow)
end

LoadSprites()

UiRoot = UI:BuildFromUxml("reflex.uxml", "reflex", "Reflex", "bottom-middle", "0px", "28px")

-- Layout-editor visibility setting: aim-assist UI is your own in-match POV only.
UI:SetWindowVisibilityTypes(UiRoot, { WindowVisibilityType.Match })

AutoaimMask = UI:BuildFromUxmlAbsolute("aimfov.uxml")
AutoaimCircle = AutoaimMask:GetChild("AutoaimCircle")

local rootElement = UI:Q(UiRoot, "Root")

if rootElement then
 local aimbotItem = UI:Q(rootElement, "AimbotItem")
 if aimbotItem then
  AimbotIcon = UI:Q(aimbotItem, "AimbotIcon")
  AimbotDotView = UI:Q(aimbotItem, "AimbotDotView")
  SwitchAimModeHotkey = UI:Q(aimbotItem, "SwitchAimModeHotkey")
 end

 local thresholdItem = UI:Q(rootElement, "ThresholdItem")
 if thresholdItem then
  ThresholdIcon = UI:Q(thresholdItem, "ThresholdIcon")
  ThresholdDotView = UI:Q(thresholdItem, "ThresholdDotView")
  PenetrationUpHotkey = UI:Q(thresholdItem, "PenetrationUpHotkey")
  PenetrationDownHotkey = UI:Q(thresholdItem, "PenetrationDownHotkey")
 end
end

if AimbotDotView then
 AimbotDotView.count = 0
 AimbotDotView.style.display = DisplayStyle.None
 AimbotDotView:Reset()
end

if ThresholdDotView then
 ThresholdDotView.count = 10
 ThresholdDotView.fillToValue = true
 ThresholdDotView:Reset()
end

UpdateReflexControlsVisibility(false)

local SwitchAimModeAction = InputActions:FindAction('SwitchAimMode')
SwitchAimModeAction:OnPerformed(SwitchAimMode)

local SaveNewConfigAction = InputActions:FindAction('SaveNewConfig')
SaveNewConfigAction:OnPerformed(TrySaveNewConfigForWeapon)

PenetrationHoldAction = InputActions:FindAction('PenetrationHold')
PenetrationUpAction = InputActions:FindAction('PenetrationUp')
PenetrationDownAction = InputActions:FindAction('PenetrationDown')

PenetrationUpAction:OnPerformed(function() AdjustThreshold(1) end)
PenetrationDownAction:OnPerformed(function() AdjustThreshold(-1) end)

FocusAction = InputActions:FindAction('Focus')

print("[AIM] HUD module inited!")

Scheduler:OnFrame(Tick)