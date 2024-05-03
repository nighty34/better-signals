local utils = require "nightfury/signals/utils"
local zone = require "nightfury/signals/zone"
local signals = {}

signals.signals = {}
-- Table holds all placed Signals
signals.signalObjects = {}

signals.signalIndex = 0

signals.pos = {0,0}
signals.trackedEntities = {}
signals.viewDistance = 20


-- 3 states: None, Changed, WasChanged

-- Function checks move_path of all the trains
-- If a signal is found it's current state is checked
-- after that the signal will be changed accordingly
function signals.updateSignals()
	local trainActivationRange = 500 -- To be changed

	local trains = {}
	local vehicles = game.interface.getEntities({pos = signals.pos, radius = trainActivationRange}, {type = "VEHICLE"})
	-- zone.setZoneCircle("zoneRadius", signals.pos, 500)

	for i, trackedTrain in pairs(signals.trackedEntities) do
		local tracked = game.interface.getEntity(trackedTrain)
		if tracked then
			local trackedPos = tracked.position
			if trackedPos then
				local newTrains = game.interface.getEntities({pos = {trackedPos[1], trackedPos[2]}, radius = trainActivationRange}, {type = "VEHICLE"})
				-- zone.setZoneCircle("tracked" .. i, {trackedPos[1], trackedPos[2]}, trainActivationRange/2)
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

	for _, vehicle in pairs(vehicles) do
		local train = utils.getComponentProtected(vehicle, 70)
		if (train ~= nil) and (not train.userStopped) and (not train.noPath) and (not train.doorsOpen) then
			table.insert(trains, vehicle)
		end
	end
	
	for _, value in pairs(signals.signalObjects) do
		if value.changed then
			value.changed = value.changed * 2
		end
	end
	
	for _,train in pairs(trains) do
		local move_path = utils.getComponentProtected(train, 66)

		if move_path then	
			--local signalPaths = walkPath(move_path, train)
			local signalPaths = evaluatePath(move_path)
			
			for _, signalPath in ipairs(signalPaths) do
				if signalPath.entity then
					local minSpeed = signalPath.signal_speed
					local signalState = signalPath.signal_state
					local signalString = "signal" .. signalPath.entity
					local tableEntry = signals.signalObjects[signalString]
					
					if tableEntry then
						local c_signal = tableEntry.construction
						signals.signalObjects[signalString].changed = 1
						
						if c_signal then
							local oldConstruction = game.interface.getEntity(c_signal)
							if oldConstruction then
								oldConstruction.params.previous_speed = signalPath.previous_speed
								oldConstruction.params.signal_state = signalState
								oldConstruction.params.signal_speed = math.floor(minSpeed)
								oldConstruction.params.following_signal = signalPath.following_signal
								oldConstruction.params.seed = nil -- important!!

								local newCheckSum = signalPath.checksum

								if (not signals.signalObjects[signalString].checksum) or (newCheckSum ~= signals.signalObjects[signalString].checksum) then
									local proposal = api.type.SimpleProposal.new()
									proposal.constructionsToRemove = {} -- TODO
									local pd = api.engine.util.proposal.makeProposalData(proposal, {}) -- can context be something smart?
									if pd.errorState.critical == true then
										print(pd.errorState.messages[1] .. " : " .. oldConstruction.fileName)
									else
										if pcall(function () 
											local check = game.interface.upgradeConstruction(oldConstruction.id, oldConstruction.fileName, oldConstruction.params)
											if check ~= c_signal then
												print("Construction upgrade error")
											end
										end) then
										else
											print("Programmical Error during Upgrade")
										end
									end
								end

								signals.signalObjects[signalString].checksum = newCheckSum
							else
								print("Couldn't access params")
							end
						end
					end
				end
			end
		end
	end
	
	-- Throw signal to red
	for key, value in pairs(signals.signalObjects) do
		if value.changed == 2 then
			local oldConstruction = game.interface.getEntity(value.construction)
			if oldConstruction then
				oldConstruction.params.signal_state = 0
				oldConstruction.params.previous_speed = nil
				oldConstruction.params.seed = nil -- important!!

				game.interface.upgradeConstruction(oldConstruction.id, oldConstruction.fileName, oldConstruction.params)
			end
			value.changed = 0
		end
	end
end


-- Registers new signal
-- @param signal signal entityid
-- @param construct construction entityid
function signals.createSignal(signal, construct, signalType, allowWaypoints)
	local signalKey = "signal" .. signal
	print("Register Signal: " .. signal .. " (" .. signalKey ..") With construction: " .. construct)
	signals.signalObjects[signalKey] = {}
	signals.signalObjects[signalKey].construction = construct
	signals.signalObjects[signalKey].changed = 0
	signals.signalObjects[signalKey].type = signalType
	signals.signalObjects[signalKey].allowWaypoints = allowWaypoints
end

function signals.removeSignalBySignal(signal)
	signals.signalObjects["signal" .. signal] = nil
end

function signals.removeSignalByConstruction(construction)
	for key, value in pairs(signals.signalObjects) do
		if value.construction == construction then
			signals.signalObjects[key] = nil
			return
		end
	end
end


function parseName(input)
    local values = {}
    
    -- Iterate over each key-value pair in the input string
    for pair in input:gmatch("%s*([^,]+)%s*,?") do
        local key, value = pair:match("(%w+)%s*=%s*(%d+)")
        if key and (key == "speed" or key == "dest" or key == "direction") then
            values[key] = tonumber(value)
        end
    end
    
    return values
end

function evaluatePath(path)
	local pathViewDistance = signals.viewDistance-- To be changed

	local evaluatedPath = {}
	local currentSegment = {}
	local edgeSpeeds = {}
	local checksum = 0
	local followingSignal = {}

	if path.path then
		local pathStart = math.max((path.dyn.pathPos.edgeIndex - 2), 1)
		local pathEnd = math.min(#path.path.edges, pathStart + pathViewDistance)

		for pathIndex = pathEnd, pathStart, -1 do
			local currentEdge = path.path.edges[pathIndex]

			if currentEdge then

				-- Get EdgeSpeed
				table.insert(edgeSpeeds, utils.getEdgeSpeed(currentEdge.edgeId))

				local potentialSignal = api.engine.system.signalSystem.getSignal(currentEdge.edgeId, currentEdge.dir)
				local signalComponent = utils.getComponentProtected(potentialSignal.entity, 26)

				if signalComponent and signalComponent.signals and #signalComponent.signals > 0 then

					local signal = signalComponent.signals[1]

					if (signal.type == 0 or signal.type == 1) or (signals.signalObjects[tonumber(signal.entity)] and signals.signalObjects[tonumber(signal.entity)].allowWaypoints) then -- Adding Signal

						currentSegment.entity = potentialSignal.entity
						currentSegment.signal_state = signal.state
						currentSegment.incomplete = false

						currentSegment.signal_speed = utils.getMinValue(edgeSpeeds)

						if followingSignal then
							if #evaluatedPath > 1 then
								followingSignal.previous_speed = currentSegment.signal_speed
							end

							currentSegment.following_signal = followingSignal
						end

						currentSegment.checksum = checksum + utils.checksum(currentSegment.entity, currentSegment.signal_state, currentSegment.signal_speed, #evaluatedPath)
						checksum = currentSegment.checksum

						table.insert(evaluatedPath, 1, currentSegment)

						followingSignal = currentSegment
						currentSegment = {}
						edgeSpeeds = {}
					end
				elseif pathIndex == (#path.path.edges - path.path.endOffset) then -- Adding Trainstations
					currentSegment.entity = 0000
					currentSegment.signal_state = 0
					currentSegment.incomplete = false
					currentSegment.signal_speed = 0

					currentSegment.checksum = checksum + utils.checksum(currentSegment.entity, currentSegment.signal_state, currentSegment.signal_speed, #evaluatedPath)
					checksum = currentSegment.checksum

					table.insert(evaluatedPath, 1, currentSegment)

					followingSignal = currentSegment
					currentSegment = {}
					edgeSpeeds = {}
				end
			end
		end

		if followingSignal then
			followingSignal.previous_speed = utils.getMinValue(edgeSpeeds)
		end
	end

	return evaluatedPath
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

