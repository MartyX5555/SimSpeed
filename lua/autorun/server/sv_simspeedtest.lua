
-- Values might vary between each computer's performance. Adjust it according to your tests and specs.
CreateConVar("gsimspeed_enable", 1, FCVAR_ARCHIVE, "enable/disable the SimSpeed")
CreateConVar("gsimspeed_system_defaultsim", 1, FCVAR_ARCHIVE, "Sets the default sim speed.")
CreateConVar("gsimspeed_system_max_entities", 500, FCVAR_ARCHIVE, "Max number of entities to consider a good performance.")
CreateConVar("gsimspeed_system_max_consscore", 6000, FCVAR_ARCHIVE, "Max Score obtained by props with constraints to consider a good performance.")
CreateConVar("gsimspeed_system_max_coldelay", 7, FCVAR_ARCHIVE, "Max delay, between collisions to consider a good performance")

CreateConVar("gsimspeed_props_cancreate_minsim", 0.1, FCVAR_ARCHIVE, "Sets the minimal sim speed prop spawning is allowed.")


GSimSpeed = GSimSpeed or {}
GSimSpeed.Entities = GSimSpeed.Entities or {}
GSimSpeed.IsSimSpeedActive = false
GSimSpeed.CanSpawn = false

-- A list of classes that should not be added into the list.
GSimSpeed.Blacklist = {
	prop_door = true,
	prop_dynamic = true,
	func_ = true,
}

--PrintTable(GSimSpeed.Entities)

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
		end
	end)
end
hook.Remove("OnEntityCreated", "SimSpeed.AddEntity")
hook.Add("OnEntityCreated", "SimSpeed.AddEntity", AddEntity)

-- Removes entities from the system
local function RemoveEntity(ent)
	GSimSpeed.Entities[ent] = nil
end
hook.Remove("EntityRemoved", "SimSpeed.RemoveEntity")
hook.Add("EntityRemoved", "SimSpeed.RemoveEntity", RemoveEntity)

local function getConvarValue(command)
	return GetConVar("gsimspeed_" .. command):GetFloat()
end

local function resetTimeScale()
	if not IsSimSpeedActive then return end
	IsSimSpeedActive = nil
	GSimSpeed.CanSpawn = true
	game.SetTimeScale( 1 )
end

local function SimSpeedThink()
	if getConvarValue("enable") < 1 then resetTimeScale() return end

	if not IsSimSpeedActive then
		IsSimSpeedActive = true
	end

	-- Lag by collisions
	local factor = physenv.GetLastSimulationTime() * 1000
	local physratio = math.min(getConvarValue("system_max_coldelay") / factor, 1)

	-- Lag by moving entities
	local ActiveEnts = 0
	local ExtraPoints = 0
	for ent, _ in pairs(GSimSpeed.Entities) do
		if not IsValid(ent) then continue end
		local physobj = ent:GetPhysicsObject()
		if IsValid(physobj) and not physobj:IsAsleep() then
			ActiveEnts = ActiveEnts + 1

			-- The points are the constraints per entity.
			if constraint.HasConstraints(ent) then
				ExtraPoints = ExtraPoints + table.Count(ent.Constraints)
			end
		end
	end
	local movratio = math.min(getConvarValue("system_max_entities") / ActiveEnts, 1)

	-- Lag by constraints
	local consratio = math.min(getConvarValue("system_max_consscore") / ExtraPoints, 1)

	-- Gets the worst of the 3.
	local finalratio = math.min(physratio, movratio, consratio)
	game.SetTimeScale( getConvarValue("system_defaultsim") *  finalratio )

	--print("Sim Speed Ratio:", game.GetTimeScale(), "Moved Entities:", ActiveEnts, "All Entities:", table.Count(GSimSpeed.Entities), "Moved Constraints:", ExtraPoints)

	-- Restricts the creation of new ents if the sim speed is below to the specified.
	GSimSpeed.CanSpawn = true
	if game.GetTimeScale() < getConvarValue("props_cancreate_minsim") then
		GSimSpeed.CanSpawn = false
	end

end
hook.Remove("Tick", "SimSpeed.Think")
hook.Add("Tick", "SimSpeed.Think", SimSpeedThink)

local function CanCreateEntity(ply)
	if not GSimSpeed.CanSpawn then
		local Override = hook.Run( "SimSpeed_OnSpawnError", game.GetTimeScale() )
		if not Override then
			ply:ChatPrint("Too much lag to process this task!")
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