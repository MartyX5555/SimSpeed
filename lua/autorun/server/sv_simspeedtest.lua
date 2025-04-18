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

-- Values might vary between each computer's performance. Adjust it according to your tests and specs.
-- If used in a dedicated server

CreateConVar("gsimspeed_system_defaultsim", 1, FCVAR_ARCHIVE, "Sets the default sim speed.")
CreateConVar("gsimspeed_system_max_entities", 500, FCVAR_ARCHIVE, "Max number of entities to consider a good performance.")
CreateConVar("gsimspeed_system_max_consscore", 6000, FCVAR_ARCHIVE, "Max Score obtained by props with constraints to consider a good performance.")
CreateConVar("gsimspeed_system_max_coldelay", 7, FCVAR_ARCHIVE, "Max delay, between collisions to consider a good performance")
CreateConVar("gsimspeed_system_max_luadelay", 30, FCVAR_ARCHIVE, "Max delay, for lua to consider a good performance") -- 15 can work, but for servers

CreateConVar("gsimspeed_props_cancreate_minsim", 0.05, FCVAR_ARCHIVE, "Sets the minimal sim speed prop spawning is allowed.")


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

local function resetTimeScale()
	if not GSimSpeed.IsSimSpeedActive then return end
	GSimSpeed.IsSimSpeedActive = nil
	GSimSpeed.CanSpawn = true
	SetTimeScale( 1 )
end

-- I'm aware of physenv.SetPhysicsPaused() but that also pauses the GetLastSimulationTime too.
local function FreezeProps(PhysObjs)
	for object, _ in pairs(PhysObjs) do
		if not IsValid(object) then continue end
		object:EnableMotion(false)
	end
	hook.Run( "SimSpeed_OnFreeze", PhysObjs )
end

local previousratio = 1
local oldestratio = 1
local function SimSpeedTick()
	if not GSimSpeed.IsEnabled then resetTimeScale() return end

	if not GSimSpeed.IsSimSpeedActive then
		GSimSpeed.IsSimSpeedActive = true
	end

	-- Lag by lua. May also work with collisions at some point.
	-- Note: this could not work in singleplayer in a reliable way. Use it at your own risk
	local luafactor = engine.AbsoluteFrameTime() * 1000
	local luaratio = math.pow(math.min( getConvarValue("system_max_luadelay") / luafactor, 2), 1)

	-- Lag by collisions.
	local factor = physenv.GetLastSimulationTime() * 1000
	local physratio = math.min(getConvarValue("system_max_coldelay") / factor, 1)

	-- Lag by moving entities
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
	local movratio = math.min(getConvarValue("system_max_entities") / ActiveEnts, 1)

	-- Lag by constraints
	local consratio = math.min(getConvarValue("system_max_consscore") / ExtraPoints, 1)

	-- Gets the worst of the 4. Apply an average based on the last ratio value.
	local currentratio = math.min(physratio, movratio, consratio, luaratio)
	local finalratio = (currentratio + previousratio + oldestratio) / 3
	SetTimeScale( getConvarValue("system_defaultsim") *  finalratio )

	-- Restricts the creation of new ents if the sim speed is below to the specified.
	if GSimSpeed.CanSpawn and GetTimeScale() < getConvarValue("props_cancreate_minsim") then

		local Override = hook.Run("SimSpeed.OnLockout", ActivePhysObjects)
		if not Override then
			FreezeProps(ActivePhysObjects)

			GSimSpeed.CanSpawn = false
			timer.Simple(5, function()
				GSimSpeed.CanSpawn = true
			end)
		end
	end

	oldestratio = previousratio
	previousratio = currentratio
end

hook.Remove("Tick", "SimSpeed.Tick")
hook.Add("Tick", "SimSpeed.Tick", SimSpeedTick)

local function CanCreateEntity(ply)

	if not GSimSpeed.CanSpawn then
		local Override = hook.Run( "SimSpeed.OnSpawnError", game.GetTimeScale() )
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