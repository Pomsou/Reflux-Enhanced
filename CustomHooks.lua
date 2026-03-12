if not _G.RefluxEnhancedAPI then return end

-- 1. Opulent Casting Bars
_G.RefluxEnhancedAPI:RegisterCustomAddon(
    "OpulentCastingBarsDB", 
    {
        api = function() return _G.OpulentCastingBarsDB and _G.OpulentCastingBarsCharDB end,
        get = function()
            if SCB and SCB.Profiles then return SCB.Profiles:GetCurrent() end
            return _G.OpulentCastingBarsCharDB.__currentProfile or "Default"
        end,
        set = function(name)
            if SCB and SCB.Profiles then 
                SCB.Profiles:Switch(name) 
            end
        end,
        copy = function(name)
            if SCB and SCB.Profiles then 
                local current = SCB.Profiles:GetCurrent()
                if current == name then return end 
                
                local allProfiles = SCB.Profiles:GetAll()
                for _, p in ipairs(allProfiles) do 
                    if p == name then SCB.Profiles:Delete(name) break end 
                end
                SCB.Profiles:New(name, true) 
            end
        end
    },
    {"OpulentCastingBarsCharDB"} -- Ignored
)

-- 2. Frogski's Cursor Trail
_G.RefluxEnhancedAPI:RegisterCustomAddon(
    "FrogskisCursorTrailDB",
    {
        api = function() return _G.FrogskisCursorTrail2 and _G.FrogskisCursorTrail2.db end,
        get = function() return _G.FrogskisCursorTrail2.db:GetCurrentProfile() end,
        set = function(name) 
            _G.FrogskisCursorTrail2.db:SetProfile(name)
            if _G.FrogskisCursorTrail2.Refresh then _G.FrogskisCursorTrail2:Refresh() end
        end,
        copy = function(name) 
            local current = _G.FrogskisCursorTrail2.db:GetCurrentProfile()
            if current == name then return end 
            _G.FrogskisCursorTrail2.db:SetProfileAccountWide(name, true)
        end
    },
    {"FrogskisCursorTrailAccountDB"} -- Ignored
)

-- 4. DandersFrames
_G.RefluxEnhancedAPI:RegisterCustomAddon(
    "DandersFramesDB",
    {
        api = function() return _G.DandersFrames end,
        get = function() return _G.DandersFrames:GetCurrentProfile() end,
        set = function(name)
            _G.DandersFrames:SetProfile(name)
        end,
        copy = function(name)
            local DF = _G.DandersFrames
            local current = DF:GetCurrentProfile()
            
            if current == name then return end 

            if DF.DeleteProfile then DF:DeleteProfile(name) end
            
            DF:DuplicateProfile(name)
        end
    },
    {"DandersFramesCharDB", "DandersFramesClickCastingDB"}
)

-- 4. BasicMinimap
_G.RefluxEnhancedAPI:RegisterCustomAddon(
    "BasicMinimapSV",
    {
        api = function() return _G.BasicMinimap and _G.BasicMinimap.db end,
        get = function() return _G.BasicMinimap.db:GetCurrentProfile() end,
        set = function(name) 

            pcall(function() _G.BasicMinimap.db:SetProfile(name) end) 
        end,
        copy = function(name)
            local db = _G.BasicMinimap.db
            local current = db:GetCurrentProfile()
            
            if current == name then return end 

            pcall(function() db:SetProfile(name) end)
            pcall(function() 
                if db.CopyProfile then db:CopyProfile(current) end 
            end)
        end
    }
)

-- =============================================================
-- THIRD-PARTY BUG HOTFIXES
-- =============================================================

-- HOTFIX: Prevent Frogski's Cursor Trail from sabotaging its own profiles.
local fctFix = CreateFrame("Frame")
fctFix:RegisterEvent("ADDON_LOADED")
fctFix:RegisterEvent("PLAYER_LOGIN")
fctFix:SetScript("OnEvent", function(self, event)
    if _G.FrogskisCursorTrail2 and _G.FrogskisCursorTrail2.UpdateConditionOverride and not self.patched then
        local orig = _G.FrogskisCursorTrail2.UpdateConditionOverride
        _G.FrogskisCursorTrail2.UpdateConditionOverride = function(fctSelf)
            local conds = _G.FrogskisCursorTrailDB and _G.FrogskisCursorTrailDB.conditions or {}
            if #conds == 0 then return end 
            orig(fctSelf)
        end
        self.patched = true
    end
end)