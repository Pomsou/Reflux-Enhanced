-- Reflux Enhanced - Profile Manager
-- Version: 1.0.5 (Flat DB Support Update)

-- =============================================================
-- LIBRARIES & VARIABLES
-- =============================================================
local addonName, addonTable = ...
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

-- =============================================================
-- UTILITY FUNCTIONS
-- =============================================================

local function DeepCopy(t, lookup_table)
    if type(t) ~= "table" then return t end
    
    -- SAFETY CHECK: Do not attempt to copy WoW UI objects (frames, fontstrings, textures).
    if type(rawget(t, 0)) == "userdata" then return nil end

    if lookup_table and lookup_table[t] then return lookup_table[t] end
    
    local copy = {}
    lookup_table = lookup_table or {}
    lookup_table[t] = copy
    
    for k, v in pairs(t) do
        -- Skip functions and UI objects stored as keys (rare, but possible)
        local isKeyValid = type(k) ~= "function" and (type(k) ~= "table" or type(rawget(k, 0)) ~= "userdata")
        
        if isKeyValid then
            if type(v) == "table" then
                local copiedValue = DeepCopy(v, lookup_table)
                -- Only assign the table if it wasn't a stripped UI object
                if copiedValue ~= nil then
                    copy[k] = copiedValue
                end
            elseif type(v) ~= "function" then
                -- Only copy raw data types (strings, numbers, booleans)
                copy[k] = v
            end
        end
    end
    
    return copy
end

local function InjectDataInPlace(dest, src)
    if type(dest) ~= "table" or type(src) ~= "table" then return end

    local protectedKeys = {
        ["profiles"] = true, ["Profiles"] = true, ["PROFILES"] = true,
        ["profileKeys"] = true, ["ProfileKeys"] = true, ["charKeys"] = true,
        ["global"] = true, ["namespaces"] = true,
    }

    -- Pass 1: Clean up old keys not present in the new profile
    for k, v in pairs(dest) do
        if src[k] == nil then
            local shouldDelete = true
            if type(k) == "string" and protectedKeys[k] then shouldDelete = false end
            if type(v) == "table" then shouldDelete = false end
            
            -- Protect live UI Objects in the destination table
            if type(v) == "table" and type(rawget(v, 0)) == "userdata" then shouldDelete = false end
            if type(k) == "string" and issecurevariable(dest, k) then shouldDelete = false end
            
            if shouldDelete then 
                -- pcall prevents crashes if __newindex throws an error on deletion
                pcall(function() dest[k] = nil end)
            end
        end
    end

    -- Pass 2: Inject new profile data
    for k, v in pairs(src) do
        local isSecure = (type(k) == "string") and issecurevariable(dest, k) or false
        
        -- Safely check existing destination value without triggering strict __index errors
        local success, destVal = pcall(function() return dest[k] end)
        if not success then destVal = rawget(dest, k) end
        
        local isDestUIObject = type(destVal) == "table" and type(rawget(destVal, 0)) == "userdata"

        if not isSecure and not isDestUIObject then
            if type(v) == "table" then
                if type(destVal) ~= "table" then 
                    -- Safely initialize the table
                    pcall(function() dest[k] = {} end)
                end
                
                -- Fetch the table and recursively inject
                local nextDest = rawget(dest, k) or dest[k]
                if type(nextDest) == "table" then
                    InjectDataInPlace(nextDest, v)
                end
            elseif type(v) ~= "function" then
                -- Safely overwrite the value
                local setSuccess = pcall(function() dest[k] = v end)
                
                -- Fallback to rawset to bypass the addon if it locked its table with __newindex
                if not setSuccess then
                    pcall(rawset, dest, k, v)
                end
            end
        end
    end
end

local function GetAceDBForVariable(varName)
    if not LibStub then return nil end
    local AceDB = LibStub("AceDB-3.0", true)
    if not AceDB or not AceDB.db_registry then return nil end
    
    local globalTable = _G[varName]
    if not globalTable then return nil end

    -- 1. Standard Registry Check
    for db, _ in pairs(AceDB.db_registry) do
        if db == globalTable or db.sv == globalTable or db.parent == globalTable then
            return db
        end
    end

    -- 2. AceAddon Fallback (Critical for LiteMount)
    local potentialAddonName = varName:gsub("DB$", ""):gsub("_", ""):gsub("Config", "")
    local AceAddon = LibStub("AceAddon-3.0", true)
    if AceAddon then
        local app = AceAddon:GetAddon(potentialAddonName, true)
        if app and app.db and (app.db.sv == globalTable or app.db.sv == varName) then
            return app.db
        end
    end

    -- 3. Global Object Scan (Last resort)
    if _G[potentialAddonName] and type(_G[potentialAddonName]) == "table" then
        local app = _G[potentialAddonName]
        if app.db and type(app.db) == "table" and (app.db.sv == globalTable) then
            return app.db
        end
    end

    return nil
end

local TYPE_ACE3 = "ACE3"
local TYPE_INTERNAL = "INTERNAL"
local TYPE_SPLIT = "SPLIT"
local TYPE_FLAT = "FLAT"

local function IdentifyAddonStructure(varName)
    local mainDB = _G[varName]
    if not mainDB or type(mainDB) ~= "table" then return nil end

    local db = GetAceDBForVariable(varName)
    if db then return TYPE_ACE3, db end

    -- Expanded suffix list to include Memento and other common formats without underscores
    local suffixes = {
        "_CONFIG", "_DATA", "_DB", "_SETTINGS", "_VARS", "_OPTIONS", "_CHAR",
        "CONFIG", "DATA", "DB", "SETTINGS", "VARS", "OPTIONS"
    }
    local baseName = nil
    local varLower = varName:lower()
    
    for _, suffix in ipairs(suffixes) do
        if varLower:find(suffix:lower() .. "$") then
            baseName = varName:sub(1, #varName - #suffix)
            break
        end
    end

    if baseName then
        local ptrVariations = {
            baseName.."_CURRENT_PROFILE", baseName.."_PROFILE", baseName.."Profile",
            baseName.."CurrentProfile", baseName.."_ActiveProfile", baseName.."_Active"
        }
        for _, ptr in ipairs(ptrVariations) do
            if _G[ptr] ~= nil then return TYPE_SPLIT, ptr end
        end
        
        -- If it natively has a profiles table, it's internal. Otherwise, it's flat.
        if mainDB.profiles or mainDB.Profiles or mainDB.PROFILES then
            return TYPE_INTERNAL, mainDB
        else
            return TYPE_FLAT, mainDB
        end
    end

    -- Fuzzy Match: If it has a profiles table but didn't match a suffix, treat as INTERNAL
    if mainDB.profiles or mainDB.Profiles or mainDB.PROFILES then 
        return TYPE_INTERNAL, mainDB 
    end
    
    -- Fallback: If it reached here, it's a valid DB but has no profile structure.
    return TYPE_FLAT, deepmainDB
end

local function isUIObject(t)
    if type(t) ~= "table" then return false end
    
    -- Safely check for WoW UI frames by looking for the internal C userdata at index 0.
    -- Using rawget bypasses strict __index metatables (like ConsolePort's) 
    -- that throw errors when querying non-existent keys like 'GetObjectType'.
    return type(rawget(t, 0)) == "userdata"
end

local function CaptureActiveData(varName, vType, extraArg)
    local mainDB = _G[varName]
    local charNameOnly = UnitName("player")
    local realmName = GetRealmName()
    local charKey = charNameOnly .. " - " .. realmName
    local charKeyNoSpaces = charNameOnly .. " - " .. realmName:gsub(" ", "")

    if vType == TYPE_ACE3 then
        local db = extraArg
        if db.profile then return db.profile end

    elseif vType == TYPE_INTERNAL then
        local profiles = mainDB.profiles or mainDB.Profiles or mainDB.PROFILES
        local keys = mainDB.profileKeys or mainDB.ProfileKeys or mainDB.charKeys
        if type(profiles) == "table" then
            if keys then
                if keys[charKey] and profiles[keys[charKey]] then return profiles[keys[charKey]] end
                if keys[charKeyNoSpaces] and profiles[keys[charKeyNoSpaces]] then return profiles[keys[charKeyNoSpaces]] end
            end
            if profiles[charKey] then return profiles[charKey] end
            if profiles["Default"] then return profiles["Default"] end
        end

    elseif vType == TYPE_SPLIT then
        local pointerVarName = extraArg
        local activeProfileName = _G[pointerVarName]
        if activeProfileName and mainDB[activeProfileName] then return mainDB[activeProfileName] end
        
        local subProfiles = mainDB.profiles or mainDB.Profiles or mainDB.PROFILES
        if subProfiles and activeProfileName and subProfiles[activeProfileName] then return subProfiles[activeProfileName] end

        local searchName = charNameOnly:lower()
        local function isValidCandidate(k, v)
            if type(k) ~= "string" or type(v) ~= "table" then return false end
            if isUIObject(v) then return false end
            local lowerK = k:lower()
            if lowerK == searchName then return true end
            if lowerK:find("^" .. searchName .. " %-") then return true end
            if lowerK:find(" %- " .. searchName .. "$") then return true end
            return false
        end

        for k, v in pairs(mainDB) do if isValidCandidate(k, v) then return v end end
        if subProfiles then for k, v in pairs(subProfiles) do if isValidCandidate(k, v) then return v end end end
    end

    if mainDB["Default"] then return mainDB["Default"] end
    
    local rootData = {}
    local hasData = false
    for k, v in pairs(mainDB) do
        if type(v) ~= "function" and not isUIObject(v) then
            rootData[k] = DeepCopy(v)
            hasData = true
        end
    end
    
    if hasData then return rootData end
    return {}
end

local function CreateAndPopulate(varName, profileName, data, vType, extraArg)
    local mainDB = _G[varName]
    local safeData = data or {}

    local function SafeOverwrite(dest, src)
        if type(dest) ~= "table" then return DeepCopy(src) end
        for k in pairs(dest) do
            if src[k] == nil then dest[k] = nil end
        end
        for k, v in pairs(src) do
            if type(v) == "table" then
                if type(dest[k]) ~= "table" then dest[k] = {} end
                SafeOverwrite(dest[k], v)
            else
                dest[k] = v
            end
        end
        return dest
    end

    if vType == TYPE_ACE3 then
        local db = extraArg
        local profiles = (db.sv and db.sv.profiles) or mainDB.profiles
        if type(profiles) == "table" then 
            profiles[profileName] = DeepCopy(safeData) 
        end
        if db.profiles then db.profiles[profileName] = profiles[profileName] end

    elseif vType == TYPE_INTERNAL or vType == TYPE_SPLIT then
        local profiles = mainDB.profiles or mainDB.Profiles or mainDB.PROFILES
        if type(profiles) == "table" then
            if not profiles[profileName] then profiles[profileName] = {} end
            SafeOverwrite(profiles[profileName], safeData)
        else
            if not mainDB[profileName] then mainDB[profileName] = {} end
            SafeOverwrite(mainDB[profileName], safeData)
        end
    elseif vType == TYPE_FLAT then
        return
    end
end

local function SwitchPointers(varName, profileName, vType, extraArg)
    local mainDB = _G[varName]
    local realmName = GetRealmName()
    local charKey = UnitName("player") .. " - " .. realmName
    local charKeyNoSpace = UnitName("player") .. " - " .. realmName:gsub(" ", "")

    if vType == TYPE_ACE3 then
        local db = extraArg
        if db.profileKeys then 
            db.profileKeys[charKey] = profileName 
            db.profileKeys[charKeyNoSpace] = profileName 
        end
        if db.sv and db.sv.profileKeys then 
            db.sv.profileKeys[charKey] = profileName 
            db.sv.profileKeys[charKeyNoSpace] = profileName 
        end

    elseif vType == TYPE_INTERNAL then
        local keys = mainDB.profileKeys or mainDB.ProfileKeys or mainDB.charKeys
        if keys and type(keys) == "table" then
            keys[charKey] = profileName
            keys[charKeyNoSpace] = profileName
        end

    elseif vType == TYPE_SPLIT then
        local pointerVarName = extraArg
        if pointerVarName then _G[pointerVarName] = profileName end
        
    elseif vType == TYPE_FLAT then
        return
    end
end

local function initDB()
    RefluxDB = RefluxDB or {}
    RefluxDB.profiles = RefluxDB.profiles or {}
    RefluxDB.emulated = RefluxDB.emulated or {}
    RefluxDB.activeProfile = RefluxDB.activeProfile or nil
    RefluxDB.pendingSyncProfile = RefluxDB.pendingSyncProfile or nil
    RefluxDB.minimap = RefluxDB.minimap or { hide = false }
end

local function forceDetectVariables()
    initDB()
    local detected = {}
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

    local blizzardBlacklist = {
        "Blizzard_", "BLIZZARD_", "Compact", "NamePlate", "UnitFrame", "VideoOptions", "InterfaceOptions",
        "AudioOptions", "EditMode", "RaidFrame", "PartyFrame", "TargetFrame", "PlayerFrame", "C_", "Enum",
        "SlashCmdList", "ChatFrame", "MacroFrame", "GameMenu", "StaticPopup", "SettingsPanel", "Logout",
        "Quit", "AutoComplete", "ColorPicker", "Ticket", "Help", "Tutorial"
    }

    local function isBlacklisted(varName)
        if type(varName) ~= "string" or varName == "" then return true end
        if issecurevariable(_G, varName) then return true end
        for _, pattern in ipairs(blizzardBlacklist) do if varName:find(pattern) then return true end end
        return false
    end

    for i = 1, GetNum() do
        local name = GetInfo(i)
        if name and name ~= "Reflux" and name ~= "Reflux Enhanced" then
            local sv = GetMetadata(name, "SavedVariables") or ""
            local svpc = GetMetadata(name, "SavedVariablesPerCharacter") or ""
            for var in string.gmatch(sv .. "," .. svpc, "([^,%s]+)") do
                local cleanVar = var:gsub("%s+", "")
                if _G[cleanVar] and not isBlacklisted(cleanVar) and type(_G[cleanVar]) == "table" and not isUIObject(_G[cleanVar]) then
                    detected[cleanVar] = true
                end
            end
        end
    end

    for k, v in pairs(_G) do
        if type(v) == "table" and k ~= "RefluxDB" and not isBlacklisted(k) and not isUIObject(v) then
            local kLower = k:lower()
            if kLower:find("db$") or kLower:find("data$") or kLower:find("config$") or kLower:find("settings$") or kLower:find("options$") or kLower:find("vars$") then 
                detected[k] = true 
            end
        end
    end

    RefluxDB.emulated = {}
    for varName, _ in pairs(detected) do 
        table.insert(RefluxDB.emulated, varName) 
    end
end

local function RefreshAceProfiles()
    if InCombatLockdown() or not LibStub then return end
    local AceDB = LibStub("AceDB-3.0", true)
    if not AceDB or not AceDB.db_registry then return end
    for db, _ in pairs(AceDB.db_registry) do
        if type(db) == "table" and db.callbacks and db.callbacks.Fire then
            local currentProfile = (db.GetCurrentProfile and db:GetCurrentProfile()) or "Default"
            local isBlizzardDB = false
            if db.parent and (db.parent.GetObjectType or issecurevariable(db, "parent")) then isBlizzardDB = true end
            if not isBlizzardDB then pcall(db.callbacks.Fire, db.callbacks, "OnProfileChanged", db, currentProfile) end
        end
    end
end

local function ValidateAddons(profileName)
    if not RefluxDB.profiles[profileName] or not RefluxDB.profiles[profileName].meta or not RefluxDB.profiles[profileName].meta.addons then
        return {}
    end
    
    local missing = {}
    local savedAddons = RefluxDB.profiles[profileName].meta.addons
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local GetDependencies = (C_AddOns and C_AddOns.GetAddOnDependencies) or GetAddOnDependencies
    
    -- Dynamically build a list of everything that SHOULD be enabled, including dependencies
    local expectedEnabled = {}
    
    local function MarkExpected(name)
        if not expectedEnabled[name] then
            expectedEnabled[name] = true
            if GetDependencies then
                -- Safely capture all returned dependencies into a table
                local deps = {GetDependencies(name)}
                for _, dep in ipairs(deps) do
                    if dep and dep ~= "" then MarkExpected(dep) end
                end
            end
        end
    end
    
    -- Pass 1: Resolve all required addons and their libraries
    for name, state in pairs(savedAddons) do
        if state and GetInfo(name) then
            MarkExpected(name)
        end
    end
    
    -- Pass 2: Compare against current client state
    for i = 1, GetNum() do
        local name, _, _, isEnabled = GetInfo(i)
        if name ~= "Reflux" and name ~= "Reflux Enhanced" then
            local shouldBeEnabled = expectedEnabled[name]
            if isEnabled and not shouldBeEnabled then
                table.insert(missing, name .. " (Should be Disabled)")
            elseif not isEnabled and shouldBeEnabled then
                table.insert(missing, name .. " (Should be Enabled)")
            end
        end
    end
    
    return missing
end

local function SyncAddonsOnly(profileName)
    if not RefluxDB.profiles[profileName] then print("|cFFFF0000Reflux Enhanced: Profile not found.|r") return end
    if not RefluxDB.profiles[profileName].meta or not RefluxDB.profiles[profileName].meta.addons then
        print("|cFFFFFF00Reflux Enhanced: No addon data for this profile.|r")
        return
    end
    
    local savedAddons = RefluxDB.profiles[profileName].meta.addons
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local Enable = (C_AddOns and C_AddOns.EnableAddOn) or EnableAddOn
    local Disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
    local GetDependencies = (C_AddOns and C_AddOns.GetAddOnDependencies) or GetAddOnDependencies
    local SaveState = (C_AddOns and C_AddOns.SaveAddOns) or SaveAddOns
    
    local playerName = UnitName("player")
    local changesMade = false
    
    print("|cFF00FF00Reflux Enhanced: Syncing addons for '"..profileName.."'...|r")
    
    -- Helper function to recursively enable dependencies
    local function EnableWithDeps(addonName)
        local _, _, _, isEnabled = GetInfo(addonName)
        if not isEnabled then
            Enable(addonName, playerName)
            print("  |cFF00FF00+ Enabling: " .. addonName .. "|r")
            changesMade = true
        end
        
        if GetDependencies then
            local deps = {GetDependencies(addonName)}
            for _, depName in ipairs(deps) do
                if depName and depName ~= "" then
                    local _, _, _, depEnabled = GetInfo(depName)
                    if not depEnabled then
                        Enable(depName, playerName)
                        print("  |cFF88FF88  + Auto-Enabling Dependency: " .. depName .. "|r")
                        changesMade = true
                    end
                end
            end
        end
    end

    -- Pass 1: Disable everything that shouldn't be loaded on this character
    for i = 1, GetNum() do
        local name, _, _, isEnabled = GetInfo(i)
        if name ~= "Reflux" and name ~= "Reflux Enhanced" then
            if isEnabled and not savedAddons[name] then
                Disable(name, playerName)
                print("  |cFFFF0000- Disabling: " .. name .. "|r")
                changesMade = true
            end
        end
    end
    
    -- Pass 2: Enable saved addons and resolve any new dependencies
    for name, shouldBeEnabled in pairs(savedAddons) do
        if shouldBeEnabled and name ~= "Reflux" and name ~= "Reflux Enhanced" then
            if GetInfo(name) then
                EnableWithDeps(name)
            else
                print("  |cFF888888? Missing Addon Ignored: " .. name .. "|r")
            end
        end
    end

    if changesMade then
        -- Force WoW to immediately write the new AddOn states to the hard drive
        if SaveState then SaveState() end 
        
        print("|cFF00FF00Reflux Enhanced: Addons updated. Reloading UI...|r")
        RefluxDB.pendingSyncProfile = profileName
        ReloadUI()
    else
        print("|cFFFFFF00Reflux Enhanced: Addons are already correct for this profile.|r")
    end
end

local function saveProfile(profileName)
    if not profileName or profileName == "" then print("Usage: /reflux save [name]") return end
    initDB()
    forceDetectVariables()
    
    print("|cFFFFFF00Reflux Enhanced: Capturing data for '" .. profileName .. "'...|r")
    
    for _, varName in ipairs(RefluxDB.emulated) do
        local vType, extra = IdentifyAddonStructure(varName)
        if vType then
            local data = CaptureActiveData(varName, vType, extra)
            CreateAndPopulate(varName, profileName, data, vType, extra)
            SwitchPointers(varName, profileName, vType, extra)
        end
    end

    local currentSnapshots = {}
    for _, varName in ipairs(RefluxDB.emulated) do
        if _G[varName] then currentSnapshots[varName] = DeepCopy(_G[varName]) end
    end
    
    RefluxDB.profiles[profileName] = currentSnapshots
    
    local activeAddons = {}
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    
    for i = 1, GetNum() do
        local name, _, _, enabled = GetInfo(i)
        if enabled then activeAddons[name] = true end
    end
    
    RefluxDB.profiles[profileName].meta = {
        timestamp = time(),
        addons = activeAddons
    }
    
    RefluxDB.activeProfile = profileName
    RefluxDB.forceNextLogin = profileName
    
-- Clean up the memory bloat caused by DeepCopying the entire UI state
    collectgarbage("collect")
    
    print("|cFF00FF00Reflux Enhanced: Profile '|r|cFFFFFF00" .. profileName .. "|r|cFF00FF00' saved. Reloading to write to disk...|r")
    ReloadUI()
end

local function switchProfile(profileName)
    if not profileName or not RefluxDB.profiles[profileName] then 
        print("|cFFFF0000Reflux Enhanced: Profile not found.|r") 
        return 
    end
    
    initDB()
    forceDetectVariables()
    
    local missing = ValidateAddons(profileName)
    if #missing > 0 then
        print("|cFFFF0000[Reflux Enhanced] ERROR: Addon mismatch detected!|r")
        print("|cFFFF0000The following addons need to be synced first:|r")
        for _, name in ipairs(missing) do print("  - " .. name) end
        print("|cFFFFFF00[Reflux Enhanced] ACTION REQUIRED: Type |r|cFF00FF00/reflux addons " .. profileName .. "|r|cFFFFFF00 first.|r")
        return
    end
    
    -- We are about to do heavy table manipulation. Let the user know.
    print("|cFFFFFF00Reflux Enhanced: Preparing data for '" .. profileName .. "'...|r")
    
    local savedData = RefluxDB.profiles[profileName]
    for varName, content in pairs(savedData) do
        if varName ~= "meta" and _G[varName] and type(_G[varName]) == "table" then
            InjectDataInPlace(_G[varName], content)
        end
    end
    
    for _, varName in ipairs(RefluxDB.emulated) do
        local vType, extra = IdentifyAddonStructure(varName)
        if vType then SwitchPointers(varName, profileName, vType, extra) end
    end
    
    RefluxDB.activeProfile = profileName
    RefluxDB.forceNextLogin = profileName
    
    RefreshAceProfiles()
    collectgarbage("collect")
    
    print("|cFF00FF00Reflux Enhanced: Switched to '" .. profileName .. "'. Reloading UI...|r")
    ReloadUI()
end

-- =============================================================
-- MINIMAP ICON DATA BROKER
-- =============================================================

local refluxLDB = LDB:NewDataObject("RefluxEnhanced", {
    type = "data source",
    text = "Reflux",
    icon = "Interface\\AddOns\\Reflux Enhanced\\icon", 
    
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("Reflux Enhanced")
        if RefluxDB.activeProfile then
            tooltip:AddLine("Active: |cFF00FF00" .. RefluxDB.activeProfile .. "|r")
        else
            tooltip:AddLine("Active: |cFF888888None|r")
        end
        tooltip:AddLine(" ")
        tooltip:AddLine("|cFFeda55fLeft-Click|r to list profiles")
        tooltip:AddLine("|cFFeda55fRight-Click|r for help")
    end,
    
    OnClick = function(self, button)
        if button == "RightButton" then
            refluxCommandHandler("help") 
        else
            refluxCommandHandler("list") 
        end
    end,
})

-- =============================================================
-- SLASH COMMANDS & INITIALIZATION
-- =============================================================

function refluxCommandHandler(msg)
    local cmd, arg = string.match(msg or "", "^%s*([^%s]+)%s*(.*)$")
    cmd = cmd and string.lower(cmd) or ""
    
    -- Sanitize input
    arg = arg and arg:match("^%s*(.-)%s*$") or ""

    if cmd == "save" then
        if arg == "" then
            print("|cFFFF0000Reflux Enhanced: Please specify a profile name. Usage: /reflux save [name]|r")
        else
            saveProfile(arg)
        end
        
    elseif cmd == "switch" then
        if arg == "" then
            print("|cFFFF0000Reflux Enhanced: Please specify a profile name. Usage: /reflux switch [name]|r")
        else
            switchProfile(arg)
        end
        
    elseif cmd == "addons" then
        if arg == "" then
            if RefluxDB.activeProfile then 
                arg = RefluxDB.activeProfile
            else 
                print("|cFFFF0000Reflux Enhanced: No active profile to sync. Usage: /reflux addons [name]|r")
                return 
            end
        end
        SyncAddonsOnly(arg)
        
    elseif cmd == "delete" then
        if arg == "" then
            print("|cFFFF0000Reflux Enhanced: Please specify a profile name. Usage: /reflux delete [name]|r")
        elseif RefluxDB.profiles[arg] then
            RefluxDB.profiles[arg] = nil
            if RefluxDB.activeProfile == arg then RefluxDB.activeProfile = nil end
            print("|cFF00FF00Reflux Enhanced: Deleted profile '" .. arg .. "'.|r")
        else
            print("|cFFFF0000Reflux Enhanced: Profile '" .. arg .. "' does not exist.|r")
        end
        
    elseif cmd == "list" then
        print("|cFF00FFFF--- Reflux Enhanced Profiles ---|r")
        local count = 0
        for name, _ in pairs(RefluxDB.profiles) do
            local suffix = (name == RefluxDB.activeProfile) and " |cFF00FF00(Active)|r" or ""
            print("  - |cFFFFFF00" .. name .. "|r" .. suffix)
            count = count + 1
        end
        if count == 0 then
            print("  |cFF888888No profiles saved yet.|r")
        end
        
    elseif cmd == "icon" then
        RefluxDB.minimap.hide = not RefluxDB.minimap.hide
        if RefluxDB.minimap.hide then
            LDBIcon:Hide("RefluxEnhanced")
            print("|cFFFFFF00Reflux Enhanced: Minimap icon hidden.|r")
        else
            LDBIcon:Show("RefluxEnhanced")
            print("|cFF00FF00Reflux Enhanced: Minimap icon shown.|r")
        end
        
    else
        -- help menu for invalid commands or /reflux alone
        print("|cFF00FFFF--- Reflux Enhanced Commands ---|r")
        print("  |cFFFFFF00/reflux save [name]|r - Saves the current UI state")
        print("  |cFFFFFF00/reflux switch [name]|r - Switches to a saved profile")
        print("  |cFFFFFF00/reflux addons [name]|r - Syncs addons for a profile")
        print("  |cFFFFFF00/reflux delete [name]|r - Deletes a saved profile")
        print("  |cFFFFFF00/reflux list|r - Lists all saved profiles")
        print("  |cFFFFFF00/reflux icon|r - Toggles the minimap button")
    end
end

SlashCmdList["REFLUX"] = refluxCommandHandler
SLASH_REFLUX1 = "/reflux"

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    initDB()
    
    if LDBIcon and not LDBIcon:IsRegistered("RefluxEnhanced") then
        LDBIcon:Register("RefluxEnhanced", refluxLDB, RefluxDB.minimap)
    end
    
    if RefluxDB.forceNextLogin then
        local pName = RefluxDB.forceNextLogin
        RefluxDB.forceNextLogin = nil
        C_Timer.After(1, function() print("|cFF00FF00Reflux Enhanced: '" .. pName .. "' active.|r") end)
    end
    if RefluxDB.pendingSyncProfile then
        local pName = RefluxDB.pendingSyncProfile
        RefluxDB.pendingSyncProfile = nil
        C_Timer.After(2, function()
            print("|cFF00FF00Reflux Enhanced: Addons loaded.|r")
            print("|cFFFFFF00You can now use |r|cFF00FF00/reflux switch " .. pName .. "|r|cFFFFFF00 to finish loading the profile.|r")
        end)
    end
end)

print("|cFF00FF00Reflux Enhanced loaded.|r")