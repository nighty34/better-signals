local utils = require "nightfury/signals/utils"

local SIGNAL_UNIDIR = 0
local SIGNAL_ONEWAY = 1
local SIGNAL_WAYPOINT = 2

local SIGNAL_STATE_RED = 0
local SIGNAL_STATE_GREEN = 1

local pathEvaluator = {}

-- TODO Edge speeds

---We evaluate a train's path and create blocks protected by better signals
---@param vehicleId any
---@param lookAheadEdges any -- Max no of edges to look ahead on path before stopping
---@param signalsToEvaluate any -- No of signals to attempt to find on the path before stopping
---@param trainLocsEdgeEntityIds any -- edgeEntityIds of location of nearby trains
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return SignalPath
function pathEvaluator.evaluate(vehicleId,  lookAheadEdges, signalsToEvaluate, trainLocsEdgeEntityIds, main_signalObjects, main_signals)
	---@class SignalPath Represents a block of track protected by a signal. This will be passed to the signal construction
	---@field entity number Entity from api.engine.system.signalSystem.getSignal(). Should rename but keeping for backwards compatibility
	---@field signal_state number
	---@field signal_speed number
	---@field following_signal SignalPath
	---@field previous_speed number
	---@field checksum number
	---@field paramsOverride table
	---@field place_in_path number -- Which number it is from the train's position
	---@field dist_from_signal number -- Distance from the signal in number of edges

	local res = {}
	local signalPaths = {}

	local path = api.engine.getComponent(vehicleId, api.type.ComponentType.MOVE_PATH)
	-- ignore stopped trains 
	if path.dyn.speed == 0 or #path.path.edges == 1 or path.dyn.pathPos.edgeIndex < 0 then
		return res
	end

	---1st evaluation: We split path into blocks protected by signals/end station. Each block starts with a signal
	local blocksInPath = pathEvaluator.findBlocksInPath(path,lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals)
	local blockBehind = pathEvaluator.findBlockBackwards(path,lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals)
	local lastSignalState = SIGNAL_STATE_RED

	-- 2nd evaluation: We determine signal states for each main signal and prepare to return as SignalPath
	-- Order is important as we add information from previous and following signals to the current signal
	for i = 1, #blocksInPath, 1 do
		local nextSignalIsRedWaypoint = pathEvaluator.nextSignalIsRedWaypoint(blocksInPath, i)
		local signalPath = pathEvaluator.createSignalPath(blocksInPath, i, trainLocsEdgeEntityIds, signalPaths, nextSignalIsRedWaypoint);
		table.insert(signalPaths, signalPath)

		if signalPath.signal_state == SIGNAL_STATE_RED and (blocksInPath[i].hasSwitch or lastSignalState == SIGNAL_STATE_GREEN or nextSignalIsRedWaypoint) then
			-- We stop early on this red because no point in evaluating beyond the switch or we've hit a red we can't safely evaluate after
			-- Note we can't be efficent and just stop when we hit a red as the game tells us the train position with a lag from what is displayed on screen: so we may have multiple red signals before we get our first green signal
			utils.debugPrint("stopping early")
			break
		end

		lastSignalState = signalPath.signal_state
	end

		-- Evaluate signal behind train first so we can add info about it to the first main signal
	if blockBehind and #blocksInPath > 0 then
		-- The presignals on the block behind the train are actually for the first signal, copy over presignals to first block if it exists
		for key, value in pairs(blockBehind.presignalsEntityIds) do
			table.insert(blocksInPath[1].presignalsEntityIds, value)
		end
		signalPaths[1].previous_speed = blockBehind.minSpeed
	end


	-- 3rd evaluation create presignals between the main signals. We do this after the 2nd evaluation because 2nd sets following_signal, and previous_speed which we need
	-- A presignal is just a copy of the main signal it's for
	for i = 1, #signalPaths, 1 do
		local signalPath = signalPaths[i]
		local presignalsTable = blocksInPath[i].presignalsEntityIds

		-- Create presignals
		for _, entityId in pairs(presignalsTable) do
			local preSignalTable = utils.deepCopy(signalPath)
			preSignalTable.entity = entityId

			utils.debugPrint("Pre signal at ", blocksInPath[i].edgeEntityIdOn, preSignalTable.entity, preSignalTable.signal_state, preSignalTable.signal_speed, preSignalTable.hasSwitch, utils.dictToString(signalPath.paramsOverride))
			table.insert(res, preSignalTable)
		end

		-- Don't forget to add in the main signal
		utils.debugPrint("Main signal at ", blocksInPath[i].edgeEntityIdOn, signalPath.entity, signalPath.signal_state, signalPath.signal_speed, blocksInPath[i].hasSwitch, utils.dictToString(signalPath.paramsOverride), signalPath.place_in_path)
		table.insert(res, signalPath)
	end

	-- We now add in the signal behind the train as well (if it's not green)
	if blockBehind and #signalPaths > 0 then
		local behindTrainSignalPath = pathEvaluator.createSignalPathForBlockBehindTrain(blockBehind, signalPaths[1])
		if behindTrainSignalPath.signal_state == SIGNAL_STATE_RED then
			utils.debugPrint("Adding Signal behind train to start of path ", blockBehind.edgeEntityIdOn, behindTrainSignalPath.entity, behindTrainSignalPath.signal_state, behindTrainSignalPath.signal_speed, blockBehind.hasSwitch, utils.dictToString(behindTrainSignalPath.paramsOverride))
			table.insert(res, 1, behindTrainSignalPath)
		end
	end

	-- 4th evaluation: calc checksums. We do in reverse order to include following signal in checksum
	utils.addChecksumToSignals(res)

	return res
end

---Creates SignalPath object for the block behind the train
---@param signalBehind BlockInfo
---@param firstSignalInPath SignalPath
---@return SignalPath
function pathEvaluator.createSignalPathForBlockBehindTrain(signalBehind, firstSignalInPath)
		local signalState = SIGNAL_STATE_RED
		if signalBehind.isStation == false then
			signalState = signalBehind.signalComp.signals[1].state
		end

		local signalPath = {}
		signalPath.entity = signalBehind.signalListEntityId
		signalPath.signal_state = signalState
		signalPath.signal_speed = signalBehind.minSpeed
		signalPath.paramsOverride = signalBehind.paramsOverride
		signalPath.place_in_path = 0
		signalPath.dist_from_signal = 0
		signalPath.following_signal = firstSignalInPath
		return signalPath
end

---Creates SignalPath object and adds info from previous signal if exists
---@param blocksInPath [BlockInfo]
---@param idx any
---@param trainLocsEdgeEntityIds any
---@param signalPaths [SignalPath] -- signal paths created so far, used to get info about previous signal
---@param nextSignalIsRedWaypoint boolean
---@return SignalPath
function pathEvaluator.createSignalPath(blocksInPath, idx, trainLocsEdgeEntityIds, signalPaths, nextSignalIsRedWaypoint)
		local signalAndBlock = blocksInPath[idx]

		local signalState = SIGNAL_STATE_RED
		if signalAndBlock.isStation then
			signalState = SIGNAL_STATE_RED
		elseif pathEvaluator.canRecalcSignalState(idx==#blocksInPath, nextSignalIsRedWaypoint, signalAndBlock) then
			signalState = pathEvaluator.recalcSignalState(signalAndBlock, trainLocsEdgeEntityIds)
		else
			signalState = signalAndBlock.signalComp.signals[1].state
		end

		local signalPath = {}
		signalPath.entity = signalAndBlock.signalListEntityId
		signalPath.signal_state = signalState
		signalPath.signal_speed = signalAndBlock.minSpeed
		signalPath.paramsOverride = signalAndBlock.paramsOverride
		signalPath.place_in_path = idx
		signalPath.dist_from_signal = signalAndBlock.edgeDistCount

		if #signalPaths > 0 then
			local lastSignal = signalPaths[#signalPaths]
			signalPath.previous_speed = lastSignal.signal_speed
			lastSignal.following_signal = signalPath
		end
		return signalPath
end

---First evaluation: We convert path into blocks protected by signals/end station
---@param path any
---@param lookAheadEdges any
---@param signalsToEvaluate any
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return [BlockInfo]
function pathEvaluator.findBlocksInPath(path, lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals)
	---@class BlockInfo Represents a block of track with a signal or a station
	---@field edges table<number> nil when isStation is true
	---@field signalComp any
	---@field signalListEntityId number -- The entity of the SignalList 
	---@field hasSwitch boolean
	---@field isStation boolean
	---@field edgeEntityIdOn number
	---@field minSpeed number
	---@field presignalsEntityIds [string]
	---@field paramsOverride table
	---@field edgeDistCount number

	local blocks = {}
	local presignalsForNextBlock = {}

	if path and path.path and #path.path.edges > 2 then
		local pathStart = math.max(path.dyn.pathPos.edgeIndex, 1)
		local pathEnd = math.min(#path.path.edges, pathStart + lookAheadEdges)
		local pathIndex = pathStart
		local shouldContinueSearch = true

		while shouldContinueSearch do
			local currentEdge = path.path.edges[pathIndex]
			local edgeEntityId = currentEdge.edgeId.entity

			local transportNetwork = utils.getComponentProtected(edgeEntityId, api.type.ComponentType.TRANSPORT_NETWORK)
			if transportNetwork == nil then
				utils.debugPrint("Unexpected exit of pathEvaluator.findSignalsInPath as transport network doesn't exist")
				return blocks
			end

			local speed = math.floor(utils.getEdgeSpeed(currentEdge.edgeId, transportNetwork))

			if #blocks > 0 then
				local lastBlock = blocks[#blocks]
				lastBlock.minSpeed = math.min(lastBlock.minSpeed, speed)
				lastBlock.hasSwitch = lastBlock.hasSwitch or pathEvaluator.isAfterSwitch(transportNetwork)
			end

			-- FYI sometimes the edgeId is duplicated in the path (seems when there is a signal on the edge). dir is needed to identify which one has signal
			local potentialSignal = api.engine.system.signalSystem.getSignal(currentEdge.edgeId, currentEdge.dir)
			if pathEvaluator.isStationOrPathEnd(pathIndex, path, pathEnd) then
				-- Adding Trainstations/End of path
				local stopInfo = {
					edges = {},
					signalListEntityId = 0000,
					hasSwitch = false,
					isStation = true,
					edgeEntityIdOn = edgeEntityId,
					minSpeed = 0,
					presignalsEntityIds = presignalsForNextBlock,
					edgeDistCount = pathIndex - pathStart
				}
				table.insert(blocks, stopInfo)
			elseif potentialSignal and potentialSignal.entity and potentialSignal.entity ~= -1 then
				local signalComponent = api.engine.getComponent(potentialSignal.entity, api.type.ComponentType.SIGNAL_LIST)
				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then
					local signal = signalComponent.signals[1]

					if pathEvaluator.isMainSignal(signal, potentialSignal.entity, main_signalObjects, main_signals) then
						local signalInfo = {
							edges = {},
							signalComp = signalComponent,
							signalListEntityId = potentialSignal.entity,
							hasSwitch = false,
							isStation = false,
							edgeEntityIdOn = edgeEntityId,
							minSpeed = speed,
							presignalsEntityIds = presignalsForNextBlock,
							edgeDistCount = pathIndex - pathStart
						}
						table.insert(blocks, signalInfo)
						presignalsForNextBlock = {}
					elseif pathEvaluator.isASignal(signal, potentialSignal.entity, main_signalObjects) then
						-- Presignal/Hybrid in presignal state
						table.insert(presignalsForNextBlock, potentialSignal.entity)
					elseif signal.type == SIGNAL_WAYPOINT then
						-- Params override
						local name = utils.getComponentProtected(potentialSignal.entity, 63)
						local values = pathEvaluator.parseName(string.gsub(name.name, " ", ""))
						
						if #blocks > 0 then
							blocks[#blocks].paramsOverride = values
							if values.speed then
								blocks[#blocks].minSpeed = values.speed
							end
						end
					end
				end
			end

			-- register edge to last signal
			if #blocks > 0 then
				table.insert(blocks[#blocks].edges, edgeEntityId)
			end

			-- reset loop
			shouldContinueSearch = pathEvaluator.shouldContinueSearching(blocks, signalsToEvaluate, pathIndex, pathEnd, path)
			pathIndex = pathIndex + 1
		end
	end

	return blocks
end

---Evaluate the state of a signal. Behind the train
---@param path any
---@param lookAheadEdges any
---@param signalsToEvaluate any
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return BlockInfo | nil
function pathEvaluator.findBlockBackwards(path, lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals)

	if path and path.path and #path.path.edges > 2 then
		-- Going backwards from end to start

		local startPoint = math.max(path.dyn.pathPos.edgeIndex -1, 1)
		local stopPoint = math.max(1, startPoint - lookAheadEdges /4)
		local pathIndex = startPoint
		local blockMinSpeed = 600
		local presignalsForNextBlock = {}
		local paramsOverride = nil
		local speedOverriden = false
		while true do
			local currentEdge = path.path.edges[pathIndex]
			local edgeEntityId = currentEdge.edgeId.entity

			local transportNetwork = utils.getComponentProtected(edgeEntityId, api.type.ComponentType.TRANSPORT_NETWORK)
			if transportNetwork == nil then
				utils.debugPrint("Unexpected exit of pathEvaluator.findSignalsInPathBackwards as transport network doesn't exist")
				return nil
			end

			if not speedOverriden then
				local speed = math.floor(utils.getEdgeSpeed(currentEdge.edgeId, transportNetwork))
				blockMinSpeed = math.min(blockMinSpeed, speed)
			end
			local potentialSignal = api.engine.system.signalSystem.getSignal(currentEdge.edgeId, currentEdge.dir)

			if pathIndex == stopPoint then
				-- Adding Trainstations/End of path
				return {
					edges = {},
					signalListEntityId = 0000,
					hasSwitch = false,
					isStation = true,
					edgeEntityIdOn = edgeEntityId,
					minSpeed = blockMinSpeed,
					presignalsEntityIds = presignalsForNextBlock, -- Actually for the next block...
					paramsOverride = paramsOverride,
					edgeDistCount = 0
				}
			elseif potentialSignal and potentialSignal.entity and potentialSignal.entity ~= -1 then
				local signalComponent = api.engine.getComponent(potentialSignal.entity, api.type.ComponentType.SIGNAL_LIST)
				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then
					local signal = signalComponent.signals[1]

					if pathEvaluator.isMainSignal(signal, potentialSignal.entity, main_signalObjects, main_signals) then
						return {
							edges = {}, -- Don't need to set edges
							signalComp = signalComponent,
							signalListEntityId = potentialSignal.entity,
							hasSwitch = false,
							isStation = false,
							edgeEntityIdOn = edgeEntityId,
							minSpeed = blockMinSpeed,
							presignalsEntityIds = presignalsForNextBlock, -- Actually for the next block...
							paramsOverride = paramsOverride,
							edgeDistCount = 0
						}
					elseif pathEvaluator.isASignal(signal, potentialSignal.entity, main_signalObjects) then
						-- Presignal/Hybrid in presignal state
						table.insert(presignalsForNextBlock, potentialSignal.entity)
					elseif signal.type == SIGNAL_WAYPOINT then
						-- Params override
						local name = utils.getComponentProtected(potentialSignal.entity, 63)
						local values = pathEvaluator.parseName(string.gsub(name.name, " ", ""))

						if values.speed then
							speedOverriden = true
							blockMinSpeed = values.speed
						end
					end
				end
			end

			pathIndex = pathIndex - 1
		end
	end

	return nil
end

function pathEvaluator.isStationOrPathEnd(pathIndex, path, pathEnd)
	return pathIndex == (#path.path.edges - path.path.endOffset) or pathIndex >= pathEnd
end

function pathEvaluator.shouldContinueSearching(foundBlocks, signalsToEvaluate, pathIndex, pathEnd, path)
	if pathEvaluator.isStationOrPathEnd(pathIndex, path, pathEnd) then
		utils.debugPrint("stopping: path end/Station")
		return false
	end

	if #foundBlocks >= signalsToEvaluate then
		-- We've found enough signals to consider. But if last signal is green keep going till we get a red or a station/end
		local lastBlock = foundBlocks[#foundBlocks]
		if lastBlock.isStation == false and lastBlock.signalComp.signals[1].state == SIGNAL_STATE_GREEN then
			utils.debugPrint("keep going: Green signal")
			return true
		else
			utils.debugPrint("stopping: enough signals")
			return false
		end
	end

	return true
end

---Gets if edge is a branch after a switch
---taken from WernerK's splitter mod
---@param transportNetwork table api.type.ComponentType.TRANSPORT_NETWORK
---@return boolean
function pathEvaluator.isAfterSwitch(transportNetwork)
	if transportNetwork then
		local lanes = transportNetwork.edges
		local firstIndex = lanes[1].conns[1].index
		local lastIndex = lanes[#lanes].conns[2].index
		return firstIndex > 0 and firstIndex < 5
		or lastIndex > 0 and lastIndex < 5
		-- >= 5 would be level crossing
	end
	return false
end

---The game has signals be default as red. This attempts to return more signals as green
---@param signalAndBlock BlockInfo
---@param trainLocsEdgeEntityIds any -- edgeEntityIds of location of nearby trains
---@return number -- signal state. 1 is green, 0 is red
function pathEvaluator.recalcSignalState(signalAndBlock, trainLocsEdgeEntityIds)
	local signal = signalAndBlock.signalComp.signals[1]
	if signal.state == SIGNAL_STATE_GREEN then
		return signal.state
	end

	-- Red signal. Let's see if it's safe to treat as green
	local hasTrainInPath = pathEvaluator.hasTrainInPath(signalAndBlock.edges, trainLocsEdgeEntityIds)

	if not hasTrainInPath then
		utils.debugPrint("Treat red signal as green "  .. signalAndBlock.signalListEntityId)
		return SIGNAL_STATE_GREEN
	else
		return signal.state
	end
end

function pathEvaluator.canRecalcSignalState(isLast, nextSignalIsRedWaypoint, signalAndBlock)
	if isLast or signalAndBlock.hasSwitch or nextSignalIsRedWaypoint or signalAndBlock.isStation then
		return false
	end

	return true
end

function pathEvaluator.nextSignalIsRedWaypoint(signalsInPath, curIdx)
	if curIdx >= #signalsInPath then
		return false
	end

	local nextSignalAndBlock = signalsInPath[curIdx+1]
	if nextSignalAndBlock.isStation == true then
		return false
	end

	local nextSignal = nextSignalAndBlock.signalComp.signals[1]
	return nextSignal.type == SIGNAL_WAYPOINT and nextSignal.state == SIGNAL_STATE_RED
end

function pathEvaluator.hasTrainInPath(edgesTable, trainLocsEdgeIds)
	for _, edgeId in pairs(edgesTable) do
		if trainLocsEdgeIds[edgeId] ~= nil then
			-- Signal is protecting a train. Stop
			return true
		end
	end
	return false
end

function pathEvaluator.isMainSignal(signal, signalListEntityId, main_signalObjects, main_signals)
	if pathEvaluator.isHybridSignalInPreSignalState(signalListEntityId, main_signalObjects, main_signals) then
		return false
	end

	return pathEvaluator.isASignal(signal, signalListEntityId, main_signalObjects)
end

function pathEvaluator.isHybridSignalInPreSignalState(signalListEntityId, main_signalObjects,main_signals)
	local signalKey = "signal" .. signalListEntityId
	local signalObj = main_signalObjects[signalKey]
	if signalObj then
		local signalType = main_signals[signalObj.signalType]
		local construction = utils.getComponentProtected(signalObj.construction, api.type.ComponentType.CONSTRUCTION)

		if signalType.type == "hybrid" and construction then
			local presignalConditionMatch = construction.params[signalType['preSignalTriggerKey']] == signalType['preSignalTriggerValue']
			if presignalConditionMatch then
				return true
			end
		end
	end
	return false
end

function pathEvaluator.isASignal(signal, signalListEntityId, main_signalObjects)
	return signal.type == SIGNAL_UNIDIR or signal.type == SIGNAL_ONEWAY or (signal.type == SIGNAL_WAYPOINT and main_signalObjects["signal" .. signalListEntityId])
end

function pathEvaluator.parseName(input)
    local result = {}
    -- Entferne Leerzeichen am Anfang und Ende des Strings/ Remove spaces at the end and the start of the string
    input = input:match("^%s*(.-)%s*$")

    -- Iteriere über jedes Paar, das durch Kommas getrennt ist/ iterate over every pair seperated by ,
    for pair in string.gmatch(input, '([^,]+)') do
        local key, value = pair:match("^%s*([^=]+)%s*=%s*(.+)%s*$")
        if key and value then
            -- Konvertiere "true" und "false" in booleans/ convert true and false booloeans
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

		-- Bugfix if speed is not a number things break later
		if result.speed and type(result.speed) ~= "number" then
			result.speed = nil
		end

    return result
end

return pathEvaluator