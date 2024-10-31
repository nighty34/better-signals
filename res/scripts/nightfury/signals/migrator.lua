local migrator = {}


function migrator.migrate(currentVersion, signalObjects)
    if signalObjects then

        if currentVersion == 0 then
            local signals = signalObjects
            print("Add possibility to link multiple better signals to one real signal")
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

        if currentVersion == 1 then
            print("Add signalType to signals")
            for key, oldSignal in pairs(signalObjects) do
                oldSignal.signalType = "default"
                if #oldSignal.signals > 1 then
                    oldSignal.construction = oldSignal.signals[#oldSignal.signals].construction
                else
                    oldSignal.construction = 0000
                end

                signalObjects[key] = oldSignal
            end

            currentVersion = 2
        end
    end

    return currentVersion, signalObjects
end


return migrator