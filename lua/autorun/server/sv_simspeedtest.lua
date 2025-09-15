util.AddNetworkString("SimSpeed.Network")

local function TransmmitStatus()
	net.Start("SimSpeed.Network")
		net.WriteBool(GSimSpeed.IsEnabled)
	net.Broadcast()
end

net.Receive("SimSpeed.Network", function()
	TransmmitStatus()
end)

local function EnableSimSpeed(_, _, new)
	local Bool = tobool(new)
	GSimSpeed.IsEnabled = Bool
	TransmmitStatus()
end
CreateConVar("gsimspeed_enable", 1, FCVAR_ARCHIVE, "enable/disable the SimSpeed")
cvars.RemoveChangeCallback("gsimspeed_enable", "gsimspeed_enable_callback" )
cvars.AddChangeCallback("gsimspeed_enable", EnableSimSpeed, "gsimspeed_enable_callback")

hook.Remove("Initialize", "SimSpeed.Initialize.ConvarValueSync")
hook.Add( "Initialize", "SimSpeed.Initialize.ConvarValueSync", function()
	local value = GetConVar("gsimspeed_enable"):GetFloat()
	GSimSpeed.IsEnabled = tobool(value)
end )

-- SimSpeed Rules. For the best results, adjust it according to your current game performance.
-- TODO: Provide a tool/helper to calibrate this properly.
CreateConVar("gsimspeed_max_entities", 500, FCVAR_ARCHIVE, "Max number of entities to consider a good performance.")
CreateConVar("gsimspeed_max_consscore", 6000, FCVAR_ARCHIVE, "Max Score obtained by props with constraints to consider a good performance.")
CreateConVar("gsimspeed_max_coldelay", 7, FCVAR_ARCHIVE, "Max delay, between collisions to consider a good performance")
CreateConVar("gsimspeed_max_luadelay", 30, FCVAR_ARCHIVE, "Max delay, for lua to consider a good performance") -- 15 can work, but for servers

-- Developer / Advanced settings. To enable/disable specific checks from the SimSpeed system.
CreateConVar("gsimspeed_monitor_lua", 1, FCVAR_ARCHIVE, "enable/disable the lua/framerates check.")
CreateConVar("gsimspeed_monitor_collisions", 1, FCVAR_ARCHIVE, "enable/disable the collisions check.")
CreateConVar("gsimspeed_monitor_entities", 1, FCVAR_ARCHIVE, "enable/disable the entities/constraints check")

-- Protection and extras.
CreateConVar("gsimspeed_enableprotection", 0, FCVAR_ARCHIVE, "enable/disable the default simspeed protection that consist on lockouts and freezes. Leave it disabled if you use a custom one.")
CreateConVar("gsimspeed_defaultsim", 1, FCVAR_ARCHIVE, "Sets the default sim speed.")
CreateConVar("gsimspeed_dangersim", 0.1, FCVAR_ARCHIVE, "Specifies the danger sim speed mark.")
CreateConVar("gsimspeed_criticalsim", 0.02, FCVAR_ARCHIVE, "Specifies the critical sim speed mark.")

GSimSpeed = GSimSpeed or {}
GSimSpeed.Entities = GSimSpeed.Entities or {}
GSimSpeed.IsSimSpeedActive = false
GSimSpeed.CanSpawn = true
GSimSpeed.IsEnabled = true

-- A list of classes that should not be added into the list.
GSimSpeed.Blacklist = {
	prop_door = true,
	prop_dynamic = true,
	func_ = true,
}

local SetTimeScale = game.SetTimeScale
local GetTimeScale = game.GetTimeScale

local function HasBlacklistedPatterns(class)
	for pattern, _ in pairs(GSimSpeed.Blacklist) do
		if string.StartsWith(class, pattern) then
			return true
		end
	end
	return false
end

-- Adds entities to the system
local function AddEntity(ent)
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		if ent:EntIndex() == 0 then return end
		if HasBlacklistedPatterns(ent:GetClass()) then return end
		local physobj = ent:GetPhysicsObject()
		if IsValid(physobj) then
			GSimSpeed.Entities[ent] = true

			-- Removes entities from the system if deleted.
			ent:CallOnRemove("gsimspeed_OnRemove", function()
				GSimSpeed.Entities[ent] = nil
			end)
		end
	end)
end
hook.Remove("OnEntityCreated", "SimSpeed.AddEntity")
hook.Add("OnEntityCreated", "SimSpeed.AddEntity", AddEntity)

local function getConvarValue(command)
	return GetConVar("gsimspeed_" .. command):GetFloat()
end

local function CanMonitor(sysname)
	return getConvarValue("monitor_" .. (sysname or "")) >= 1
end

local function resetTimeScale()
	if not GSimSpeed.IsSimSpeedActive then return end
	GSimSpeed.IsSimSpeedActive = nil
	GSimSpeed.CanSpawn = true
	SetTimeScale( 1 )
end

-- EZ functions to use. If a server wants to implement this addon.
-- I'm aware of physenv.SetPhysicsPaused() but that also pauses the GetLastSimulationTime too.
-- Freezes every prop on the map. Calls GSimSpeed.OnFreeze hook
function GSimSpeed.FreezeAllProps()

	local Entities = GSimSpeed.Entities
	local Objects = {}
	for ent, _ in pairs(Entities) do
		if not IsValid(ent) then continue end

		local object = ent:GetPhysicsObject()
		if not IsValid(object) then continue end

		object:EnableMotion(false)
		Objects[object] = true
	end
	hook.Run( "GSimSpeed.OnFreeze", Entities, Objects )
end

local TimerId = "GSimSpeed.LockoutTimer"

local function TimerFunc()
	if timer.RepsLeft( TimerId ) > 1 then return end
	GSimSpeed.CanSpawn = true
	hook.Run("SimSpeed.OnEndLockout")
end

-- Temporally prevents the creation of new props via spawnmenu during a specific period of time. 5 seconds is by default.
function GSimSpeed.ApplyCreationLockout(CTime)

	local Time = CTime or 5
	if timer.Exists( TimerId ) then
		timer.Adjust( TimerId, 1, Time, TimerFunc )
		return
	end
	timer.Create( TimerId, 1, Time, TimerFunc )

	GSimSpeed.CanSpawn = false

	hook.Run("SimSpeed.OnStartLockout")
end

local previousratio = 1
local oldestratio = 1

local function SimSpeedTick()
	if not GSimSpeed.IsEnabled then resetTimeScale() return end

	if not GSimSpeed.IsSimSpeedActive then
		GSimSpeed.IsSimSpeedActive = true
	end

	-- Lag by lua. May also work with collisions at some point.
	-- Note: this could not work in singleplayer in a reliable way. Disable it by adding a big number.
	local luaratio = 1
	if CanMonitor("lua") then
		local luafactor = engine.AbsoluteFrameTime() * 1000
		luaratio = math.min( getConvarValue("max_luadelay") / luafactor, 1)
	end

	-- Lag by collisions.
	local physratio = 1
	if CanMonitor("collisions") then
		local factor = physenv.GetLastSimulationTime() * 1000
		physratio = math.min(getConvarValue("max_coldelay") / factor, 1)
	end

	-- Lag by Entities & Constraints
	local movratio = 1
	local consratio = 1
	if CanMonitor("entities") then

		local ActiveEnts = 0
		local ActivePhysObjects = {}
		local ExtraPoints = 0
		for ent, _ in pairs(GSimSpeed.Entities) do
			local physobj = ent:GetPhysicsObject()
			if IsValid(physobj) and not physobj:IsAsleep() then
				ActiveEnts = ActiveEnts + 1

				-- The points are the constraints per entity.
				if constraint.HasConstraints(ent) then
					ExtraPoints = ExtraPoints + table.Count(ent.Constraints)
				end

				ActivePhysObjects[physobj] = true
			end
		end
		movratio = math.min(getConvarValue("max_entities") / ActiveEnts, 1)
		consratio = math.min(getConvarValue("max_consscore") / ExtraPoints, 1)
	end

	-- Gets the worst of the 4. Apply an average based on the last ratio value.
	local currentratio = math.min(physratio, movratio, consratio, luaratio)

	-- if the previous ratio was bad, but the current is good, apply ratio without averaging.
	local finalratio = currentratio
	if currentratio < previousratio and previousratio < oldestratio then
		finalratio = (currentratio + previousratio + oldestratio) / 3
	end

	SetTimeScale( getConvarValue("defaultsim") *  finalratio )

	oldestratio = previousratio
	previousratio = currentratio

	local warninglevel = 0 -- normal. no warnings

	if finalratio < getConvarValue("criticalsim") then -- Critical. Freeze props or another extreme measures. The part where the server is really dying.
		warninglevel = 3
	elseif finalratio < getConvarValue("dangersim") then -- Danger. Prevent more prop spawning or another restrictions.
		warninglevel = 2
	elseif finalratio < getConvarValue("defaultsim") then -- Warning. SimSpeed has droppen below default. No restrictions.
		warninglevel = 1
	end

	hook.Run("SimSpeed.OnLowSim", GSimSpeed.Entities, finalratio, warninglevel)
end
hook.Remove("Tick", "SimSpeed.Tick")
hook.Add("Tick", "SimSpeed.Tick", SimSpeedTick)

local function CanCreateEntity(ply)

	if not GSimSpeed.CanSpawn then
		local Override = hook.Run( "SimSpeed.OnSpawnError", GetTimeScale() )
		if not Override then
			ply:ChatPrint("[SimSpeed Warning] - Too much lag to process this task!")
		end
		return false
	end
end
-- Props, Effects & Ragdolls
hook.Remove("PlayerSpawnObject", "SimSpeed.CanCreateObj")
hook.Add("PlayerSpawnObject", "SimSpeed.CanCreateObj", CanCreateEntity)

-- NPCs
hook.Remove("PlayerSpawnNPC", "SimSpeed.CanCreateNPC")
hook.Add("PlayerSpawnNPC", "SimSpeed.CanCreateNPC", CanCreateEntity)

-- SENTs
hook.Remove("PlayerSpawnSENT", "SimSpeed.CanCreateSENT")
hook.Add("PlayerSpawnSENT", "SimSpeed.CanCreateSENT", CanCreateEntity)

-- Vehicles
hook.Remove("PlayerSpawnVehicle", "SimSpeed.CanCreateVehile")
hook.Add("PlayerSpawnVehicle", "SimSpeed.CanCreateVehile", CanCreateEntity)

-- Tools, as you can use duplicator
hook.Remove("CanTool", "SimSpeed.CanTool")
hook.Add("CanTool", "SimSpeed.CanTool", CanCreateEntity)