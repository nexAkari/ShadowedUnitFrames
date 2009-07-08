
local Units = {unitFrames = {}, loadedUnits = {}}
local vehicleMonitor = CreateFrame("Frame", nil, nil, "SecureHandlerBaseTemplate")
local unitFrames, loadedUnits, unitEvents, queuedCombat = Units.unitFrames, Units.loadedUnits, {}, {}
local FRAME_LEVEL_MAX = 5
local _G = getfenv(0)

ShadowUF.Units = Units
ShadowUF:RegisterModule(Units, "units")

-- Frame shown, do a full update
local function FullUpdate(self)
	for i=1, #(self.fullUpdates), 2 do
		local handler = self.fullUpdates[i]
		handler[self.fullUpdates[i + 1]](handler, self)
	end
end

-- Register an event that should always call the frame
local function RegisterNormalEvent(self, event, handler, func)
	-- Make sure the handler/func exists
	if( not handler[func] ) then
		error(string.format("Invalid handler/function passed for %s on event %s, the function %s does not exist.", self:GetName() or tostring(self), event, func), 3)
		return
	end

	self:RegisterEvent(event)
	self.registeredEvents[event] = self.registeredEvents[event] or {}
	
	-- Each handler can only register an event once per a frame.
	if( self.registeredEvents[event][handler] ) then
		return
	end
			
	self.registeredEvents[event][handler] = func
end

-- Unregister an event
local function UnregisterEvent(self, event, handler)
	if( self and self.registeredEvents[handler] ) then
		self.registeredEvents[event][handler] = nil
	end
end

-- Register an event thats only called if it's for the actual unit
local function RegisterUnitEvent(self, event, handler, func)
	unitEvents[event] = true
	RegisterNormalEvent(self, event, handler, func)
end

-- Register a function to be called in an OnUpdate if it's an invalid unit (targettarget/etc)
local function RegisterUpdateFunc(self, handler, func)
	if( not handler[func] ) then
		error(string.format("Invalid handler/function passed to RegisterUpdateFunc for %s, the function %s does not exist.", self:GetName() or tostring(self), event, func), 3)
		return
	end

	for i=1, #(self.fullUpdates), 2 do
		local data = self.fullUpdates[i]
		if( data == handler and self.fullUpdates[i + 1] == func ) then
			return
		end
	end
	
	table.insert(self.fullUpdates, handler)
	table.insert(self.fullUpdates, func)
end

-- Used when something is disabled, removes all callbacks etc to it
local function UnregisterAll(self, handler)
	for i=#(self.fullUpdates), 1, -1 do
		if( self.fullUpdates[i] == handler ) then
			table.remove(self.fullUpdates, i + 1)
			table.remove(self.fullUpdates, i)
		end
	end

	for event, list in pairs(self.registeredEvents) do
		list[handler] = nil
		
		local totalEvents = 0
		for _ in pairs(list) do
			totalEvents = totalEvents + 1
		end
		
		if( totalEvents == 0 ) then
			self:UnregisterEvent(event)
		end
	end
end

-- Event handling
local function OnEvent(self, event, unit, ...)
	if( not unitEvents[event] or self.unit == unit ) then
		for handler, func in pairs(self.registeredEvents[event]) do
			handler[func](handler, self, event, unit, ...)
		end
	end
end

-- Do a full update OnShow, and stop watching for events when it's not visible
local function OnShow(self)
	-- Reset the event handler
	self:SetScript("OnEvent", OnEvent)
	Units:CheckUnitGUID(self)
end

local function OnHide(self)
	self:SetScript("OnEvent", nil)
	
	-- If it's a non-static unit like target or focus, will reset the flag and force an update when it's shown.
	if( self.unitType ~= "party" and self.unitType ~= "partypet" and self.unitType ~= "partytarget" and self.unitType ~= "player" and self.unitType ~= "raid" ) then
		self.unitGUID = nil
	end
end

-- For targettarget/focustarget/etc units that don't give us real events
local function TargetUnitUpdate(self, elapsed)
	self.timeElapsed = self.timeElapsed + elapsed
	
	if( self.timeElapsed >= 0.50 ) then
		self.timeElapsed = 0
		
		-- Have to make sure the unit exists or else the frame will flash offline for a second until it hides
		if( UnitExists(self.unit) ) then
			self:FullUpdate()
		end
	end
end

-- Deal with enabling modules inside a zone
local function SetVisibility(self)
	local layoutUpdate
	local zone = select(2, IsInInstance())

	-- Selectively disable modules
	for _, module in pairs(ShadowUF.moduleOrder) do
		if( module.OnEnable and module.OnDisable and ShadowUF.db.profile.units[self.unitType][module.moduleKey] ) then
			local key = module.moduleKey
			local enabled = ShadowUF.db.profile.units[self.unitType][key].enabled or nil
			
			-- These have child options where we want to disable the entire module if they are all disabled
			-- but we want to enable the module if at least one is enabled
			if( key == "auras" or key == "indicators" or key == "highlight" ) then
				enabled = nil
				for _, option in pairs(ShadowUF.db.profile.units[self.unitType][key]) do
					if( type(option) == "table" and option.enabled or option == true ) then
						enabled = true
						break
					end
				end
			end
			
			-- In an actual zone, check to see if we have an override for the zone
			if( zone ~= "none" ) then
				if( ShadowUF.db.profile.visibility[zone][self.unitType .. key] == false ) then
					enabled = nil
				elseif( ShadowUF.db.profile.visibility[zone][self.unitType .. key] == true ) then
					enabled = true
				end
			end
			
			-- Options changed, will need to do a layout update
			local wasEnabled = self.visibility[key]
			if( self.visibility[key] ~= enabled ) then
				layoutUpdate = true
			end
			
			self.visibility[key] = enabled
			
			-- Module isn't enabled all the time, only in this zone so we need to force it to be enabled
			if( enabled and not self.status[key] ) then
				module:OnEnable(self)
				self.status[key] = true
			elseif( not enabled and self.status[key] ) then
				module:OnDisable(self)
				self.status[key] = nil
			end
		end
	end
	
	-- We had a module update, force a full layout update
	if( layoutUpdate ) then
		ShadowUF.Layout:Load(self)
	end
end

-- Vehicles do not always return their data right away, a pure OnUpdate check seems to be the most accurate unfortunately
local function checkVehicleData(self, elapsed)
	self.timeElapsed = self.timeElapsed + elapsed
	if( self.timeElapsed >= 0.20 ) then
		self.timeElapsed = 0
		self.dataAttempts = self.dataAttempts + 1
		
		-- Either we got data already, or it took over 5 seconds (25 tries) to get it
		if( UnitIsConnected(self.unit) or UnitHealthMax(self.unit) > 0 or self.dataAttempts >= 25 ) then
			self:SetScript("OnUpdate", nil)
			self:FullUpdate()
		end
	end
end

-- Check if a unit entered a vehicle
function Units:CheckVehicleStatus(frame, event, unit)
	if( event and frame.unitOwner ~= unit ) then return end
	
	-- Not in a vehicle yet, and they entered one that has a UI 
	if( not frame.inVehicle and UnitHasVehicleUI(frame.unitOwner) and not ShadowUF.db.profile.units[frame.unitType].disableVehicle ) then
		frame.inVehicle = true
		frame.unit = frame.vehicleUnit

		if( not UnitIsConnected(frame.unit) or UnitHealthMax(frame.unit) == 0 ) then
			frame.timeElapsed = 0
			frame.dataAttempts = 0
			frame:SetScript("OnUpdate", checkVehicleData)
		else
			frame:FullUpdate()
		end
		
		-- Keep track of what the players current unit is supposed to be, so things like auras can figure it out
		if( frame.unitOwner == "player" ) then ShadowUF.playerUnit = frame.unit end
		
	-- Was in a vehicle, no longer has a UI
	elseif( frame.inVehicle and ( not UnitHasVehicleUI(frame.unitOwner) or ShadowUF.db.profile.units[frame.unitType].disableVehicle ) ) then
		frame.inVehicle = false
		frame.unit = frame.unitOwner
		frame.unitGUID = UnitGUID(frame.unit)
		frame:FullUpdate()

		if( frame.unitOwner == "player" ) then ShadowUF.playerUnit = frame.unitOwner end
	end
end

-- The argument from UNIT_PET is the pets owner, so the player summoning a new pet gets "player", party1 summoning a new pet gets "party1" and so on
function Units:CheckUnitUpdated(frame, event, unit)
	if( unit ~= frame.unitRealOwner or not UnitExists(frame.unit) ) then return end
	frame:FullUpdate()
end

-- When a frames GUID changes,
-- Handles checking for GUID changes for doing a full update, this fixes frames sometimes showing the wrong unit when they change
function Units:CheckUnitGUID(frame)
	local guid = frame.unit and UnitGUID(frame.unit)
	if( guid and guid ~= frame.unitGUID ) then
		frame:FullUpdate()
	end
	
	frame.unitGUID = guid
end

-- This is the fall back, raid frames can't be done without tainting unfortunately, but will see if I can find a way around it
local function ShowMenu(self)
	local menuFrame
	if( string.match(self.unit, "party") ) then
		menuFrame = getglobal("PartyMemberFrame" .. self.unitID .. "DropDown")
	else
		menuFrame = FriendsDropDown
		menuFrame.displayMode = "MENU"
		menuFrame.initialize = RaidFrameDropDown_Initialize
		menuFrame.userData = self.unitID
	end

	HideDropDownMenu(1)
	menuFrame.unit = self.unit
	menuFrame.name = UnitName(self.unit)
	menuFrame.id = self.unitID
	ToggleDropDownMenu(1, nil, menuFrame, "cursor")
end

-- Attribute set, something changed
-- unit = Active unitid
-- unitID = Just the number from the unitid
-- unitType = Unitid minus numbers in it, used for configuration
-- unitOwner = Always the units owner even when unit changes due to vehicles
-- vehicleUnit = Unit to use when the unitOwner is in a vehicle
local function OnAttributeChanged(self, name, unit)
	if( name ~= "unit" or not unit or unit == self.unitOwner ) then return end
	
	-- Unit already exists but unitid changed, update the info we got on them
	-- Don't need to recheck the unitType and force a full update, because a raid frame can never become
	-- a party frame, or a player frame and so on
	if( self.unit ) then
		self.unit = unit
		self.unitID = tonumber(string.match(unit, "([0-9]+)"))
		self.unitOwner = unit
		self.vehicleUnit = self.unitOwner == "player" and "vehicle" or self.unitType == "party" and "partypet" .. self.unitID or self.unitType == "raid" and "raidpet" .. self.unitID or nil
		self.inVehicle = false
		
		Units:CheckUnitGUID(self)
		return
	end
		
	-- Setup identification data
	self.unit = unit
	self.unitID = tonumber(string.match(unit, "([0-9]+)"))
	self.unitType = self.unitType or string.gsub(unit, "([0-9]+)", "")
	self.unitOwner = unit
	self.vehicleUnit = self.unitOwner == "player" and "vehicle" or self.unitType == "party" and "partypet" .. self.unitID or self.unitType == "raid" and "raidpet" .. self.unitID or nil
	
	-- Add to Clique
	ClickCastFrames = ClickCastFrames or {}
	ClickCastFrames[self] = true

	-- Store it for later
	unitFrames[self.unit] = self
	
	-- Pet changed, going from pet -> vehicle for one
	if( self.unit == "pet" or self.unitType == "partypet" ) then
		self.unitRealOwner = self.unit == "pet" and "player" or ShadowUF.partyUnits[self.unitID]
		self:RegisterNormalEvent("UNIT_PET", Units, "CheckUnitUpdated")
		
		if( self.unit == "pet" ) then
			self.dropdownMenu = PetFrameDropDown
			self:SetAttribute("_menu", PetFrame.menu)
			self:SetAttribute("disableVehicleSwap", ShadowUF.db.profile.units.player.disableVehicle)
		else
			self:SetAttribute("disableVehicleSwap", ShadowUF.db.profile.units.party.disableVehicle)
		end
	
		-- Logged out in a vehicle
		if( UnitHasVehicleUI(self.unitRealOwner) ) then
			self:SetAttribute("unitIsVehicle", true)
		end

		-- Hide any pet that became a vehicle, we detect this by the owner being untargetable but we have a pet out
		RegisterStateDriver(self, "vehicleupdated", string.format("[target=%s, nohelp, noharm] vehicle; [target=%s, exists] pet", self.unitRealOwner, self.unit))
		vehicleMonitor:WrapScript(self, "OnAttributeChanged", [[
			if( name == "state-vehicleupdated" ) then
				self:SetAttribute("unitIsVehicle", value == "vehicle" and true or false)
			elseif( name == "state-unitexists" ) then
				if( not value or ( not self:GetAttribute("disableVehicleSwap") and self:GetAttribute("unitIsVehicle") ) ) then
					self:Hide()
				elseif( value ) then
					self:Show()
				end
			elseif( name == "disablevehicleswap" ) then
				if( value and self:GetAttribute("state-unitexists") ) then
					self:Show()
				elseif( not self:GetAttribute("state-unitexists") or ( not value and self:GetAttribute("unitIsVehicle") ) ) then 
					self:Hide()
				end
			end
		]])

	-- Automatically do a full update on target change
	elseif( self.unit == "target" ) then
		self.dropdownMenu = TargetFrameDropDown
		self:SetAttribute("_menu", TargetFrame.menu)
		self:RegisterNormalEvent("PLAYER_TARGET_CHANGED", Units, "CheckUnitGUID")

	-- Automatically do a full update on focus change
	elseif( self.unit == "focus" ) then
		self.dropdownMenu = FocusFrameDropDown
		self:SetAttribute("_menu", FocusFrame.menu)
		self:RegisterNormalEvent("PLAYER_FOCUS_CHANGED", Units, "CheckUnitGUID")
				
	elseif( self.unit == "player" ) then
		self.dropdownMenu = PlayerFrameDropDown
		self:SetAttribute("_menu", PlayerFrame.menu)
		self:SetAttribute("toggleForVehicle", true)
		
		-- Force a full update when the player is alive to prevent freezes when releasing in a zone that forces a ressurect (naxx/tk/etc)
		self:RegisterNormalEvent("PLAYER_ALIVE", self, "FullUpdate")
	
	-- Check for a unit guid to do a full update
	elseif( self.unitType == "raid" ) then
		self:RegisterNormalEvent("RAID_ROSTER_UPDATE", Units, "CheckUnitGUID")
		
	-- Party members need to watch for changes
	elseif( self.unitType == "party" ) then
		self:RegisterNormalEvent("PARTY_MEMBERS_CHANGED", Units, "CheckUnitGUID")

		-- Party frame has been loaded, so initialize it's sub-frames if they are enabled
		if( loadedUnits.partypet ) then
			if( not InCombatLockdown() ) then
				Units:LoadChildUnit(self, "partypet", "partypet" .. self.unitID)
			else
				queuedCombat["partypet" .. self.unitID] = self
			end
		end
		
		if( loadedUnits.partytarget ) then
			if( not InCombatLockdown() ) then
				Units:LoadChildUnit(self, "partytarget", "party" .. self.unitID .. "target")
			else
				queuedCombat["party" .. self.unitID .. "target"] = self
			end
		end

	-- *target units are not real units, thus they do not receive events and must be polled for data
	elseif( string.match(self.unit, "%w+target") ) then
		self.timeElapsed = 0
		self:SetScript("OnUpdate", TargetUnitUpdate)
		
		-- This speeds up updating of fake units, if party1 changes target then party1target is force updated, if target changes target, then targettarget and targettarget are force updated
		-- same goes for focus changing target, focustarget is forced to update.
		self.unitRealOwner = self.unitType == "partytarget" and ShadowUF.partyUnits[self.unitID] or self.unitType == "focustarget" and "focus" or "target"
		self:RegisterNormalEvent("UNIT_TARGET", Units, "CheckUnitUpdated")
		
		-- Another speed up, if the focus changes then of course the focustarget has to be force updated
		if( self.unit == "focustarget" ) then
			self:RegisterNormalEvent("PLAYER_FOCUS_CHANGED", Units, "CheckUnitGUID")
		-- If the player changes targets, then we know the targettarget and targettargettarget definitely changed
		elseif( self.unit == "targettarget" or self.unit == "targettargettarget" ) then
			self:RegisterNormalEvent("PLAYER_TARGET_CHANGED", Units, "CheckUnitGUID")
		end
	end

	-- You got to love programming without documentation, ~3 hours spent making this work with raids and such properly, turns out? It's a simple attribute
	-- and all you have to do is set it up so the unit variables are properly changed based on being in a vehicle... which is what will do now
	if( self.unit == "player" or self.unitType == "party" or self.unitType == "raid" ) then
		self:RegisterNormalEvent("UNIT_ENTERED_VEHICLE", Units, "CheckVehicleStatus")
		self:RegisterNormalEvent("UNIT_EXITED_VEHICLE", Units, "CheckVehicleStatus")
		self:RegisterUpdateFunc(Units, "CheckVehicleStatus")
						
		-- Check if they are in a vehicle
		Units:CheckVehicleStatus(self)
	end	
	
	-- Update module status
	self:SetVisibility()
	
	-- Check for any unit changes
	Units:CheckUnitGUID(self)
end

-- Header unit initialized
local function initializeUnit(self)
	local unitType = self:GetParent().unitType
	local config = ShadowUF.db.profile.units[unitType]

	self.ignoreAnchor = true
	self.unitType = unitType
	self:SetAttribute("initial-height", config.height)
	self:SetAttribute("initial-width", config.width)
	self:SetAttribute("initial-scale", config.scale)
	self:SetAttribute("toggleForVehicle", true)
	
	-- We can't set the attribute for game menus in combat by the time OnAttributeChanged fires
	-- if they are using invalid sorting, will force it to use the dynamic show menu 
	if( unitType == "party" and config.sortMethod == "INDEX" and config.sortOrder == "ASC" ) then
		local unitID = string.match(self:GetName(), "(%d+)")
		self.dropdownMenu = _G["PartyMemberFrame" .. unitID .. "DropDown"]
		self:SetAttribute("_menu", _G["PartyMemberFrame" .. unitID].menu)
	else
		self.dropdownMenu = FriendsDropDown
		self.menu = ShowMenu
	end
		
	Units:CreateUnit(self)
end

-- Show tooltip
local function OnEnter(self)
	if( not ShadowUF.db.profile.tooltipCombat or not InCombatLockdown() ) then
		UnitFrame_OnEnter(self)
	end
end

-- Reset the fact that we clamped the dropdown to the screen to be safe
DropDownList1:HookScript("OnHide", function(self)
	self:SetClampedToScreen(false)
end)

-- Create the generic things that we want in every secure frame regardless if it's a button or a header
function Units:CreateUnit(frame)
	frame.fullUpdates = {}
	frame.registeredEvents = {}
	frame.visibility = {}
	frame.status = {}
	frame.RegisterNormalEvent = RegisterNormalEvent
	frame.RegisterUnitEvent = RegisterUnitEvent
	frame.RegisterUpdateFunc = RegisterUpdateFunc
	frame.UnregisterAll = UnregisterAll
	frame.FullUpdate = FullUpdate
	frame.SetVisibility = SetVisibility
	frame.topFrameLevel = FRAME_LEVEL_MAX
	
	-- Ensures that text is the absolute highest thing there is
	frame.highFrame = CreateFrame("Frame", nil, frame)
	frame.highFrame:SetFrameLevel(frame.topFrameLevel + 1)
	frame.highFrame:SetAllPoints(frame)
	
	frame:SetScript("OnAttributeChanged", OnAttributeChanged)
	frame:SetScript("OnEvent", OnEvent)
	frame:SetScript("OnEnter", OnEnter)
	frame:SetScript("OnLeave", UnitFrame_OnLeave)
	frame:SetScript("OnShow", OnShow)
	frame:SetScript("OnHide", OnHide)

	frame:RegisterForClicks("AnyUp")	
	frame:SetAttribute("*type1", "target")
	frame:SetAttribute("*type2", "menu")
	frame:SetScript("PostClick", function(self)
		if( UIDROPDOWNMENU_OPEN_MENU == self.dropdownMenu and DropDownList1:IsShown() )	 then
			DropDownList1:ClearAllPoints()
			DropDownList1:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, 0)
			DropDownList1:SetClampedToScreen(true)
		end
	end)
	
	-- allowVehicleTarget
	--[16:42] <+alestane> Shadowed: It says whether a unit defined as, for instance, "party1target" should be remapped to "partypet1target" when party1 is in a vehicle.
end

-- Update the main header
function Units:ReloadHeader(type)
	local frame = unitFrames[type]
	if( frame ) then
		self:SetFrameAttributes(frame, type)
		ShadowUF.Layout:AnchorFrame(UIParent, frame, ShadowUF.db.profile.positions[type])
	end
end

function Units:SetFrameAttributes(frame, type)
	local config = ShadowUF.db.profile.units[type]
	if( not config ) then
		return
	end
	
	frame:SetAttribute("point", config.attribPoint)
	frame:SetAttribute("xOffset", config.xOffset)
	frame:SetAttribute("yOffset", config.yOffset)
	frame:SetAttribute("sortMethod", config.sortMethod)
	frame:SetAttribute("sortDir", config.sortOrder)
		
	if( type == "raid" ) then
		local filter
		for id, enabled in pairs(config.filters) do
			if( enabled ) then
				if( filter ) then
					filter = filter .. "," .. id
				else
					filter = id
				end
			end
		end
	
		frame:SetAttribute("showRaid", true)
		frame:SetAttribute("maxColumns", config.maxColumns)
		frame:SetAttribute("unitsPerColumn", config.unitsPerColumn)
		frame:SetAttribute("columnSpacing", config.columnSpacing)
		frame:SetAttribute("columnAnchorPoint", config.attribAnchorPoint)
		frame:SetAttribute("groupFilter", filter or "1,2,3,4,5,6,7,8")
		
		if( config.groupBy == "CLASS" ) then
			frame:SetAttribute("groupingOrder", "DEATHKNIGHT,DRUID,HUNTER,MAGE,PALADIN,PRIEST,ROGUE,SHAMAN,WARLOCK,WARRIOR")
			frame:SetAttribute("groupBy", "CLASS")
		else
			frame:SetAttribute("groupingOrder", "1,2,3,4,5,6,7,8")
			frame:SetAttribute("groupBy", "GROUP")
		end
	-- Update party frames to not show anyone if they should be in raids
	elseif( type == "party" ) then
		frame:SetAttribute("showParty", ( not config.showAsRaid or not ShadowUF.db.profile.units.raid.enabled ) and true or false)

		if( config.sortMethod ~= "INDEX" or config.sortOrder ~= "ASC" ) then
			frame.dropdownMenu = FriendsDropDown
			frame.menu = ShowMenu
		end
	end

	-- Update the raid frames to if they should be showing raid or party
	if( unitFrames.raid and unitFrames.party ) then
		unitFrames.raid:SetAttribute("showParty", not unitFrames.party:GetAttribute("showParty"))
	end
end

-- Load a single unit such as player, target, pet, etc
function Units:LoadUnit(config, unit)
	-- Already be loaded, just enable
	if( unitFrames[unit] ) then
		RegisterUnitWatch(unitFrames[unit], unit == "pet")
		return
	end
	
	local frame = CreateFrame("Button", "SUFUnit" .. unit, UIParent, "SecureUnitButtonTemplate")
	self:CreateUnit(frame)
	frame:SetAttribute("unit", unit)

	unitFrames[unit] = frame
		
	-- Annd lets get this going
	RegisterUnitWatch(frame, unit == "pet")
end

-- Load a header unit, party or raid
function Units:LoadGroupHeader(config, type)
	if( unitFrames[type] ) then
		unitFrames[type]:Show()
		return
	end
	
	local headerFrame = CreateFrame("Frame", "SUFHeader" .. type, UIParent, "SecureGroupHeaderTemplate")
	self:SetFrameAttributes(headerFrame, type)
	
	headerFrame:SetAttribute("template", "SecureUnitButtonTemplate")
	headerFrame:SetAttribute("initial-unitWatch", true)
	headerFrame.initialConfigFunction = initializeUnit
	headerFrame.unitType = type
	headerFrame:Show()

	unitFrames[type] = headerFrame
	ShadowUF.Layout:AnchorFrame(UIParent, headerFrame, ShadowUF.db.profile.positions[type])
end

-- Load a unit that is a child of another unit (party pet/party target)
function Units:LoadChildUnit(parent, type, unit)
	if( unitFrames[unit] ) then
		ShadowUF.Layout:AnchorFrame(parent, unitFrames[unit], ShadowUF.db.profile.positions[type])

		unitFrames[unit]:SetParent(parent)
		unitFrames[unit].parent = parent

		RegisterUnitWatch(unitFrames[unit], type == "partypet")
		return
	end
	
	local frame = CreateFrame("Button", "SUFUnit" .. unit, parent, "SecureUnitButtonTemplate")
	frame:SetFrameStrata("LOW")
	self:CreateUnit(frame)
	frame:SetAttribute("unit", unit)
	frame.parent = parent
	
	unitFrames[unit] = frame

	ShadowUF.Layout:AnchorFrame(parent, unitFrames[unit], ShadowUF.db.profile.positions[type])
	RegisterUnitWatch(frame, type == "partypet")
end

-- Initialize units
function Units:InitializeFrame(config, type)
	if( loadedUnits[type] ) then return end
	loadedUnits[type] = true
	
	if( type == "party" or type == "raid" ) then
		self:LoadGroupHeader(config, type)
	-- Since I delay the partypet/partytarget creation until the owners were loaded, we don't want to actually initialize them here
	-- unless the pets were already loaded, this mainly accounts for the fact that you might enable a unit in arenas, but not in raids, etc.
	elseif( type == "partypet" ) then
		for id, unit in pairs(ShadowUF.partyUnits) do
			if( unitFrames[unit] ) then
				Units:LoadChildUnit(unitFrames[ShadowUF.partyUnits[id]], type, "partypet" .. id)
			end
		end
	elseif( type == "partytarget" ) then
		for id, unit in pairs(ShadowUF.partyUnits) do
			if( unitFrames[unit] ) then
				Units:LoadChildUnit(unitFrames[ShadowUF.partyUnits[id]], type, "party" .. id .. "target")
			end
		end
	else
		self:LoadUnit(config, type)
	end
end

-- Uninitialize units
function Units:UninitializeFrame(config, type)
	if( not loadedUnits[type] ) then return end
	loadedUnits[type] = nil
		
	-- Disable all frames of this time
	for _, frame in pairs(unitFrames) do
		if( frame.unitType == type ) then
			UnregisterUnitWatch(frame)
			frame:Hide()
		end
	end
end

-- Profile changed, reload units
function Units:ProfileChanged()
	-- Reset the anchors for all frames to prevent X is dependant on Y
	for _, frame in pairs(unitFrames) do
		if( frame:GetAttribute("unit") ) then
			frame:ClearAllPoints()
		end
	end
	
	-- Force all of the module changes
	for _, frame in pairs(unitFrames) do
		if( frame:GetAttribute("unit") ) then
			-- Force all enabled modules to disable
			for key, module in pairs(ShadowUF.modules) do
				if( frame[key] and frame.status[key] ) then
					frame.status[key] = nil
					module:OnDisable(frame)
				end
			end
			
			-- Now enable whatever we need to
			frame:SetVisibility()
			ShadowUF.Layout:Load(frame)
			frame:FullUpdate()
		end
	end
	
	-- Force headers to update
	self:ReloadHeader("raid")
	self:ReloadHeader("party")
end

-- Small helper function for creating bars with
function Units:CreateBar(parent)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetFrameLevel(FRAME_LEVEL_MAX)
	bar.parent = parent
	
	bar.background = bar:CreateTexture(nil, "BORDER")
	bar.background:SetHeight(1)
	bar.background:SetWidth(1)
	bar.background:SetAllPoints(bar)

	return bar
end

-- Deal with zone changes for enabling modules
local instanceType
function Units:CheckPlayerZone(force)
	local instance = select(2, IsInInstance())
	if( instance == instanceType and not force ) then return end
	instanceType = instance
	
	ShadowUF:LoadUnits()
	for _, frame in pairs(unitFrames) do
		if( frame:GetAttribute("unit") ) then
			frame:SetVisibility()
			
			if( UnitExists(frame.unit) ) then
				frame:FullUpdate()
			end
		end
	end
end

-- Handles events related to all units and not a specific one
local centralFrame = CreateFrame("Frame")
centralFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
centralFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
centralFrame:SetScript("OnEvent", function(self, event, unit)
	-- Check if the player changed zone types and we need to change module status, while they are dead
	-- we won't change their zone type as releasing from an instance will change the zone type without them
	-- really having left the zone
	if( event == "ZONE_CHANGED_NEW_AREA" ) then
		if( UnitIsDeadOrGhost("player") ) then
			self:RegisterEvent("PLAYER_UNGHOST")
			return
		else
			self:UnregisterEvent("PLAYER_UNGHOST")
		end
		
		Units:CheckPlayerZone()
	-- They're alive again so they "officially" changed zone types now
	elseif( event == "PLAYER_UNGHOST" ) then
		Units:CheckPlayerZone()
	-- This is slightly hackish, but it suits the purpose just fine for somthing thats rarely called.
	elseif( event == "PLAYER_REGEN_ENABLED" ) then
		for unitID, parent in pairs(queuedCombat) do
			queuedCombat[unitID] = nil
			Units:LoadChildUnit(parent, string.gsub(unitID, "(%d+)", ""), unitID)
		end
	end
end)