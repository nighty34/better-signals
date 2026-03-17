local trainHelper = require "nightfury/signals/mainupdate/trainHelper"
local pathEvaluator = require "nightfury/signals/mainupdate/pathEvaluator"
local utils = require "nightfury/signals/utils"

local config_lookAheadEdges = 100
local config_cameraRadiusSignalVisibleAt = 500 -- Can't see signal when camera radius is > 500


-- 3 states: None, Changed, WasChanged
local BETTER_SIGNAL_NO_CHANGE = 0
local BETTER_SIGNAL_CHANGED = 1
local BETTER_SIGNAL_WAS_CHANGED = 2


local signals = {}
signals.signals = {}
-- Table holds all placed Signals
signals.signalObjects = {}
signals.viewDistance = 2000
signals.targetNoToEval = 4
signals.pos = {0,0} -- Updated by event
signals.posRadius = 1000 -- Updated by event
signals.cockpitMode = false
signals.cockpitTrainEntityId = nil
signals.cockpitModeAtTime = nil -- We lock the cockpit mode for 2 seconds to prevent a race condition 
-- where a late arriving camera move makes us think we're out of cockpitMode

----------------------
--GUI Location Update!
--In cockpitMode the location Gui camera doesn't change but we can use the location of the train
--TODO: Maybe move this section to it's own file?

---Set's gui's camera position. Updated by event.
---We detect the game has left cockpitMode when the location starts updating again: the camera zooms to and tracks the train.
---When entering cockpit mode when the camera is following a train there is a race condition so we only allow
---detecting exiting cockpitMode after 2 seconds
---@param pos table<number> x,y position
---@param radius number
function signals.updateGuiCameraPos(pos, radius)
	if signals.cockpitMode then
		if pos[1] == signals.pos[1] and pos[2] == signals.pos[2] then
			-- No position change still in cockpitMode
			return
		elseif signals.cockpitModeAtTime ~= nil then
			-- We wait 2 seconds before we start detecting exit cockpitMode
			if os.clock() - signals.cockpitModeAtTime > 2  then
				signals.cockpitModeAtTime = nil
			end
		else
			-- The location is updating so must hae exited cockpitMode
			signals.cockpitMode = false
			signals.cockpitTrainEntityId = nil
		end
	end

	signals.pos = pos
	signals.posRadius = radius
end
function signals.setCockpitMode(vehicleId)
	if trainHelper.isTrain(vehicleId)  then
		signals.cockpitMode = true
		signals.cockpitTrainEntityId = vehicleId
		signals.cockpitModeAtTime = os.clock()
	end
end
function signals.getPosition()
	if signals.cockpitMode and signals.cockpitTrainEntityId then
		local trainPos = trainHelper.getTrainPos(signals.cockpitTrainEntityId)
		if trainPos then
			return trainPos
		end
	end
	return signals.pos
end
----------------------

--- Function checks move_path of all the trains
--- If a signal is found it's current state is checked
--- after that the signal will be changed accordingly
function signals.updateSignals()
	if signals.posRadius > config_cameraRadiusSignalVisibleAt and signals.cockpitMode == false then
		return
	end

	utils.debugPrint("----------")
	utils.debugPrint("Better Signals ", signals.viewDistance, signals.targetNoToEval)
	utils.debugPrint("----------")
	local start_time = os.clock()

	local pos = signals.getPosition()
	local trains = trainHelper.getTrainsToEvaluate(pos, signals.viewDistance)
	signals.resetAll()

	local trainLocsEdgeIds = trainHelper.computeTrainLocs(trains)

	local signalsToBeUpdated = signals.computeSignalPaths(trains, trainLocsEdgeIds)

	signals.updateConstructions(signalsToBeUpdated)

	signals.throwSignalToRed()
	utils.debugPrint(string.format("updateSignals. Elapsed time: %.4f", os.clock() - start_time))
end

function signals.computeSignalPaths(trains, trainLocsEdgeIds)
	local signalsToBeUpdated = {}

	-- Compute signals in path of each train
	for vehicleId, vehComp in pairs(trains) do
		utils.debugPrintVehicle(vehicleId)

		local lineName = trainHelper.getLineNameOfVehicle(vehComp)
		local signalsToEvaluate = signals.targetNoToEval

		local signalPaths = pathEvaluator.evaluate(vehicleId, config_lookAheadEdges, signalsToEvaluate, trainLocsEdgeIds, signals.signalObjects, signals.signals)

		for _, signalPath in ipairs(signalPaths) do
			signalPath.lineName = lineName.name
			signals.recordSignalToBeUpdated(signalPath, signalsToBeUpdated)
		end
	end
	return signalsToBeUpdated
end

function signals.recordSignalToBeUpdated(signalPath, signalsToBeUpdated)
	local signalKey = "signal" .. signalPath.entity
	if signalsToBeUpdated[signalKey] then
		-- two trains want to update the same signal. Prioritise whichever train is closest to signal

		local existingPath = signalsToBeUpdated[signalKey]
		if existingPath.placeInPath > signalPath.placeInPath then
			utils.debugPrint("existing replace", signalPath.entity)
			signalsToBeUpdated[signalKey] = signalPath
		elseif existingPath.placeInPath == signalPath.placeInPath then
			-- when both have same place use whichever has green
			utils.debugPrint("2 trains with same place in", signalPath.entity)
			if existingPath.signal_state < signalPath.signal_state then
				utils.debugPrint("existing replace", signalPath.entity)
				signalsToBeUpdated[signalKey] = signalPath
			end
		else
			utils.debugPrint("existing remains")
		end
	else
		signalsToBeUpdated[signalKey] = signalPath
	end
end

function signals.updateConstructions(signalsToBeUpdated)
	for signalKey, signalPath in pairs(signalsToBeUpdated) do
		local tableEntry = signals.signalObjects[signalKey]
		if tableEntry then
			local newCheckSum = 0
			for _, betterSignal in pairs(tableEntry.signals) do
				signals.signalObjects[signalKey].changed = BETTER_SIGNAL_CHANGED
				local conSignal = betterSignal.construction

				if conSignal then
					local oldConstruction = game.interface.getEntity(conSignal)
					if oldConstruction and oldConstruction.params then
						oldConstruction.params.previous_speed = signalPath.previous_speed
						oldConstruction.params.signal_state = signalPath.signal_state
						oldConstruction.params.signal_speed = signalPath.signal_speed
						oldConstruction.params.following_signal = signalPath.following_signal
						oldConstruction.params.paramsOverride = signalPath.paramsOverride
						oldConstruction.params.showSpeedChange = true

						if signalPath.lineName ~= "ERROR" then
							oldConstruction.params.currentLine = signalPath.lineName
						end

						newCheckSum = signalPath.checksum

						if (not signals.signalObjects[signalKey].checksum) or (newCheckSum ~= signals.signalObjects[signalKey].checksum) then
							utils.updateConstruction(oldConstruction, conSignal)
							
							utils.debugPrint("utils.updateConstruction for ", signalPath.entity, newCheckSum, signals.signalObjects[signalKey].checksum, signalPath.signal_state )
						end
					else
						print("Couldn't access params")
					end
				end
			end

			signals.signalObjects[signalKey].checksum = newCheckSum
		end
	end
end

function signals.resetAll()
    for _, value in pairs(signals.signalObjects) do
        if value.changed then
            value.changed = value.changed * 2
        end
    end
end

function signals.throwSignalToRed()
	for signalkey, value in pairs(signals.signalObjects) do
		if value.changed == BETTER_SIGNAL_WAS_CHANGED then
			for _, signal in pairs(value.signals) do
				local oldConstruction = game.interface.getEntity(signal.construction)
				if oldConstruction then
					utils.debugPrint("Throw to red ", signalkey, value.checksum)

					oldConstruction.params.signal_state = 0
					oldConstruction.params.previous_speed = nil
					utils.updateConstruction(oldConstruction, signal.construction)
				end
				value.changed = BETTER_SIGNAL_NO_CHANGE
				value.checksum = 0
			end
		end
	end
end

-- Registers new signal
-- @param signal signal entityid
-- @param construct construction entityid
function signals.createSignal(signal, construct, signalType, isAnimated)
	local signalKey = "signal" .. signal

	if not signals.signalObjects[signalKey] then
		signals.signalObjects[signalKey] = {}
		signals.signalObjects[signalKey].signals = {}
	end

	signals.signalObjects[signalKey].changed = BETTER_SIGNAL_NO_CHANGE
	signals.signalObjects[signalKey].signalType = signalType
	signals.signalObjects[signalKey].construction = construct

	local newSignal = {}

	newSignal.construction = construct
	newSignal.isAnimated = isAnimated

	table.insert(signals.signalObjects[signalKey].signals, newSignal)
end

function signals.removeSignalBySignal(signal)
	signals.signalObjects["signal" .. signal] = nil
end

function signals.removeSignalByConstruction(construction)
	for _, value in pairs(signals.signalObjects) do
		for index, signal in ipairs(value.signals) do
			if signal.construction == construction then
				table.remove(value.signals, index)
				print("Removed Signal " .. construction .. " at index: " .. index)
				return
			end
		end
	end
end

function signals.removeTunnel(signalConstructionId)
	local oldConstruction = game.interface.getEntity(signalConstructionId)
	if oldConstruction then
		oldConstruction.params.better_signals_tunnel_helper = 0

		utils.updateConstruction(oldConstruction, signalConstructionId)
	end
end

function signals.save()
	return signals.signalObjects
end


function signals.load(state)
	if state then
		signals.signalObjects = state
	end
end

return signals