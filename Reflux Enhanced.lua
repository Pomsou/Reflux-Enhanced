-- Reflux Enhanced - Profile Manager
-- Version: 1.1.0 (Reflux API for custom DB addons)

-- =============================================================
-- PUBLIC API REGISTRY
-- =============================================================
_G.RefluxEnhancedAPI = _G.RefluxEnhancedAPI or {}
_G.RefluxEnhancedAPI.CustomHandlers = {}
_G.RefluxEnhancedAPI.IgnoredDBs = {}

function _G.RefluxEnhancedAPI:RegisterCustomAddon(mainDBName, handlerParams, ignoredDBsList)
    self.CustomHandlers[mainDBName] = handlerParams
    if ignoredDBsList and type(ignoredDBsList) == "table" then
        for _, dbName in ipairs(ignoredDBsList) do self.IgnoredDBs[dbName] = true end
    end
end

-- =============================================================
-- LIBRARIES & VARIABLES
-- =============================================================
local addonName, addonTable = ...
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

-- =============================================================
-- UTILITY FUNCTIONS
-- =============================================================

local function DeepCopy(t, lookup_table, depth, tracker)
    if type(t) ~= "table" then return t end
    if type(rawget(t, 0)) == "userdata" then return nil end

    lookup_table = lookup_table or {}
    if lookup_table[t] then return lookup_table[t] end

    depth = depth or 0
    if depth > 20 then return nil end 

    tracker = tracker or { count = 0, limitHit = false }
    if tracker.limitHit then return nil end
    
    local copy = {}
    lookup_table[t] = copy
    
    for k, v in pairs(t) do
        tracker.count = tracker.count + 1
        
        if tracker.count > 5000 then 
            tracker.limitHit = true
            return nil 
        end

        local isKeyValid = type(k) ~= "function" and (type(k) ~= "table" or type(rawget(k, 0)) ~= "userdata")
        if isKeyValid then
            if type(v) == "table" then
                local copiedValue = DeepCopy(v, lookup_table, depth + 1, tracker)
                if tracker.limitHit then return nil end
                if copiedValue ~= nil then copy[k] = copiedValue end
            elseif type(v) ~= "function" then
                copy[k] = v
            end
        end
    end
    return copy
end

local function InjectDataInPlace(dest, src, isRoot)
    if isRoot == nil then isRoot = true end
    if type(dest) ~= "table" or type(src) ~= "table" then return end

    local protectedKeys = {
        ["profiles"] = true, ["Profiles"] = true, ["PROFILES"] = true,
        ["profileKeys"] = true, ["ProfileKeys"] = true, ["charKeys"] = true,
        ["global"] = true, ["namespaces"] = true,
    }

    local pointerKeys = {
        ["profileKeys"] = true, ["ProfileKeys"] = true, ["charKeys"] = true,
    }

    for k, v in pairs(dest) do
        if src[k] == nil then
            local shouldDelete = true
            if isRoot and type(k) == "string" and protectedKeys[k] then shouldDelete = false end
            if type(v) == "table" and type(rawget(v, 0)) == "userdata" then shouldDelete = false end
            if isRoot and type(k) == "string" and issecurevariable(dest, k) then shouldDelete = false end
            if shouldDelete then rawset(dest, k, nil) end
        end
    end

    for k, v in pairs(src) do
        local isSecure = isRoot and (type(k) == "string") and issecurevariable(dest, k) or false
        local isPointer = isRoot and type(k) == "string" and pointerKeys[k]
        
        if not isSecure and not isPointer then
            local destVal = rawget(dest, k)
            local isDestUIObject = type(destVal) == "table" and type(rawget(destVal, 0)) == "userdata"

            if not isDestUIObject then
                if type(v) == "table" then
                    if type(destVal) ~= "table" then 
                        rawset(dest, k, {})
                        destVal = rawget(dest, k)
                    end
                    InjectDataInPlace(destVal, v, false)
                elseif type(v) ~= "function" then
                    rawset(dest, k, v)
                end
            end
        end
    end
end

local function GetAceDBForVariable(varName)
    if not LibStub then return nil end
    local AceDB = LibStub("AceDB-3.0", true)
    local globalTable = _G[varName]
    
    -- 1. Official AceDB Registry Check
    if AceDB and AceDB.db_registry and globalTable then
        for db, _ in pairs(AceDB.db_registry) do
            if db == globalTable or db.sv == globalTable or db.parent == globalTable then return db end
        end
    end

    -- 2. AceAddon Object Check
    local potentialAddonName = varName:gsub("DB$", ""):gsub("_", ""):gsub("Config", "")
    local AceAddon = LibStub("AceAddon-3.0", true)
    if AceAddon and globalTable then
        local app = AceAddon:GetAddon(potentialAddonName, true)
        if app and app.db and (app.db.sv == globalTable or app.db.sv == varName) then return app.db end
    end

    -- 3. Standard Global Object Check
    if _G[potentialAddonName] and type(_G[potentialAddonName]) == "table" then
        local app = _G[potentialAddonName]
        if app.db and type(app.db) == "table" and (app.db.sv == globalTable) then return app.db end
    end

    -- 4. Aggressive Heuristic Scan (Finds Frogski's custom DB manager)
    local cleanVar = varName:lower():gsub("db$", ""):gsub("account$", ""):gsub("data$", ""):gsub("config$", "")
    for k, v in pairs(_G) do
        if type(v) == "table" and k ~= "RefluxDB" and k ~= "AceDB-3.0" then
            local success, db = pcall(function() return rawget(v, "db") end)
            if success and type(db) == "table" and type(rawget(db, "SetProfile")) == "function" and type(rawget(db, "GetCurrentProfile")) == "function" then
                -- Does it implicitly own this variable?
                if globalTable and (db.sv == globalTable or db.parent == globalTable) then
                    return db
                end
                -- Do the string prefixes match? (e.g. 'FrogskisCursorTrail2' and 'FrogskisCursorTrailAccountDB')
                local cleanK = k:lower():gsub("%d+$", "")
                if cleanVar ~= "" and cleanK ~= "" and (cleanVar:find(cleanK, 1, true) or cleanK:find(cleanVar, 1, true)) then
                    return db
                end
            end
        end
    end

    return nil
end

local TYPE_ACE3 = "ACE3"
local TYPE_INTERNAL = "INTERNAL"
local TYPE_SPLIT = "SPLIT"
local TYPE_FLAT = "FLAT"

local function IdentifyAddonStructure(varName)
    -- 1. Check Custom API Hooks First
    if _G.RefluxEnhancedAPI then
        local function getBaseDB(n) return type(n) == "string" and n:lower():gsub("_?v%d+$", "") or "" end
        local baseVarName = getBaseDB(varName)
        
        if _G.RefluxEnhancedAPI.IgnoredDBs then
            for ignoredDB, _ in pairs(_G.RefluxEnhancedAPI.IgnoredDBs) do
                if getBaseDB(ignoredDB) == baseVarName then return "IGNORED", nil end
            end
        end
        
        if _G.RefluxEnhancedAPI.CustomHandlers then
            for customDB, handler in pairs(_G.RefluxEnhancedAPI.CustomHandlers) do
                if getBaseDB(customDB) == baseVarName then
                    if handler.api() then return "CUSTOM", handler end
                end
            end
        end
    end

    local mainDB = _G[varName]
    if not mainDB or type(mainDB) ~= "table" then return nil end

    local db = GetAceDBForVariable(varName)
    if db then 
        -- Safety bind: Ensure custom DB manager actually manages this specific table
        if db.sv == mainDB or mainDB.profiles or mainDB.Profiles or mainDB.PROFILES then
            return TYPE_ACE3, db 
        end
    end

    local baseName = nil
    local varLower = varName:lower()
    
    local vStart = varLower:find("_db_v%d+$") or varLower:find("db_v%d+$")
    
    if vStart then
        baseName = varName:sub(1, vStart - 1)
    else
        local suffixes = {
            "_CONFIG", "_DATA", "_DB", "_SETTINGS", "_VARS", "_OPTIONS", "_CHAR",
            "CONFIG", "DATA", "DB", "SETTINGS", "VARS", "OPTIONS"
        }
        for _, suffix in ipairs(suffixes) do
            if varLower:find(suffix:lower() .. "$") then
                baseName = varName:sub(1, #varName - #suffix)
                break
            end
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
        
        if mainDB.profiles or mainDB.Profiles or mainDB.PROFILES then return TYPE_INTERNAL, mainDB
        else return TYPE_FLAT, mainDB end
    end

    if mainDB.profiles or mainDB.Profiles or mainDB.PROFILES then return TYPE_INTERNAL, mainDB end
    return TYPE_FLAT, mainDB
end

local function isUIObject(t)
    if type(t) ~= "table" then return false end
    return type(rawget(t, 0)) == "userdata"
end

local function CaptureActiveData(varName, vType, extraArg)
    local mainDB = _G[varName]
    local charNameOnly = UnitName("player")
    local realmName = GetRealmName()
    local charKey = charNameOnly .. " - " .. realmName
    local charKeyNoSpaces = charNameOnly .. " - " .. realmName:gsub(" ", "")

    if vType == TYPE_INTERNAL then
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
            local copiedValue = DeepCopy(v)
            if copiedValue then
                rootData[k] = copiedValue
                hasData = true
            end
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
        for k in pairs(dest) do if src[k] == nil then dest[k] = nil end end
        for k, v in pairs(src) do
            if type(v) == "table" then
                if type(dest[k]) ~= "table" then dest[k] = {} end
                SafeOverwrite(dest[k], v)
            else dest[k] = v end
        end
        return dest
    end

    if vType == TYPE_INTERNAL or vType == TYPE_SPLIT then
        local profiles = mainDB.profiles or mainDB.Profiles or mainDB.PROFILES
        if type(profiles) == "table" then
            if not profiles[profileName] then profiles[profileName] = {} end
            SafeOverwrite(profiles[profileName], safeData)
        else
            if not mainDB[profileName] then mainDB[profileName] = {} end
            SafeOverwrite(mainDB[profileName], safeData)
        end
    end
end

local function SwitchPointers(varName, profileName, vType, extraArg)
    local mainDB = _G[varName]
    local realmName = GetRealmName()
    local charKey = UnitName("player") .. " - " .. realmName
    local charKeyNoSpace = UnitName("player") .. " - " .. realmName:gsub(" ", "")

    if vType == TYPE_INTERNAL then
        local keys = mainDB.profileKeys or mainDB.ProfileKeys or mainDB.charKeys
        if keys and type(keys) == "table" then
            keys[charKey] = profileName
            keys[charKeyNoSpace] = profileName
        end

    elseif vType == TYPE_SPLIT then
        local pointerVarName = extraArg
        if pointerVarName then _G[pointerVarName] = profileName end
    end
end

local function initDB()
    RefluxDB = RefluxDB or {}
    RefluxDB.profiles = RefluxDB.profiles or {}
    RefluxDB.emulated = RefluxDB.emulated or {}
    RefluxDB.activeProfile = RefluxDB.activeProfile or nil
    RefluxDB.pendingSyncProfile = RefluxDB.pendingSyncProfile or nil
    RefluxDB.minimap = RefluxDB.minimap or { hide = false }
    RefluxDB.characterLinks = RefluxDB.characterLinks or {}
end

local function forceDetectVariables()
    initDB()
    local detected = {}
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

    local addonBlacklist = {
        "TradeSkillMaster", "Details", "RaiderIO", "AllTheThings", "DataStore", 
        "Auctionator", "Auctioneer", "Skada", "Recount", "WeakAurasArchive",
        "Pawn", "Questie", "GatherMate", "Routes", "TomTom", "DBM", "BigWigs", "AtlasLoot"
    }

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
        for _, pattern in ipairs(addonBlacklist) do if varName:find(pattern) then return true end end
        return false
    end

    for i = 1, GetNum() do
        local name = GetInfo(i)
        if name and name ~= "Reflux" and name ~= "Reflux Enhanced" then
            local sv = GetMetadata(name, "SavedVariables") or ""
            local svpc = GetMetadata(name, "SavedVariablesPerCharacter") or ""
            for var in string.gmatch(sv .. "," .. svpc, "([^,%s]+)") do
                local cleanVar = var:gsub("%s+", "")
                if cleanVar ~= "" and _G[cleanVar] and type(_G[cleanVar]) == "table" and not isBlacklisted(cleanVar) and not isUIObject(_G[cleanVar]) then
                    detected[cleanVar] = true
                end
            end
        end
    end

    for k, v in pairs(_G) do
        if type(v) == "table" and k ~= "RefluxDB" and not detected[k] and not isBlacklisted(k) and not isUIObject(v) then
            local kLower = k:lower()
            if kLower:find("db$") or kLower:find("data$") or kLower:find("config$") or kLower:find("settings$") or kLower:find("options$") or kLower:find("vars$") or kLower:find("db_v%d+$") then 
                detected[k] = true 
            end
        end
    end
-- FORCE INCLUDE CUSTOM API ADDONS (Bypasses the scanner)
    if _G.RefluxEnhancedAPI and _G.RefluxEnhancedAPI.CustomHandlers then
        for customVar, _ in pairs(_G.RefluxEnhancedAPI.CustomHandlers) do
            local baseCustom = customVar:lower():gsub("_?v%d+$", "")
            local alreadyFound = false

            for detectedVar, _ in pairs(detected) do
                if detectedVar:lower():gsub("_?v%d+$", "") == baseCustom then
                    alreadyFound = true
                    break
                end
            end
            
            if not alreadyFound then
                detected[customVar] = true
            end
        end
    end

    RefluxDB.emulated = {}
    for varName, _ in pairs(detected) do table.insert(RefluxDB.emulated, varName) end
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
    if not RefluxDB.profiles[profileName] or not RefluxDB.profiles[profileName].meta or not RefluxDB.profiles[profileName].meta.addons then return {} end
    
    local missing = {}
    local savedAddons = RefluxDB.profiles[profileName].meta.addons
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local GetDependencies = (C_AddOns and C_AddOns.GetAddOnDependencies) or GetAddOnDependencies
    local playerName = UnitName("player")

    local function IsAddOnEnabled(name)
        if C_AddOns and C_AddOns.GetAddOnEnableState then
            return C_AddOns.GetAddOnEnableState(name, playerName) > 0
        elseif GetAddOnEnableState then
            return GetAddOnEnableState(playerName, name) > 0
        else
            local _, _, _, _, reason = GetInfo(name)
            return reason ~= "DISABLED"
        end
    end
    
    local expectedEnabled = {}
    local function MarkExpected(name)
        if not expectedEnabled[name] then
            expectedEnabled[name] = true
            if GetDependencies then
                local deps = {GetDependencies(name)}
                for _, dep in ipairs(deps) do if dep and dep ~= "" then MarkExpected(dep) end end
            end
        end
    end
    
    for name, state in pairs(savedAddons) do if state and GetInfo(name) then MarkExpected(name) end end
    
    for i = 1, GetNum() do
        local name = GetInfo(i)
        if name and name ~= "Reflux" and name ~= "Reflux Enhanced" then
            local isEnabled = IsAddOnEnabled(name)
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
        print("|cFFFFFF00Reflux Enhanced: No addon data for this profile.|r") return
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
    
    local function IsAddOnEnabled(name)
        if C_AddOns and C_AddOns.GetAddOnEnableState then
            return C_AddOns.GetAddOnEnableState(name, playerName) > 0
        elseif GetAddOnEnableState then
            return GetAddOnEnableState(playerName, name) > 0
        else
            local _, _, _, _, reason = GetInfo(name)
            return reason ~= "DISABLED"
        end
    end
    
    local function EnableWithDeps(addonName)
        if not IsAddOnEnabled(addonName) then
            Enable(addonName) 
            Enable(addonName, playerName)
            print("  |cFF00FF00+ Enabling: " .. addonName .. "|r")
            changesMade = true
        end
        if GetDependencies then
            local deps = {GetDependencies(addonName)}
            for _, depName in ipairs(deps) do
                if depName and depName ~= "" and GetInfo(depName) then
                    if not IsAddOnEnabled(depName) then
                        Enable(depName) 
                        Enable(depName, playerName)
                        print("  |cFF88FF88  + Auto-Enabling Dependency: " .. depName .. "|r")
                        changesMade = true
                    end
                end
            end
        end
    end

    for i = 1, GetNum() do
        local name = GetInfo(i)
        if name and name ~= "Reflux" and name ~= "Reflux Enhanced" then
            if IsAddOnEnabled(name) and not savedAddons[name] then
                Disable(name) 
                Disable(name, playerName)
                print("  |cFFFF0000- Disabling: " .. name .. "|r")
                changesMade = true
            end
        end
    end
    
    for name, shouldBeEnabled in pairs(savedAddons) do
        if shouldBeEnabled and name ~= "Reflux" and name ~= "Reflux Enhanced" then
            if GetInfo(name) then EnableWithDeps(name)
            else print("  |cFF888888? Missing Addon Ignored: " .. name .. "|r") end
        end
    end

    if changesMade then
        if SaveState then SaveState() end 
        print("|cFF00FF00Reflux Enhanced: Addons updated. Reloading UI...|r")
        RefluxDB.pendingSyncProfile = profileName
        ReloadUI()
    else
        print("|cFFFFFF00Reflux Enhanced: Addons are already correct for this profile.|r")
        print("|cFFFFFF00You can now safely run: |r|cFF00FF00/reflux switch " .. profileName .. "|r")
    end
end

local function saveProfile(profileName)
    if not profileName or profileName == "" then print("Usage: /reflux save [name]") return end
    initDB()
    forceDetectVariables()
    
    print("|cFFFFFF00Reflux Enhanced: Capturing data for '" .. profileName .. "'...|r")
    
    for _, varName in ipairs(RefluxDB.emulated) do
        local vType, extra = IdentifyAddonStructure(varName)
        
        if vType == "CUSTOM" then
            local handler = extra
            local currentProfile = handler.get()
            if currentProfile ~= profileName then
                pcall(function() handler.copy(profileName) end)
            end
        elseif vType == "ACE3" then
            local db = extra
            if db.GetCurrentProfile and db.SetProfile then
                local currentProfile = db:GetCurrentProfile()
                if currentProfile ~= profileName then
                    pcall(function()
                        if db.CopyProfile then
                            db:SetProfile(profileName)
                            db:CopyProfile(currentProfile)
                        else
                            if type(db.CreateProfile) == "function" then
                                pcall(db.CreateProfile, db, profileName, true)
                            end
                            db:SetProfile(profileName)
                        end
                    end)
                end
            end
        elseif vType ~= "IGNORED" and vType then
            local data = CaptureActiveData(varName, vType, extra)
            CreateAndPopulate(varName, profileName, data, vType, extra)
            SwitchPointers(varName, profileName, vType, extra)
        end
    end

    local currentSnapshots = {}
    for _, varName in ipairs(RefluxDB.emulated) do
        local vType, _ = IdentifyAddonStructure(varName)
        if vType == "FLAT" and _G[varName] then 
            local copiedData = DeepCopy(_G[varName])
            if copiedData then
                currentSnapshots[varName] = copiedData
            end
        end
    end
    
    RefluxDB.profiles[profileName] = currentSnapshots
    
    local activeAddons = {}
    local GetNum = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local GetInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local playerName = UnitName("player")
    
    local function IsAddOnEnabled(name)
        if C_AddOns and C_AddOns.GetAddOnEnableState then
            return C_AddOns.GetAddOnEnableState(name, playerName) > 0
        elseif GetAddOnEnableState then
            return GetAddOnEnableState(playerName, name) > 0
        else
            local _, _, _, _, reason = GetInfo(name)
            return reason ~= "DISABLED"
        end
    end

    for i = 1, GetNum() do
        local name = GetInfo(i)
        if name then
            if IsAddOnEnabled(name) then 
                activeAddons[name] = true 
            end
        end
    end
    
    RefluxDB.profiles[profileName].meta = { timestamp = time(), addons = activeAddons }
    RefluxDB.activeProfile = profileName
    RefluxDB.forceNextLogin = profileName
    
    collectgarbage("collect")
    print("|cFF00FF00Reflux Enhanced: Profile '|r|cFFFFFF00" .. profileName .. "|r|cFF00FF00' saved. Reloading to write to disk...|r")
    ReloadUI()
end

local function switchProfile(profileName)
    if not profileName or not RefluxDB.profiles[profileName] then print("|cFFFF0000Reflux Enhanced: Profile not found.|r") return end
    
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
    
    print("|cFFFFFF00Reflux Enhanced: Preparing data for '" .. profileName .. "'...|r")
    
    local savedData = RefluxDB.profiles[profileName]
    for varName, content in pairs(savedData) do
        if varName ~= "meta" and _G[varName] and type(_G[varName]) == "table" then
            InjectDataInPlace(_G[varName], content, true)
        end
    end
    
    for _, varName in ipairs(RefluxDB.emulated) do
        local vType, extra = IdentifyAddonStructure(varName)
        if vType == "CUSTOM" then
            local handler = extra
            pcall(function() handler.set(profileName) end)
        elseif vType == "ACE3" then
            local db = extra
            if db.SetProfile then
                pcall(function() db:SetProfile(profileName) end)
            end
        elseif vType ~= "IGNORED" and vType then 
            SwitchPointers(varName, profileName, vType, extra) 
        end
    end
    
    RefluxDB.activeProfile = profileName
    RefluxDB.forceNextLogin = profileName
    
    local charKey = UnitName("player") .. " - " .. GetRealmName()
    RefluxDB.characterLinks[charKey] = profileName
    
    RefreshAceProfiles()
    collectgarbage("collect")
    
    print("|cFF00FF00Reflux Enhanced: Switched to '" .. profileName .. "'. Reloading UI...|r")
    ReloadUI()
end

-- =============================================================
-- MINIMAP ICON DATA BROKER
-- =============================================================

local refluxLDB = LDB:NewDataObject("RefluxEnhanced", {
    type = "data source", text = "Reflux", icon = "Interface\\AddOns\\Reflux Enhanced\\icon", 
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("Reflux Enhanced")
        tooltip:AddLine("Active: " .. (RefluxDB.activeProfile and "|cFF00FF00" .. RefluxDB.activeProfile .. "|r" or "|cFF888888None|r"))
        tooltip:AddLine(" ")
        tooltip:AddLine("|cFFeda55fLeft-Click|r to list profiles")
        tooltip:AddLine("|cFFeda55fRight-Click|r for help")
    end,
    OnClick = function(self, button) if button == "RightButton" then refluxCommandHandler("help") else refluxCommandHandler("list") end end,
})

-- =============================================================
-- SLASH COMMANDS & INITIALIZATION
-- =============================================================

function refluxCommandHandler(msg)
    local cmd, arg = string.match(msg or "", "^%s*([^%s]+)%s*(.*)$")
    cmd = cmd and string.lower(cmd) or ""
    arg = arg and arg:match("^%s*(.-)%s*$") or ""

    if cmd == "save" then
        if arg == "" then print("|cFFFF0000Reflux Enhanced: Please specify a profile name. Usage: /reflux save [name]|r") else saveProfile(arg) end
    elseif cmd == "switch" then
        if arg == "" then print("|cFFFF0000Reflux Enhanced: Please specify a profile name. Usage: /reflux switch [name]|r") else switchProfile(arg) end
    elseif cmd == "addons" then
        if arg == "" then
            if RefluxDB.activeProfile then arg = RefluxDB.activeProfile else print("|cFFFF0000Reflux Enhanced: No active profile to sync. Usage: /reflux addons [name]|r") return end
        end
        SyncAddonsOnly(arg)
    elseif cmd == "delete" then
        if arg == "" then
            print("|cFFFF0000Reflux Enhanced: Please specify a profile name. Usage: /reflux delete [name]|r")
        elseif RefluxDB.profiles[arg] then
            RefluxDB.profiles[arg] = nil
            if RefluxDB.activeProfile == arg then RefluxDB.activeProfile = nil end
            if RefluxDB.characterLinks then
                for charKey, linkedProfile in pairs(RefluxDB.characterLinks) do
                    if linkedProfile == arg then RefluxDB.characterLinks[charKey] = nil end
                end
            end
            if RefluxDB.forceNextLogin == arg then RefluxDB.forceNextLogin = nil end
            if RefluxDB.pendingSyncProfile == arg then RefluxDB.pendingSyncProfile = nil end
            print("|cFF00FF00Reflux Enhanced: Deleted profile '" .. arg .. "'. Database cleaned.|r")
        else
            print("|cFFFF0000Reflux Enhanced: Profile '" .. arg .. "' does not exist.|r")
        end
    elseif cmd == "reset" then
        RefluxDB = {}
        initDB()
        print("|cFF00FF00Reflux Enhanced: Database completely wiped. Memory freed.|r")
        ReloadUI()
    elseif cmd == "list" then
        print("|cFF00FFFF--- Reflux Enhanced Profiles ---|r")
        local count = 0
        for name, _ in pairs(RefluxDB.profiles) do
            print("  - |cFFFFFF00" .. name .. "|r" .. ((name == RefluxDB.activeProfile) and " |cFF00FF00(Active)|r" or ""))
            count = count + 1
        end
        if count == 0 then print("  |cFF888888No profiles saved yet.|r") end
    elseif cmd == "icon" then
        RefluxDB.minimap.hide = not RefluxDB.minimap.hide
        if RefluxDB.minimap.hide then
            LDBIcon:Hide("RefluxEnhanced") print("|cFFFFFF00Reflux Enhanced: Minimap icon hidden.|r")
        else
            LDBIcon:Show("RefluxEnhanced") print("|cFF00FF00Reflux Enhanced: Minimap icon shown.|r")
        end
    elseif cmd == "debug" then
        initDB()
        forceDetectVariables()
        print("|cFF00FFFF--- Reflux Enhanced: Tracked Databases ---|r")
        local count = 0
        local sortedDBs = {}
        for _, v in ipairs(RefluxDB.emulated) do table.insert(sortedDBs, v) end
        table.sort(sortedDBs)
        for _, varName in ipairs(sortedDBs) do
            local vType, _ = IdentifyAddonStructure(varName)
            local typeColor = "|cFFaaaaaa"
            if vType == "ACE3" then typeColor = "|cFFFFaa00"
            elseif vType == "INTERNAL" then typeColor = "|cFF00FF00"
            elseif vType == "SPLIT" then typeColor = "|cFF00aaff"
            elseif vType == "FLAT" then typeColor = "|cFFFF00FF"
            elseif vType == "CUSTOM" then typeColor = "|cFFff55ff"
            elseif vType == "IGNORED" then typeColor = "|cFF555555" end

            if vType then print("  " .. typeColor .. "[" .. vType .. "]|r |cFFFFFF00" .. varName .. "|r") else print("  |cFFFF0000[UNKNOWN]|r |cFFFFFF00" .. varName .. "|r") end
            count = count + 1
        end
        print("  |cFF888888Total Databases Tracked: " .. count .. "|r")
    else
        print("|cFF00FFFF--- Reflux Enhanced Commands ---|r")
        print("  |cFFFFFF00/reflux save [name]|r - Saves the current UI state")
        print("  |cFFFFFF00/reflux switch [name]|r - Switches to a saved profile")
        print("  |cFFFFFF00/reflux addons [name]|r - Syncs addons for a profile")
        print("  |cFFFFFF00/reflux delete [name]|r - Deletes a saved profile")
        print("  |cFFFFFF00/reflux reset|r - Wipes Reflux memory completely")
        print("  |cFFFFFF00/reflux list|r - Lists all saved profiles")
        print("  |cFFFFFF00/reflux debug|r - Shows all detected addon databases")
        print("  |cFFFFFF00/reflux icon|r - Toggles the minimap button")
    end
end

SlashCmdList["REFLUX"] = refluxCommandHandler
SLASH_REFLUX1 = "/reflux"

local function SilentAutoRestore(profileName)
    if not profileName or not RefluxDB.profiles[profileName] then return end
    local savedData = RefluxDB.profiles[profileName]
    
    local dbsToRestore = {}
    for _, varName in ipairs(RefluxDB.emulated) do
        local vType, _ = IdentifyAddonStructure(varName)
        if vType == "FLAT" and savedData[varName] and _G[varName] and type(_G[varName]) == "table" then
            table.insert(dbsToRestore, varName)
        end
    end
    
    if #dbsToRestore == 0 then return end

    local index = 1
    local ticker
    ticker = C_Timer.NewTicker(0.05, function()
        local varName = dbsToRestore[index]
        if varName and _G[varName] then
            InjectDataInPlace(_G[varName], savedData[varName], true)
        end
        
        index = index + 1
        if index > #dbsToRestore then
            ticker:Cancel()
        end
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    initDB()
    
    if LDBIcon and not LDBIcon:IsRegistered("RefluxEnhanced") then
        LDBIcon:Register("RefluxEnhanced", refluxLDB, RefluxDB.minimap)
    end
    
    local charKey = UnitName("player") .. " - " .. GetRealmName()
    local assignedProfile = RefluxDB.characterLinks[charKey]
    
    if RefluxDB.forceNextLogin then
        local pName = RefluxDB.forceNextLogin
        RefluxDB.forceNextLogin = nil
        C_Timer.After(1, function() print("|cFF00FF00Reflux Enhanced: '" .. pName .. "' active.|r") end)
    elseif RefluxDB.pendingSyncProfile then
        local pName = RefluxDB.pendingSyncProfile
        RefluxDB.pendingSyncProfile = nil
        C_Timer.After(2, function()
            print("|cFFFFFF00Reflux Enhanced: Addon sync complete!|r")
            print("|cFFFFFF00Action Required: Type |r|cFF00FF00/reflux switch " .. pName .. "|r|cFFFFFF00 to apply the profile data.|r")
        end)
    elseif assignedProfile then
        C_Timer.After(1.5, function()
            SilentAutoRestore(assignedProfile)
        end)
    end
end)