--[[
    SkitsammaRaidTools - Complete Addon Implementation
    
    This addon displays raid lockout information during ready checks.
    It uses inter-addon communication (CHAT_MSG_ADDON) to share lockout data
    between players who have the addon installed.
    More to come in the future, but this is a solid foundation for the core functionality.
    
    BLIZZARD POLICY COMPLIANCE NOTES:
    - Only shares the player's OWN lockout data voluntarily
    - Uses GetSavedInstanceInfo() and RequestRaidInfo() - official APIs only
    - Rate-limits addon messages (max once every 8 seconds per player)
    - No memory reading, no secure hooks, no input injection
    - All communication is raid-only and follows message limits
    - Data sharing is opt-in (players with addon only)
]]

local ADDON_NAME = "SkitsammaRaidTools"
local ADDON_PREFIX = "RLCK"
local MESSAGE_RATE_LIMIT = 8.0 -- seconds
local DATA_EXPIRY = 30.0 -- seconds
local MAX_BOSSES = 8

-- Difficulty IDs for current retail raid tiers
local RAID_DIFFICULTIES = {
    lfr = 17,
    normal = 14,
    heroic = 15,
    mythic = 16
}

local DEFAULT_DIFFICULTY = "lfr"
local CURRENT_DIFFICULTY = DEFAULT_DIFFICULTY

-- Current state
local PlayerData = {}
local CachedData = {} -- { playerName = { data, timestamp } }
local LastMessageTime = {} -- { playerName = timestamp } for rate limiting
local CurrentReadyCheck = nil
local MainFrame = nil
local ReadyCheckInProgress = false
local WaitingForInstanceInfo = false

local RefreshPlayerList
local HideReadyCheckFrame

-- Raid boss configuration (current raid tier)
-- For April 2026, assuming latest raid with 8 bosses
local RAID_BOSSES = {
    "Boss 1",
    "Boss 2",
    "Boss 3",
    "Boss 4",
    "Boss 5",
    "Boss 6",
    "Boss 7",
    "Boss 8"
}

-- Class colors for player names (official WoW colors)
local CLASS_COLORS = {
    WARRIOR = {1.0, 0.49, 0.04},
    PALADIN = {0.96, 0.55, 0.73},
    HUNTER = {0.67, 0.83, 0.45},
    ROGUE = {1.0, 0.96, 0.41},
    PRIEST = {1.0, 1.0, 1.0},
    DEATHKNIGHT = {0.77, 0.12, 0.23},
    SHAMAN = {0.0, 0.44, 0.87},
    MAGE = {0.41, 0.8, 0.94},
    WARLOCK = {0.58, 0.51, 0.79},
    MONK = {0.0, 1.0, 0.59},
    DRUID = {1.0, 0.49, 0.04},
    DEMONHUNTER = {0.64, 0.19, 0.79},
    EVOKER = {0.3, 0.6, 0.96}
}

--[[
    ============================================================
    UTILITY & SERIALIZATION FUNCTIONS
    ============================================================
]]

local function GetPlayerClass(unitToken)
    local _, class = UnitClass(unitToken)
    return class
end

local function NormalizePlayerName(name)
    if not name or name == "" then
        return nil
    end

    if Ambiguate then
        return Ambiguate(name, "short")
    end

    return string.match(name, "^[^-]+") or name
end

local function GetLocalPlayerName()
    return NormalizePlayerName(UnitName("player"))
end

local function GetCurrentRaidInstanceName()
    local instanceName, instanceType = GetInstanceInfo()
    if instanceType == "raid" and instanceName and instanceName ~= "" then
        return instanceName
    end

    return nil
end

local function GetPlayerColor(class)
    return CLASS_COLORS[class] or {0.5, 0.5, 0.5}
end

local function NowTime()
    return GetTime()
end

local function UpdateTitle()
    if not MainFrame or not MainFrame.titleString then
        return
    end

    local prettyDifficulty
    if CURRENT_DIFFICULTY == "lfr" then
        prettyDifficulty = "LFR"
    else
        prettyDifficulty = string.upper(string.sub(CURRENT_DIFFICULTY, 1, 1)) .. string.sub(CURRENT_DIFFICULTY, 2)
    end
    MainFrame.titleString:SetText("Raid Lockout Status (" .. prettyDifficulty .. ")")
end

local function GetDifficultyLetter()
    if CURRENT_DIFFICULTY == "lfr" then
        return "L"
    elseif CURRENT_DIFFICULTY == "normal" then
        return "N"
    elseif CURRENT_DIFFICULTY == "heroic" then
        return "H"
    elseif CURRENT_DIFFICULTY == "mythic" then
        return "M"
    end
    return "N"
end

local function GetDifficultyNameFromID(difficultyID)
    if difficultyID == RAID_DIFFICULTIES.lfr then
        return "lfr"
    elseif difficultyID == RAID_DIFFICULTIES.normal then
        return "normal"
    elseif difficultyID == RAID_DIFFICULTIES.heroic then
        return "heroic"
    elseif difficultyID == RAID_DIFFICULTIES.mythic then
        return "mythic"
    end
end

local function GetSelectedRaidDifficulty()
    local _, instanceType, instanceDifficultyID = GetInstanceInfo()
    if instanceType == "raid" and instanceDifficultyID and instanceDifficultyID > 0 then
        return instanceDifficultyID
    end

    if GetRaidDifficultyID then
        return GetRaidDifficultyID()
    end
end

local function IsSupportedRaidDifficulty(difficultyID)
    return difficultyID == RAID_DIFFICULTIES.lfr
        or difficultyID == RAID_DIFFICULTIES.normal
        or difficultyID == RAID_DIFFICULTIES.heroic
end

local function IsAddonActiveForCurrentGroup()
    if not IsInRaid() then
        return false
    end

    return IsSupportedRaidDifficulty(GetSelectedRaidDifficulty())
end

local function DetectRaidDifficulty()
    local difficultyID = GetSelectedRaidDifficulty()
    local newDifficulty = GetDifficultyNameFromID(difficultyID)

    if newDifficulty and newDifficulty ~= CURRENT_DIFFICULTY then
        CURRENT_DIFFICULTY = newDifficulty
        SkitsammaRaidToolsDB.difficulty = newDifficulty
        if MainFrame then
            UpdateTitle()
            if MainFrame:IsShown() then
                RefreshPlayerList()
            end
        end
        print("|cFF00FF00SkitsammaRaidTools:|r Auto-detected raid difficulty: " .. string.upper(newDifficulty))
    end
end

local function SerializeLockoutData(data)
    -- Simple serialization: "instanceID:boss1,boss2,boss3" for each difficulty
    -- Format: "{lfr:1,2}|{normal:1,2,3}|{heroic:1,2}|{mythic:1}"
    local parts = {}
    for difficulty, bosses in pairs(data) do
        if difficulty == "lfr" or difficulty == "normal" or difficulty == "heroic" or difficulty == "mythic" then
            local bossStr = table.concat(bosses, ",")
            table.insert(parts, difficulty .. ":" .. bossStr)
        end
    end
    return table.concat(parts, "|")
end

local function DeserializeLockoutData(serialized)
    local data = {}
    for part in string.gmatch(serialized, "[^|]+") do
        local difficulty, bosses = string.match(part, "([^:]+):(.*)")
        if difficulty then
            data[difficulty] = {}
            if bosses and bosses ~= "" then
                for boss in string.gmatch(bosses, "[^,]+") do
                    table.insert(data[difficulty], tonumber(boss) or boss)
                end
            end
        end
    end
    return data
end

--[[
    ============================================================
    LOCKOUT DETECTION & CACHE FUNCTIONS
    ============================================================
]]

local function UpdateOwnLockoutData()
    local currentRaidName = GetCurrentRaidInstanceName()
    local numSavedInstances = GetNumSavedInstances and GetNumSavedInstances() or 0
    local nextPlayerData = {
        instanceName = currentRaidName,
        lfr = {},
        normal = {},
        heroic = {},
        mythic = {}
    }

    for i = 1, numSavedInstances do
        local name, _, _, difficultyID, locked, _, _, isRaid, _, _, numEncounters, _, _, instanceID = GetSavedInstanceInfo(i)

        if name and isRaid and locked then
            local difficultyName
            if difficultyID == RAID_DIFFICULTIES.lfr then
                difficultyName = "lfr"
            elseif difficultyID == RAID_DIFFICULTIES.normal then
                difficultyName = "normal"
            elseif difficultyID == RAID_DIFFICULTIES.heroic then
                difficultyName = "heroic"
            elseif difficultyID == RAID_DIFFICULTIES.mythic then
                difficultyName = "mythic"
            end

            if difficultyName then
                local shouldUseInstance = false

                if currentRaidName then
                    shouldUseInstance = name == currentRaidName
                else
                    shouldUseInstance = nextPlayerData.instanceName == nil or nextPlayerData.instanceName == name
                end

                if shouldUseInstance then
                    nextPlayerData.instanceName = name
                    nextPlayerData.instanceID = instanceID
                    wipe(nextPlayerData[difficultyName])

                    for encounterIndex = 1, (numEncounters or 0) do
                        local _, _, isKilled = GetSavedInstanceEncounterInfo(i, encounterIndex)
                        if isKilled then
                            table.insert(nextPlayerData[difficultyName], encounterIndex)
                        end
                    end
                end
            end
        end
    end

    PlayerData = nextPlayerData
end

local function RequestOwnLockoutUpdate()
    if WaitingForInstanceInfo then
        return
    end

    WaitingForInstanceInfo = true
    RequestRaidInfo()
end

local function GetPlayerLockoutData(playerName)
    -- Returns { normal = {1,2,3}, heroic = {1,2}, mythic = {1} }
    playerName = NormalizePlayerName(playerName)

    if playerName == GetLocalPlayerName() then
        return PlayerData, false
    end

    if CachedData[playerName] then
        local data, timestamp = CachedData[playerName].data, CachedData[playerName].timestamp
        if NowTime() - timestamp < DATA_EXPIRY then
            return data, false -- not stale
        else
            return data, true -- stale
        end
    end
    return nil, false
end

local function IsPlayerLocked(playerName, boss, difficulty)
    -- Returns true if player IS locked to boss on this difficulty
    -- (i.e., player has NOT killed this boss)
    playerName = NormalizePlayerName(playerName)

    local data = (playerName == GetLocalPlayerName()) and PlayerData or (CachedData[playerName] and CachedData[playerName].data)
    
    if not data then
        return nil
    end
    
    local lockedBosses = data[difficulty] or {}
    
    -- Check if this boss is in the locked list (killed list)
    for _, boss_id in ipairs(lockedBosses) do
        if boss_id == boss then
            return false -- player HAS killed this boss, so NOT locked
        end
    end
    
    return true -- player has NOT killed this boss, so IS locked
end

--[[
    ============================================================
    UI CREATION & MANAGEMENT
    ============================================================
]]

local function CreateMainFrame()
    if MainFrame then
        return MainFrame
    end
    
    -- Create main frame
    MainFrame = CreateFrame("Frame", "SkitsammaRaidToolsFrame", UIParent, "BasicFrameTemplateWithInset")
    MainFrame:SetSize(900, 500)
    MainFrame:SetPoint("CENTER")
    MainFrame:SetMovable(true)
    MainFrame:EnableMouse(true)
    MainFrame:RegisterForDrag("LeftButton")
    MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
    MainFrame:SetScript("OnDragStop", function()
        MainFrame:StopMovingOrSizing()
        if SkitsammaRaidToolsDB then
            local point, _, relPoint, x, y = MainFrame:GetPoint(1)
            SkitsammaRaidToolsDB.framePos = {point, relPoint, x, y}
        end
    end)
    
    -- Restore saved position
    if SkitsammaRaidToolsDB and SkitsammaRaidToolsDB.framePos then
        local pos = SkitsammaRaidToolsDB.framePos
        MainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end
    
    -- The BasicFrameTemplateWithInset already provides the backdrop styling
    -- SetBackdrop was removed in patch 12.x, so we rely on the template
    
    -- Title
    local title = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -8)
    MainFrame.titleString = title
    MainFrame.playerRows = {}
    UpdateTitle()
    
    -- Close button
    local closeBtn = CreateFrame("Button", nil, MainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        MainFrame:Hide()
        ReadyCheckInProgress = false
    end)
    
    -- Scroll frame for player list
    local scrollFrame = CreateFrame("ScrollFrame", nil, MainFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 12, -32)
    scrollFrame:SetPoint("BOTTOMRIGHT", -32, 12)
    MainFrame.scrollFrame = scrollFrame
    
    -- Content frame
    local contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetSize(900, 1)
    scrollFrame:SetScrollChild(contentFrame)
    MainFrame.contentFrame = contentFrame
    
    MainFrame:Hide()
    
    return MainFrame
end

local function ClearPlayerRows()
    if not MainFrame or not MainFrame.contentFrame then
        return
    end
    
    for _, row in ipairs(MainFrame.playerRows or {}) do
        row:Hide()
        row = nil
    end
    MainFrame.playerRows = {}
end

local function AddPlayerRow(playerName, class, hasAddon)
    if not MainFrame or not MainFrame.contentFrame then
        return
    end
    
    local lastRow = MainFrame.playerRows[#MainFrame.playerRows]
    
    local row = CreateFrame("Frame", nil, MainFrame.contentFrame)
    row:SetSize(850, 25)
    if lastRow then
        row:SetPoint("TOPLEFT", lastRow, "BOTTOMLEFT", 0, -5)
    else
        row:SetPoint("TOPLEFT", MainFrame.contentFrame, "TOPLEFT", 0, 0)
    end
    
    -- Player name (class colored)
    local nameString = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameString:SetPoint("LEFT", 10, 0)
    nameString:SetWidth(150)
    nameString:SetText(playerName)
    
    local color = GetPlayerColor(class)
    nameString:SetTextColor(color[1], color[2], color[3])
    
    row.nameString = nameString
    row.playerName = playerName
    row.hasAddon = hasAddon
    
    -- Boss columns (8 bosses)
    for bossNum = 1, MAX_BOSSES do
        local offsetX = 160 + (bossNum - 1) * 80
        local bossString = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        bossString:SetPoint("LEFT", offsetX, 0)
        bossString:SetWidth(60)
        bossString:SetJustifyH("CENTER")
        
        -- Determine display text
        if not hasAddon then
            bossString:SetText("NO ADDON")
            bossString:SetTextColor(1, 0, 0)
        else
            local data, isStale = GetPlayerLockoutData(playerName)
            if isStale then
                bossString:SetText("DATA IS OVER 30s OLD")
                bossString:SetTextColor(1, 0, 0)
                bossString:SetWidth(130)
                break -- Don't draw more columns if data is stale
            elseif data then
                local isLocked = IsPlayerLocked(playerName, bossNum, CURRENT_DIFFICULTY)
                if isLocked == nil then
                    bossString:SetText("-")
                    bossString:SetTextColor(0.5, 0.5, 0.5)
                elseif isLocked then
                    -- Green for not locked (hasn't killed this boss)
                    bossString:SetText(GetDifficultyLetter())
                    bossString:SetTextColor(0, 1, 0)
                else
                    -- Red for locked (has killed this boss)
                    bossString:SetText(GetDifficultyLetter())
                    bossString:SetTextColor(1, 0, 0)
                end
            else
                bossString:SetText("-")
                bossString:SetTextColor(0.5, 0.5, 0.5)
            end
        end
        
        row["bossString" .. bossNum] = bossString
    end
    
    table.insert(MainFrame.playerRows, row)
    
    -- Adjust content frame height
    local contentHeight = #MainFrame.playerRows * 30
    MainFrame.contentFrame:SetHeight(math.max(contentHeight, 1))
end

function RefreshPlayerList()
    ClearPlayerRows()
    
    if not IsAddonActiveForCurrentGroup() then
        return
    end
    
    for i = 1, GetNumGroupMembers() do
        local unitToken = "raid" .. i
        local playerName = NormalizePlayerName(UnitName(unitToken))
        local _, class = UnitClass(unitToken)
        
        if playerName then
            local hasAddon = playerName == GetLocalPlayerName() or CachedData[playerName] ~= nil
            AddPlayerRow(playerName, class, hasAddon)
        end
    end
end

local function ShowReadyCheckFrame()
    if not IsAddonActiveForCurrentGroup() then
        HideReadyCheckFrame()
        return
    end

    if not MainFrame then
        CreateMainFrame()
    end
    
    RefreshPlayerList()
    MainFrame:Show()
    ReadyCheckInProgress = true
end

function HideReadyCheckFrame()
    if MainFrame then
        MainFrame:Hide()
    end
    ReadyCheckInProgress = false
end

--[[
    ============================================================
    ADDON COMMUNICATION
    ============================================================
]]

local function SerializeOwnData()
    return SerializeLockoutData(PlayerData)
end

local function SendLockoutData(force)
    if not IsAddonActiveForCurrentGroup() then
        return
    end
    
    -- Rate limiting: don't send to the same player more than once per 8 seconds
    local now = NowTime()
    if not force and LastMessageTime["broadcast"] and (now - LastMessageTime["broadcast"]) < MESSAGE_RATE_LIMIT then
        return
    end
    
    local data = SerializeOwnData()

    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, data, "RAID")
    LastMessageTime["broadcast"] = now
end

local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then
        return
    end
    
    if not message or message == "" then
        return
    end
    
    -- Only accept messages from supported raid groups
    if channel ~= "RAID" then
        return
    end

    if not IsAddonActiveForCurrentGroup() then
        return
    end
    
    -- Don't process our own messages
    sender = NormalizePlayerName(sender)

    if sender == GetLocalPlayerName() then
        return
    end
    
    -- Deserialize and cache the data
    local data = DeserializeLockoutData(message)
    if data then
        CachedData[sender] = {
            data = data,
            timestamp = NowTime()
        }
    end
    
    -- Refresh player list if frame is shown
    if MainFrame and MainFrame:IsShown() then
        RefreshPlayerList()
    end
end

--[[
    ============================================================
    EVENT HANDLERS
    ============================================================
]]

local function OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then
        return
    end
    
    -- Initialize SavedVariables
    if not SkitsammaRaidToolsDB then
        SkitsammaRaidToolsDB = {
            framePos = nil,
            difficulty = DEFAULT_DIFFICULTY
        }
        print("|cFF00FF00SkitsammaRaidTools:|r Created new SavedVariables database.")
    else
        print("|cFF00FF00SkitsammaRaidTools:|r Loaded existing SavedVariables. Difficulty: " .. (SkitsammaRaidToolsDB.difficulty or DEFAULT_DIFFICULTY))
    end
    
    CURRENT_DIFFICULTY = SkitsammaRaidToolsDB.difficulty or DEFAULT_DIFFICULTY
    
    -- Register addon communication
    C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

    DetectRaidDifficulty()
    if IsAddonActiveForCurrentGroup() then
        -- Build from any cached info immediately, then ask the server for a fresh copy.
        UpdateOwnLockoutData()
        RequestOwnLockoutUpdate()
    end
end

local function OnReadyCheck()
    -- A ready check has started
    DetectRaidDifficulty()
    if not IsAddonActiveForCurrentGroup() then
        HideReadyCheckFrame()
        return
    end
    UpdateOwnLockoutData()
    ShowReadyCheckFrame()
    RequestOwnLockoutUpdate()
    SendLockoutData()
end

local function OnReadyCheckFinished()
    -- Ready check has ended
    -- Frame remains open for manual close
    ReadyCheckInProgress = false
end

local function OnGroupRosterUpdate()
    DetectRaidDifficulty()
    if not IsAddonActiveForCurrentGroup() then
        HideReadyCheckFrame()
        return
    end

    UpdateOwnLockoutData()
    if MainFrame and MainFrame:IsShown() then
        RefreshPlayerList()
    end
end

local function OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
    if success then
        -- Ask the server for updated lockout data after a successful kill.
        DetectRaidDifficulty()
        if not IsAddonActiveForCurrentGroup() then
            return
        end
        RequestOwnLockoutUpdate()
    end
end

local function OnUpdateInstanceInfo()
    -- Fresh saved-instance data is now available from the server.
    WaitingForInstanceInfo = false
    DetectRaidDifficulty()
    UpdateOwnLockoutData()
    if not IsAddonActiveForCurrentGroup() then
        HideReadyCheckFrame()
        return
    end
    if MainFrame and MainFrame:IsShown() then
        RefreshPlayerList()
    end
    if IsAddonActiveForCurrentGroup() then
        SendLockoutData(true)
    end
end

local function OnPlayerEnteringWorld()
    -- Player changed zones; rebuild what we can locally and then request a refresh.
    DetectRaidDifficulty()
    UpdateOwnLockoutData()
    
    -- Clear cached data when entering world to force refresh
    CachedData = {}

    if not IsAddonActiveForCurrentGroup() then
        HideReadyCheckFrame()
        return
    end

    RequestOwnLockoutUpdate()
end

--[[
    ============================================================
    SLASH COMMANDS
    ============================================================
]]

local function HandleSlashCommand(msg)
    msg = string.lower(msg or "")
    
    if msg == "" or msg == "toggle" then
        if MainFrame and MainFrame:IsShown() then
            HideReadyCheckFrame()
            print("|cFF00FF00SkitsammaRaidTools:|r Frame hidden.")
        else
            if IsAddonActiveForCurrentGroup() then
                ShowReadyCheckFrame()
                print("|cFF00FF00SkitsammaRaidTools:|r Frame shown.")
            else
                print("|cFFFF0000SkitsammaRaidTools:|r Inactive outside LFR/Normal/Heroic raid groups.")
            end
        end
    elseif msg == "lfr" or msg == "normal" or msg == "heroic" or msg == "mythic" then
        print("|cFF00FF00SkitsammaRaidTools:|r Difficulty is auto-detected from the current raid difficulty.")
    elseif msg == "status" then
        local selectedDifficulty = GetDifficultyNameFromID(GetSelectedRaidDifficulty()) or "unknown"
        print("|cFF00FF00SkitsammaRaidTools Status:|r")
        print("  Current Difficulty (runtime): " .. CURRENT_DIFFICULTY)
        print("  Selected Raid Difficulty: " .. selectedDifficulty)
        print("  In Raid: " .. tostring(IsInRaid()))
        print("  Active For Current Group: " .. tostring(IsAddonActiveForCurrentGroup()))
        print("  Frame Shown: " .. tostring(MainFrame and MainFrame:IsShown()))
    else
        print("|cFF00FF00SkitsammaRaidTools:|r Usage: /rlock [toggle|status]")
    end
end

--[[
    ============================================================
    EVENT INITIALIZATION
    ============================================================
]]

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("READY_CHECK")
frame:RegisterEvent("READY_CHECK_FINISHED")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UPDATE_INSTANCE_INFO")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        OnAddonLoaded(...)
    elseif event == "READY_CHECK" then
        OnReadyCheck()
    elseif event == "READY_CHECK_FINISHED" then
        OnReadyCheckFinished()
    elseif event == "GROUP_ROSTER_UPDATE" then
        OnGroupRosterUpdate()
    elseif event == "ENCOUNTER_END" then
        OnEncounterEnd(...)
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "PLAYER_ENTERING_WORLD" then
        OnPlayerEnteringWorld()
    elseif event == "UPDATE_INSTANCE_INFO" then
        OnUpdateInstanceInfo()
    end
end)

-- Register slash commands
SLASH_SKITSAMMARAIDTOOLS1 = "/rlock"
SlashCmdList["SKITSAMMARAIDTOOLS"] = HandleSlashCommand

print("|cFF00FF00SkitsammaRaidTools addon loaded. Use /rlock for options.|r")
