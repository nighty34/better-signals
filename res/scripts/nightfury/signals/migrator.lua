local migrator = {}


function migrator.migrate(currentVersion, signalObjects)

    if signalObjects then

    if currentVersion == 0 then
            local signals = signalObjects

            

            for key, oldSignal in pairs(signals) do
                local newSignal = {}
                local newSignalEntry = {}
                newSignalEntry.construction = oldSignal.construction
                newSignalEntry.type = oldSignal.type
                if oldSignal.isAnimated then
                    newSignalEntry.isAnimated = oldSignal.isAnimated
                else
                    newSignalEntry.isAnimated = false
                end

                newSignal.signals = {}
                newSignal.changed = 0
                
                table.insert(newSignal.signals, newSignalEntry)
        
                signalObjects[key] = newSignal
                
                currentVersion = 1
            end


        end

    end

    return currentVersion, signalObjects
end


return migrator