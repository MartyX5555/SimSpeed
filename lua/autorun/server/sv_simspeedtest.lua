
local MSLag = 7
local MovingEntities = 500
local Constraints = 6000
local CanSpawn

-- Values might vary between each computer's performance. Adjust it according to your tests and specs.
CreateConVar("gsimspeed_enable", 1, FCVAR_ARCHIVE, "enable/disable the SimSpeed")
CreateConVar("gsimspeed_system_max_entities", 600, FCVAR_ARCHIVE, "Max number of entities to consider a good performance.")
CreateConVar("gsimspeed_system_max_consfactor", 1000, FCVAR_ARCHIVE, "A number that defines the limit for constraints.")
CreateConVar("gsimspeed_system_max_coldelay", 7, FCVAR_ARCHIVE, "Max delay, between collisions to consider a good performance")

CreateConVar("gsimspeed_props_cancreate_minsim", 0.1, FCVAR_ARCHIVE, "Sets the minimal sim speed prop spawning is allowed.")

GSimSpeed = GSimSpeed or {}
GSimSpeed.Entities = GSimSpeed.Entities or {}

GSimSpeed.WhiteList = {
	prop_physics = true,
}

local function AddEntity(ent)
	timer.Simple(0, function()
		if not IsValid(ent) then return end
		if not GSimSpeed.WhiteList[ent:GetClass()] then return end
		local physobj = ent:GetPhysicsObject()
		if IsValid(physobj) then
			GSimSpeed.Entities[ent] = true
		end
	end)
end
hook.Remove("OnEntityCreated", "SimSpeed.AddEntity")
hook.Add("OnEntityCreated", "SimSpeed.AddEntity", AddEntity)


local function RemoveEntity(ent)
	GSimSpeed.Entities[ent] = nil
end
hook.Remove("EntityRemoved", "SimSpeed.RemoveEntity")
hook.Add("EntityRemoved", "SimSpeed.RemoveEntity", RemoveEntity)

local function resetTimeScale()
	if not IsSimSpeedActive then return end
	print("values have been reseted!")
	IsSimSpeedActive = nil
	CanSpawn = true
	game.SetTimeScale( 1 )
end

local function SimSpeedThink()
	if GetConVar("GSimSpeed_enable"):GetInt() < 1 then resetTimeScale() return end

	if not IsSimSpeedActive then
		IsSimSpeedActive = true
	end

	-- Lag by collisions
	local factor = physenv.GetLastSimulationTime() * 1000
	local physratio = math.min(MSLag / factor, 1)

	-- Lag by moving entities
	local ActiveEnts = 0
	local ExtraPoints = 0
	for ent, _ in pairs(GSimSpeed.Entities) do
		if not IsValid(ent) then continue end
		local physobj = ent:GetPhysicsObject()
		if IsValid(physobj) and not physobj:IsAsleep() then 
			ActiveEnts = ActiveEnts + 1

			if constraint.HasConstraints(ent) then
				ExtraPoints = ExtraPoints + table.Count(ent.Constraints) --#constraint.GetTable(ent)
			end
		end
	end
	local movratio = math.min(MovingEntities / ActiveEnts, 1)

	-- Lag by constraints
	local consratio = math.min(Constraints / ExtraPoints, 1)

	local finalratio = math.min(physratio, movratio, consratio)

	CanSpawn = true
	if finalratio < GetConVar("gsimspeed_props_cancreate_minsim"):GetFloat() then
		CanSpawn = false
	end

	--print("Sim Speed Ratio:", finalratio, "Moved Entities:", ActiveEnts, "Moved Constraints:", ExtraPoints)

	game.SetTimeScale( finalratio )
end
hook.Remove("Tick", "SimSpeed.Think")
hook.Add("Tick", "SimSpeed.Think", SimSpeedThink)

local function CanCreateEntity(ply)
	if not CanSpawn then ply:ChatPrint("Too much lag to process this task!") return false end
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