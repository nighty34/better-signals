local signals = require "nightfury/signals/main"
local utils = require "nightfury/signals/utils"
local SignalBluePrint = require "nightfury/signals/model/signal_blueprint"
local BetterSignal = require "nightfury/signals/model/better_signal"
local zone = require "nightfury/signals/zone"
local animationTimer = require "nightfury/signals/utils/timer"

local betterSignals = {}

animationTimer.start()

betterSignals.debugMode = false

betterSignals.registeredSignals = {}
betterSignals.activeSignals = {}
betterSignals.blueprints = {}

local function getRegisteredKey(signalEntity)
	return "signal" .. signalEntity
end

function betterSignals.createSignal(signal_entity, construction, signalBlueprint)
	if signalBlueprint.__type ~= SignalBluePrint.__type then
		print("Not a SignalBlueprint")
		return
	end

	betterSignals.registeredSignals[getRegisteredKey(signal_entity)] = BetterSignal:new(signal_entity, construction, signalBlueprint)
	print("Registered new Signal")
end

function betterSignals.unregisterSignal(signal_entity)
	betterSignals.registeredSignals[getRegisteredKey(signal_entity)] = nil
end

function betterSignals.unregisterSignalByConstruction(construction)
	for signalKey, registeredSignal in pairs(betterSignals.registeredSignals) do
		if registeredSignal.construction and registeredSignal.construction == construction then
			betterSignals.registeredSignals[signalKey] = nil
		end
	end
end

function betterSignals.addBlueprint(con_name, parameters)
	local blueprint = SignalBluePrint:fromParameters(con_name, parameters)
	betterSignals.blueprints[con_name] = blueprint
end

local function isSignal (signal, potentialSignal)
	if betterSignals.registeredSignals[getRegisteredKey(potentialSignal)] then
		local signal = betterSignals.registeredSignals[getRegisteredKey(potentialSignal)]

		local isHybrid = false
		local params = signal:getConstructionParameters()
		local signalBluePrint = signal:getBluePrint()

		if signalBluePrint and (signalBluePrint:getType() == "hybrid") and params then
			isHybrid = params[signalBluePrint:getPreSignalTiggerKey()] == signalBluePrint:getPreSignalTiggerValue()
			if isHybrid then
				return false
			end
		end
	end

	return (signal.type == 0 or signal.type == 1) or ((potentialSignal and betterSignals.registeredSignals[getRegisteredKey(potentialSignal)]))
end

local function getAllVisibleVehicles()
	local trainActivationRange = 500
	local vehicles = game.interface.getEntities({pos = signals.pos, radius = trainActivationRange}, {type = "VEHICLE"})

	if betterSignals.debugMode then
		zone.setZoneCircle("zoneRadius", signals.pos, trainActivationRange, {1,1,0,1})
	end

	for _, trackedTrain in pairs(signals.trackedEntities) do
		local tracked = game.interface.getEntity(trackedTrain)
		if tracked then
			local trackedPos = tracked.position
			if trackedPos then
				local newTrains = game.interface.getEntities({pos = {trackedPos[1], trackedPos[2]}, radius = trainActivationRange}, {type = "VEHICLE"})
				if newTrains and #newTrains > 0 then
					for _, newTrain in pairs(newTrains) do
						if not utils.contains(vehicles, newTrain) then
							table.insert(vehicles, newTrain)
						end
					end
				end
			end
		else
			if utils.contains(signals.trackedEntities, trackedTrain) then
				utils.removeFromTableByValue(signals.trackedEntities, trackedTrain)
			end
		end
	end

	if betterSignals.debugMode then
		for index, vehicle in pairs(vehicles) do
			local position = game.interface.getEntity(vehicle).position
			zone.setZoneCircle("tracked_vehicle" .. index, position, 5, {1,0,0,1})
		end
	end

	return vehicles
end

function betterSignals.getBlueprintByName(name)
	for _, entry in pairs(betterSignals.blueprints) do
		if entry:getName() == name then
			return entry
		end
	end
end

local function parseName(input)
    local result = {}
    -- Entferne Leerzeichen am Anfang und Ende des Strings
    input = input:match("^%s*(.-)%s*$")
    
    -- Iteriere über jedes Paar, das durch Kommas getrennt ist
    for pair in string.gmatch(input, '([^,]+)') do
        local key, value = pair:match("^%s*([^=]+)%s*=%s*(.+)%s*$")
        if key and value then
            -- Konvertiere "true" und "false" in booleans
            if value == "true" then
                value = 1
            elseif value == "false" then
                value = 2
            elseif tonumber(value) then
                value = tonumber(value)
            end
            result[key] = value
        end
    end
    return result
end

local function updateSignalDataForTrain(train)
	local move_path = utils.getComponentProtected(train, api.type.ComponentType.MOVE_PATH)
	local pathViewDistance = signals.viewDistance
	local segmentSpeed = math.huge

	local lastEvaluated = nil
	local paramOverride = {}

	if move_path and move_path.path then
		local pathStart = math.max((move_path.dyn.pathPos.edgeIndex - 6), 1)
		local pathEnd = math.min(#move_path.path.edges, pathStart + pathViewDistance)

		for pathIndex = pathEnd, pathStart, -1 do
			local currentEdge = move_path.path.edges[pathIndex]

			if currentEdge then
				segmentSpeed = math.min(segmentSpeed, utils.getEdgeSpeed(currentEdge.edgeId))

				local potentialSignalEntity = api.engine.system.signalSystem.getSignal(currentEdge.edgeId, currentEdge.dir).entity
				local signalComponent = utils.getComponentProtected(potentialSignalEntity,api.type.ComponentType.SIGNAL_LIST)

				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then
					local signal = signalComponent.signals[1]
					if (isSignal(signal, potentialSignalEntity)) then

						local registeredSignal = betterSignals.registeredSignals[getRegisteredKey(potentialSignalEntity)] or BetterSignal:new(potentialSignalEntity, nil, nil)

						if lastEvaluated then -- since the path is rolled up from end to start - the last Signal gets this signal registered as the previous one.
							lastEvaluated:setPreviousSignal(registeredSignal)
						end

						if paramOverride and paramOverride.speed then
							segmentSpeed = paramOverride.speed
						end

						registeredSignal:setSignalState(signal.state, segmentSpeed, paramOverride, lastEvaluated)
						table.insert(betterSignals.activeSignals, registeredSignal)
						segmentSpeed = math.huge

						paramOverride = {}
						lastEvaluated = registeredSignal
					elseif (signal.type == 0 or signal.type == 1) or (potentialSignalEntity and betterSignals.registeredSignals[getRegisteredKey(potentialSignalEntity)]) then -- preSignal
						local registeredSignal = betterSignals.registeredSignals[getRegisteredKey(potentialSignalEntity)] or BetterSignal:new(potentialSignalEntity, nil, nil)
						registeredSignal:setSignalState(signal.state, 0, {}, lastEvaluated)
						table.insert(betterSignals.activeSignals, registeredSignal)

					elseif signal.type == 2 then
						local name = utils.getComponentProtected(potentialSignalEntity, api.type.ComponentType.NAME)
						local values = parseName(string.gsub(name.name, " ", ""))

						paramOverride = values
					end
				elseif pathIndex == (#move_path.path.edges - move_path.path.endOffset) then -- Adding Trainstations
					local endSignal = BetterSignal:new(0000, nil, nil)
					endSignal:setSignalState(false, 0, paramOverride, nil)
					endSignal:setStation(true)

					if lastEvaluated then
						lastEvaluated:setPreviousSignal(endSignal)
					end

					table.insert(betterSignals.activeSignals, endSignal)

					segmentSpeed = math.huge
				end
			end
		end
	end
end

local function resetAllChangedSignals()
	for _, value in pairs(betterSignals.registeredSignals) do
		if value:isChanged() then
			local construction = value:getConstruction()
			if construction and construction.params then
				construction.params.signal_state = 0
				construction.params.previous_speed = 0

				utils.updateConstruction(construction, value:getConstructionId())
			end

			value:resetChangedFlag()
		end
	end
end

function betterSignals.updateSignalConstructions()
	for _, signal in pairs(betterSignals.registeredSignals) do
		signal:moveChangedValue()
	end

	for _, vehicle in pairs(getAllVisibleVehicles()) do
		updateSignalDataForTrain(vehicle)
	end

	for _, signal in pairs(betterSignals.activeSignals) do
		local currentSignal = signal or BetterSignal:new(nil,nil,nil)

		if currentSignal:isBetterSignal() then
			local signalConstruction = currentSignal:getConstruction()

			if signalConstruction and signalConstruction.params then
				local checksum = signalConstruction.params.checksum
				local newChecksum = currentSignal:getChecksum()

				signalConstruction.params.entity = currentSignal:getEntity()
				signalConstruction.params.signal_state = currentSignal:getSignalState()
				signalConstruction.params.signal_speed = currentSignal:getSignalSpeed()
				signalConstruction.params.following_signal = currentSignal:getAsFollowingSignal()
				signalConstruction.params.paramsOverride = currentSignal:getParamOverride()
				signalConstruction.params.previous_speed = currentSignal:getPreviousSpeed()
				signalConstruction.params.isStation = currentSignal:getIsStation()
				signalConstruction.params.changed = currentSignal:getChanged()

				if currentSignal:isAnimated() then
					signalConstruction.params.animationTimer = animationTimer.get()
				end
				
				currentSignal:setChangedFlag()
				-- signalConstruction.params.currentLine = signalPath.line

				if (checksum ~= newChecksum) or currentSignal:isAnimated() then
					signalConstruction.params.checksum = newChecksum
					utils.updateConstruction(signalConstruction, currentSignal:getConstructionId())
				end
			end
		end
	end

	betterSignals.activeSignals = {}
	resetAllChangedSignals()
end

function betterSignals.load(signals)
	for key, entry in pairs(signals) do
		local newSignal = BetterSignal:new(entry.entity, entry.construction, betterSignals.getBlueprintByName(entry.signalBlueprintName))
		betterSignals.registeredSignals[key] = newSignal
	end
end

function betterSignals.save()
	local save = {}
	if betterSignals.registeredSignals then
		for key, entry in pairs(betterSignals.registeredSignals) do
			if entry.__type == BetterSignal.__type then
				save[key] = entry:getAsSavedEntry()
			end
		end
	else
		print("BetterSignals - Registered Signals is 0")
		betterSignals.registeredSignals = {}
	end

	return save
end

return betterSignals