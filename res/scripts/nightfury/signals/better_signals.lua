local signals = require "nightfury/signals/main"
local utils = require "nightfury/signals/utils"
local SignalBluePrint = require "nightfury/signals/model/signal_blueprint"
local BetterSignal = require "nightfury/signals/model/better_signal"
local zone = require "nightfury/signals/zone"
local animationTimer = require "nightfury/signals/utils/timer"

local betterSignals = {}
local EMPTY_SIGNAL = BetterSignal:new(0000, nil, nil)

EMPTY_SIGNAL:setSignalState(0,0, {}, nil)

animationTimer.start()

betterSignals.debugMode = false

betterSignals.registeredSignals = {}
betterSignals.activeSignals = {}
betterSignals.blueprints = {}

local function getRegisteredKey(signalEntity)
	return "signal" .. signalEntity
end

function betterSignals.createSignal(signal_entity, construction, signalBlueprint)
	if signalBlueprint and (signalBlueprint.__type ~= SignalBluePrint.__type) then
		print("Better Signals - Not a SignalBlueprint")
		return
	end

	betterSignals.registeredSignals[getRegisteredKey(signal_entity)] = BetterSignal:new(signal_entity, construction, signalBlueprint)
	print("Better Signals - Registered new Signal")
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
	local better_signal = betterSignals.registeredSignals[getRegisteredKey(potentialSignal)]
	if better_signal then
		local signalBluePrint = better_signal:getBluePrint()

		if signalBluePrint then
			local signalType = string.lower(signalBluePrint:getType())
			if signalType == "main" then
				return true
			elseif signalType == "pre" then
				return false
			elseif signalType == "hybrid" then
				local construction = better_signal:getConstruction()

				if construction and construction.params then
					return not (construction.params[signalBluePrint:getPreSignalTiggerKey()] == signalBluePrint:getPreSignalTriggerValue())
				end
			end
		end
	end

	return (signal.type == 0 or signal.type == 1)
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
						if not vehicles[newTrain] then
							table.insert(vehicles, newTrain)
						end
					end
				end
			end
		else
			if signals.trackedEntities[trackedTrain] then
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
	return betterSignals.blueprints[name]
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

	local lastEvaluated = EMPTY_SIGNAL
	local paramOverride = {}

	if move_path and move_path.path then
		local pathStart = math.max((move_path.dyn.pathPos.edgeIndex - 6), 1)
		local pathEnd = math.min(#move_path.path.edges, pathStart + pathViewDistance)

		local wasLastRed = true

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

						if wasLastRed and signal.state == 1 then
							local emptySignal = EMPTY_SIGNAL
							lastEvaluated:setNextSignal(emptySignal)
						end

						if signal.state == 1 then
							wasLastRed = false
						end 
					elseif (potentialSignalEntity and betterSignals.registeredSignals[getRegisteredKey(potentialSignalEntity)]) then -- preSignal
						local registeredSignal = betterSignals.registeredSignals[getRegisteredKey(potentialSignalEntity)] or EMPTY_SIGNAL
						registeredSignal:setSignalState(signal.state, 0, {}, lastEvaluated)
						registeredSignal:setPreSignal(true)
						
						if lastEvaluated then
							lastEvaluated:addPreSignal(registeredSignal)
						end

					elseif signal.type == 2 then
						local name = utils.getComponentProtected(potentialSignalEntity, api.type.ComponentType.NAME)
						local values = parseName(string.gsub(name.name, " ", ""))

						paramOverride = values
					end
				elseif pathIndex == (#move_path.path.edges - move_path.path.endOffset) then -- Adding Trainstations
					local endSignal = BetterSignal:new(0000, nil, nil)
					endSignal:setSignalState(0, 0, paramOverride, nil)
					endSignal:setStation(true)

					lastEvaluated = endSignal

					segmentSpeed = math.huge
				end
			end
		end
	end
end

local function updatePreSignals(preSignals, better_signal)
	for _, preSignal in pairs(preSignals) do
		local construction = preSignal:getConstruction()

		if construction and construction.params then
			construction.params.isPreSignal = true
			construction.params.entity = better_signal:getEntity()
			construction.params.signal_state = better_signal:getSignalState()
			construction.params.signal_speed = better_signal:getSignalSpeed()
			construction.params.following_signal = better_signal:getAsFollowingSignal(false)
			construction.params.paramsOverride = better_signal:getParamOverride()
			construction.params.previous_speed = better_signal:getPreviousSpeed()
			construction.params.isStation = better_signal:getIsStation()
			construction.params.changed = better_signal:getChanged()

			utils.updateConstruction(construction, preSignal:getConstructionId())
		end
	end
end

local function resetAllChangedSignals()
	for _, value in pairs(betterSignals.registeredSignals) do
		if value:isChanged() then
			local construction = value:getConstruction()

			if construction and construction.params then
				value:resetState()

				construction.params.signal_state = 0
				construction.params.previous_speed = 0

				utils.updateConstruction(construction, value:getConstructionId())

				updatePreSignals(value:getPreSignals(), value)
			end

			value:resetChangedFlag()
		end
	end
end

function betterSignals.updateSignalConstructions()
	local statTimer = require "nightfury/signals/utils/timer"

	for _, signal in pairs(betterSignals.registeredSignals) do
		signal:moveChangedValue()
	end

	statTimer.start()
	for _, vehicle in pairs(getAllVisibleVehicles()) do
		updateSignalDataForTrain(vehicle)
	end

	for _, signal in pairs(betterSignals.activeSignals) do
		local currentSignal = signal or EMPTY_SIGNAL

		if currentSignal:isBetterSignal() then
			local signalConstruction = currentSignal:getConstruction()

			if signalConstruction and signalConstruction.params then
				local checksum = signalConstruction.params.checksum
				local newChecksum = currentSignal:getChecksum()

				signalConstruction.params.entity = currentSignal:getEntity()
				signalConstruction.params.signal_state = currentSignal:getSignalState()
				signalConstruction.params.signal_speed = currentSignal:getSignalSpeed()
				signalConstruction.params.following_signal = currentSignal:getAsFollowingSignal(false)
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
					updatePreSignals(currentSignal:getPreSignals(), currentSignal)
				end
			end
		end
	end
	
	betterSignals.activeSignals = {}
	resetAllChangedSignals()
end

function betterSignals.load(signals)
	for key, entry in pairs(signals) do
		local bluePrintName = entry.signalBlueprintName
		if not bluePrintName then
			local entity = game.interface.getEntity(entry.construction)
			if entity and entity.fileName then
				bluePrintName = string.match(entity.fileName, "([^/]+)%.con$")
				print("Better Signals - Trying to convert signal " .. key .. " to blueprint: " .. bluePrintName .. "based on construction name")
			end
		end

		local newSignal = BetterSignal:new(entry.entity, entry.construction, betterSignals.getBlueprintByName(bluePrintName))
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
		print("Better Signals - Registered Signals is 0")
		betterSignals.registeredSignals = {}
	end

	return save
end

return betterSignals