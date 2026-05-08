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
	---@field showSpeedChange boolean -- Whether to show the speed change on the signal construction
	---@field is_station boolean -- Whether this signal path is actually a station
	---@field construction_params [table] -- Construction params for the signal constructions attached to this signal
	---@field gateway_next_main_signal SignalPath -- Reference to the next main signal for shunting signals
	
	local res = {}

	local path = api.engine.getComponent(vehicleId, api.type.ComponentType.MOVE_PATH)
	-- ignore stopped trains 
	if path.dyn.speed == 0 or #path.path.edges == 1 or path.dyn.pathPos.edgeIndex < 0 then
		return res
	end

	local function processPass(targetFuncType)
		local signalPaths = {}
		---1st evaluation: We split path into blocks protected by signals/end station. Each block starts with a signal
		local blocksInPath = pathEvaluator.findBlocksInPath(path,lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals, targetFuncType)
		local blockBehind = pathEvaluator.findBlockBackwards(path,lookAheadEdges, main_signalObjects, main_signals, targetFuncType)
		local lastSignalState = SIGNAL_STATE_RED

		-- 2nd evaluation: We determine signal states for each main signal and prepare to return as SignalPath
		for i = 1, #blocksInPath, 1 do
			local nextSignalIsRedWaypoint = pathEvaluator.nextSignalIsRedWaypoint(blocksInPath, i)
			local signalPath = pathEvaluator.createSignalPath(blocksInPath, i, trainLocsEdgeEntityIds, signalPaths, nextSignalIsRedWaypoint, main_signalObjects)
			table.insert(signalPaths, signalPath)

			if signalPath.signal_state == SIGNAL_STATE_RED and (blocksInPath[i].hasSwitch or lastSignalState == SIGNAL_STATE_GREEN or nextSignalIsRedWaypoint) then
				utils.debugPrint("stopping early for " .. targetFuncType)
				break
			end

			lastSignalState = signalPath.signal_state
		end

		-- Evaluate signal behind train first so we can add info about it to the first main signal
		if blockBehind and #blocksInPath > 0 then
			for key, value in pairs(blockBehind.presignalsEntityIds) do
				table.insert(blocksInPath[1].presignalsEntityIds, value)
			end
			signalPaths[1].previous_speed = blockBehind.minSpeed
		end

		-- 3rd evaluation create presignals between the main signals.
		local passRes = {}
		for i = 1, #signalPaths, 1 do
			local signalPath = signalPaths[i]
			local presignalsTable = blocksInPath[i].presignalsEntityIds

			for _, entityId in pairs(presignalsTable) do
				local preSignalTable = utils.deepCopy(signalPath)
				preSignalTable.entity = entityId
				table.insert(passRes, preSignalTable)
			end
			table.insert(passRes, signalPath)
		end

		if blockBehind and #signalPaths > 0 then
			local behindTrainSignalPath = pathEvaluator.createSignalPathForBlockBehindTrain(blockBehind, signalPaths[1])
			if behindTrainSignalPath.signal_state == SIGNAL_STATE_RED then
				table.insert(passRes, 1, behindTrainSignalPath)
			end
		end

		return passRes, signalPaths
	end

	local resMain, signalPathsMain = processPass("main")
	local resShunting, signalPathsShunting = processPass("shunting")

	-- Gateway logic: Link the last shunting signal in a chain to the next main signal
	for _, shPath in ipairs(signalPathsShunting) do
		if not shPath.is_station then
			local nextMain = nil
			for _, mPath in ipairs(signalPathsMain) do
				if not mPath.is_station and mPath.dist_from_signal > shPath.dist_from_signal then
					nextMain = mPath
					break
				end
			end
			
			if nextMain then
				local nextShuntingDist = shPath.following_signal and shPath.following_signal.dist_from_signal or math.huge
				if nextMain.dist_from_signal < nextShuntingDist then
					-- We only pass a stripped down version of the next main signal to avoid infinite recursion/deep copying issues
					shPath.gateway_next_main_signal = {
						entity = nextMain.entity,
						signal_state = nextMain.signal_state,
						signal_speed = nextMain.signal_speed,
						dist_from_signal = nextMain.dist_from_signal,
						is_station = nextMain.is_station
					}
				end
			end
		end
	end

	-- 4th evaluation: calc checksums independently to avoid interference between the two systems
	utils.addChecksumToSignals(resMain)
	utils.addChecksumToSignals(resShunting)

	-- Add gateway state to shunting checksum so shunting signals update if the gateway main signal changes state
	for _, shRes in ipairs(resShunting) do
		if shRes.gateway_next_main_signal then
			shRes.checksum = shRes.checksum + (shRes.gateway_next_main_signal.signal_state * 13)
		end
	end

	for _, pRes in ipairs(resMain) do table.insert(res, pRes) end
	for _, pRes in ipairs(resShunting) do table.insert(res, pRes) end

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
		signalPath.showSpeedChange = true
		signalPath.following_signal = firstSignalInPath
		-- is_station and construction_params are not necessary for the first (only apply to following_signal)

		-- Internal
		signalPath.place_in_path = 0
		signalPath.dist_from_signal = 0
		return signalPath
end

---Creates SignalPath object and adds info from previous signal if exists
---@param blocksInPath [BlockInfo]
---@param idx any
---@param trainLocsEdgeEntityIds any
---@param signalPaths [SignalPath] -- signal paths created so far, used to get info about previous signal
---@param nextSignalIsRedWaypoint boolean
---@param main_signalObjects table
---@return SignalPath
function pathEvaluator.createSignalPath(blocksInPath, idx, trainLocsEdgeEntityIds, signalPaths, nextSignalIsRedWaypoint, main_signalObjects)
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
		signalPath.is_station = signalAndBlock.isStation
		signalPath.showSpeedChange = true
		signalPath.construction_params = pathEvaluator.getConstructionParams(signalAndBlock.signalListEntityId, main_signalObjects)

		if #signalPaths > 0 then
			local lastSignal = signalPaths[#signalPaths]
			signalPath.previous_speed = lastSignal.signal_speed
			lastSignal.following_signal = signalPath
		end

		-- Internal
		signalPath.place_in_path = idx
		signalPath.dist_from_signal = signalAndBlock.edgeDistCount

		return signalPath
end

function pathEvaluator.getConstructionParams(signalListEntityId, main_signalObjects)
	local constructionTable = main_signalObjects["signal" .. signalListEntityId]
	local toReturn = {}

	if constructionTable and constructionTable.signals and #constructionTable.signals > 0 then
		for _, value in pairs(constructionTable.signals) do
			local conSignalId = value.construction
			table.insert(toReturn, utils.getStaticConstructionParams(conSignalId))
		end
	end

	return toReturn
end

---First evaluation: We convert path into blocks protected by signals/end station
---@param path any
---@param lookAheadEdges any
---@param signalsToEvaluate any
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return [BlockInfo]
function pathEvaluator.findBlocksInPath(path, lookAheadEdges, signalsToEvaluate, main_signalObjects, main_signals, targetFuncType)
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

					if not pathEvaluator.isASignal(signal, potentialSignal.entity, main_signalObjects) then
						if signal.type == SIGNAL_WAYPOINT then
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
					else
						local sFuncType = pathEvaluator.getSignalFunctionalType(potentialSignal.entity, main_signalObjects, main_signals)
						
						if sFuncType == targetFuncType then
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
						elseif sFuncType == "pre" and targetFuncType == "main" then
							table.insert(presignalsForNextBlock, potentialSignal.entity)
						elseif sFuncType == "pre_shunting" and targetFuncType == "shunting" then
							table.insert(presignalsForNextBlock, potentialSignal.entity)
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
---@param main_signalObjects any -- signals.signalObjects
---@param main_signals any -- signals.signals
---@return BlockInfo | nil
function pathEvaluator.findBlockBackwards(path, lookAheadEdges, main_signalObjects, main_signals, targetFuncType)

	if path and path.path and #path.path.edges > 2 then
		local startPoint = math.max(path.dyn.pathPos.edgeIndex -1, 1) -- Train location
		local stopPoint = math.max(1, startPoint - lookAheadEdges /4) -- Start of path.path.edges. Normally a station
		local blockMinSpeed = 600
		local presignalsForFirstBlock = {}
		local paramsOverride = nil
		local speedOverriden = false

		for pathIndex = startPoint, stopPoint, -1 do
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
			if potentialSignal and potentialSignal.entity and potentialSignal.entity ~= -1 then
				local signalComponent = api.engine.getComponent(potentialSignal.entity, api.type.ComponentType.SIGNAL_LIST)
				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then
					local signal = signalComponent.signals[1]

					if not pathEvaluator.isASignal(signal, potentialSignal.entity, main_signalObjects) then
						if signal.type == SIGNAL_WAYPOINT then
							-- Params override
							local name = utils.getComponentProtected(potentialSignal.entity, 63)
							local values = pathEvaluator.parseName(string.gsub(name.name, " ", ""))

							paramsOverride = values
							if values.speed then
								speedOverriden = true
								blockMinSpeed = values.speed
							end
						end
					else
						local sFuncType = pathEvaluator.getSignalFunctionalType(potentialSignal.entity, main_signalObjects, main_signals)

						if sFuncType == targetFuncType then
							return {
								edges = {}, -- Don't need to set edges
								signalComp = signalComponent,
								signalListEntityId = potentialSignal.entity,
								hasSwitch = false,
								isStation = false,
								edgeEntityIdOn = edgeEntityId,
								minSpeed = blockMinSpeed,
								presignalsEntityIds = presignalsForFirstBlock,
								paramsOverride = paramsOverride,
								edgeDistCount = 0
							}
						elseif sFuncType == "pre" and targetFuncType == "main" then
							table.insert(presignalsForFirstBlock, potentialSignal.entity)
						elseif sFuncType == "pre_shunting" and targetFuncType == "shunting" then
							table.insert(presignalsForFirstBlock, potentialSignal.entity)
						end
					end
				end
			end
		end

		-- Adding Trainstations/End of path
		return {
			edges = {},
			signalListEntityId = 0000,
			hasSwitch = false,
			isStation = true,
			edgeEntityIdOn = path.path.edges[stopPoint].edgeId.entity,
			minSpeed = blockMinSpeed,
			presignalsEntityIds = presignalsForFirstBlock,
			paramsOverride = paramsOverride,
			edgeDistCount = 0
		}
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

function pathEvaluator.getSignalFunctionalType(signalListEntityId, main_signalObjects, main_signals)
	local signalKey = "signal" .. signalListEntityId
	local signalObj = main_signalObjects[signalKey]
	if signalObj then
		local signalTypeConfig = main_signals[signalObj.signalType]
		local construction = utils.getComponentProtected(signalObj.construction, api.type.ComponentType.CONSTRUCTION)

		if signalTypeConfig and construction then
			if signalTypeConfig.type == "hybrid" then
				if signalTypeConfig.preSignalTriggerKey and construction.params[signalTypeConfig.preSignalTriggerKey] == signalTypeConfig.preSignalTriggerValue then
					return "pre"
				elseif signalTypeConfig.shuntingTriggerKey and construction.params[signalTypeConfig.shuntingTriggerKey] == signalTypeConfig.shuntingTriggerValue then
					return "shunting"
				else
					return "main"
				end
			elseif signalTypeConfig.type == "shunting" then
				return "shunting"
			elseif signalTypeConfig.type == "pre" then
				return "pre"
			else
				return "main"
			end
		end
	end
	return "main"
end

function pathEvaluator.isMainSignal(signal, signalListEntityId, main_signalObjects, main_signals)
	if not pathEvaluator.isASignal(signal, signalListEntityId, main_signalObjects) then
		return false
	end
	return pathEvaluator.getSignalFunctionalType(signalListEntityId, main_signalObjects, main_signals) == "main"
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