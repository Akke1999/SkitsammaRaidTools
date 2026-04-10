--[[
    SkitsammaRaidTools - Raid Lockout Tracker

    This addon displays raid lockout information for the current raid tier
    (Midnight Season 1). It shows all three raids with visual separators.
    Uses inter-addon communication (CHAT_MSG_ADDON) to share lockout data
    between players who have the addon installed.

    BLIZZARD POLICY COMPLIANCE NOTES:
    - Only shares the player's OWN lockout data voluntarily
    - Uses GetSavedInstanceInfo() and RequestRaidInfo() - official APIs only
    - Rate-limits addon messages (max once every 8 seconds)
    - No memory reading, no secure hooks, no input injection
    - All communication is raid-only and follows message limits
    - Data sharing is opt-in (players with addon only)
]]

local ADDON_NAME = "SkitsammaRaidTools"
local ADDON_PREFIX = "RLCK"
local MESSAGE_RATE_LIMIT = 8.0 -- seconds between broadcasts

-- ============================================================
-- RAID CONFIGURATION (Midnight Season 1)
-- Boss names must match the in-game instance/encounter names.
-- Update these when the raid tier changes.
-- ============================================================

local RAID_INSTANCES = {
    {
        name = "The Voidspire",
        shortName = "Voidspire",
        bosses = {
            "Averzian",       -- Imperator Averzian
            "Vorasius",       -- Vorasius
            "Salhadaar",      -- Fallen-King Salhadaar
            "Vaelgor",        -- Vaelgor & Ezzorak
            "Vanguard",       -- Lightblinded Vanguard
            "Crown",          -- Crown of the Cosmos
        }
    },
    {
        name = "The Dreamrift",
        shortName = "Dreamrift",
        bosses = {
            "Chimaerus",      -- Chimaerus the Undreamt God
        }
    },
    {
        name = "March on Quel'Danas",
        shortName = "Quel'Danas",
        bosses = {
            "Belo'ren",       -- Belo'ren, Child of A'lar
            "L'ura",          -- Midnight Falls (L'ura)
        }
    },
}

-- ============================================================
-- LAYOUT PRECOMPUTATION
-- ============================================================

local NAME_COL_WIDTH = 130
local BOSS_COL_WIDTH = 75
local BOSS_COL_START = 140
local RAID_GAP = 15
local ROW_HEIGHT = 22
local ROW_SPACING = 4
local HEADER_HEIGHT = 50

-- Precompute column positions, mapping, and separator positions
local COLUMN_POSITIONS = {}   -- [globalBossIdx] = x offset
local COLUMN_MAP = {}         -- [globalBossIdx] = {raidIndex, bossIndex, bossName}
local SEPARATOR_POSITIONS = {} -- x offsets for vertical separator lines
local RAID_COLUMN_RANGES = {} -- [raidIdx] = {first, last} global indices

local currentX = BOSS_COL_START
local globalBossIdx = 0

for raidIdx, raid in ipairs(RAID_INSTANCES) do
    local firstIdx = globalBossIdx + 1
    for bossIdx, bossName in ipairs(raid.bosses) do
        globalBossIdx = globalBossIdx + 1
        COLUMN_POSITIONS[globalBossIdx] = currentX
        COLUMN_MAP[globalBossIdx] = {
            raidIndex = raidIdx,
            bossIndex = bossIdx,
            bossName = bossName,
        }
        currentX = currentX + BOSS_COL_WIDTH
    end
    RAID_COLUMN_RANGES[raidIdx] = { first = firstIdx, last = globalBossIdx }
    if raidIdx < #RAID_INSTANCES then
        table.insert(SEPARATOR_POSITIONS, currentX + math.floor(RAID_GAP / 2))
        currentX = currentX + RAID_GAP
    end
end

local TOTAL_BOSSES = globalBossIdx
local CONTENT_WIDTH = currentX + 20
local FRAME_WIDTH = CONTENT_WIDTH + 64

-- ============================================================
-- DIFFICULTY CONFIGURATION
-- ============================================================

local RAID_DIFFICULTIES = {
    lfr = 17,
    normal = 14,
    heroic = 15,
    mythic = 16,
}

local DEFAULT_DIFFICULTY = "lfr"
local CURRENT_DIFFICULTY = DEFAULT_DIFFICULTY

-- Class colors: uses WoW's built-in RAID_CLASS_COLORS for accuracy

-- ============================================================
-- STATE VARIABLES
-- ============================================================

-- PlayerData structure: { [raidIndex] = { lfr={}, normal={}, heroic={}, mythic={} } }
-- Each difficulty contains a list of killed boss indices (encounter indices).
local PlayerData = {}
local CachedData = {}         -- { playerName = { data={...}, timestamp=<number> } }
local LastMessageTime = {}    -- rate limiting for broadcasts
local MainFrame = nil
local ReadyCheckInProgress = false
local WaitingForInstanceInfo = false

-- Forward declarations for functions referenced before definition
local RefreshPlayerList
local HideReadyCheckFrame

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

local function GetClassColor(class)
    local c = RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function NowTime()
    return GetTime()
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
    return nil
end

local function GetSelectedRaidDifficulty()
    local _, instanceType, instanceDifficultyID = GetInstanceInfo()
    if instanceType == "raid" and instanceDifficultyID and instanceDifficultyID > 0 then
        return instanceDifficultyID
    end
    if GetRaidDifficultyID then
        return GetRaidDifficultyID()
    end
    return nil
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

local function GetRaidIndexByName(instanceName)
    for idx, raid in ipairs(RAID_INSTANCES) do
        if raid.name == instanceName then
            return idx
        end
    end
    return nil
end

-- ============================================================
-- SERIALIZATION
-- Format: "raidIdx.difficulty:boss1,boss2;raidIdx.difficulty:boss1"
-- Only entries with killed bosses are included to keep messages short.
-- ============================================================

local function SerializeLockoutData(data)
    local parts = {}
    for raidIdx, raidData in pairs(data) do
        if type(raidIdx) == "number" and type(raidData) == "table" then
            for difficulty, bosses in pairs(raidData) do
                if type(bosses) == "table" and #bosses > 0 then
                    local bossStr = table.concat(bosses, ",")
                    table.insert(parts, raidIdx .. "." .. difficulty .. ":" .. bossStr)
                end
            end
        end
    end
    return table.concat(parts, ";")
end

local function DeserializeLockoutData(serialized)
    -- Initialize empty data for all known raids
    local data = {}
    for raidIdx = 1, #RAID_INSTANCES do
        data[raidIdx] = { lfr = {}, normal = {}, heroic = {}, mythic = {} }
    end

    if not serialized or serialized == "" then
        return data
    end

    for part in string.gmatch(serialized, "[^;]+") do
        local raidStr, rest = string.match(part, "(%d+)%.(.*)")
        if raidStr and rest then
            local raidIdx = tonumber(raidStr)
            local difficulty, bosses = string.match(rest, "([^:]+):(.*)")
            if raidIdx and difficulty and data[raidIdx] and data[raidIdx][difficulty] then
                data[raidIdx][difficulty] = {}
                if bosses and bosses ~= "" then
                    for boss in string.gmatch(bosses, "[^,]+") do
                        table.insert(data[raidIdx][difficulty], tonumber(boss))
                    end
                end
            end
        end
    end

    return data
end

-- ============================================================
-- LOCKOUT DETECTION & CACHE
-- ============================================================

local function InitPlayerData()
    PlayerData = {}
    for raidIdx = 1, #RAID_INSTANCES do
        PlayerData[raidIdx] = { lfr = {}, normal = {}, heroic = {}, mythic = {} }
    end
end

local function UpdateOwnLockoutData()
    local numSavedInstances = GetNumSavedInstances and GetNumSavedInstances() or 0

    -- Initialize fresh data for all raids
    local newData = {}
    for raidIdx = 1, #RAID_INSTANCES do
        newData[raidIdx] = { lfr = {}, normal = {}, heroic = {}, mythic = {} }
    end

    for i = 1, numSavedInstances do
        local name, _, _, difficultyID, locked, _, _, isRaid, _, _, numEncounters = GetSavedInstanceInfo(i)

        if name and isRaid and locked then
            local difficultyName = GetDifficultyNameFromID(difficultyID)
            if difficultyName then
                local raidIdx = GetRaidIndexByName(name)
                if raidIdx then
                    -- Merge kills (handles LFR wings that share the same instance name)
                    for encounterIndex = 1, (numEncounters or 0) do
                        local _, _, isKilled = GetSavedInstanceEncounterInfo(i, encounterIndex)
                        if isKilled then
                            local found = false
                            for _, existing in ipairs(newData[raidIdx][difficultyName]) do
                                if existing == encounterIndex then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(newData[raidIdx][difficultyName], encounterIndex)
                            end
                        end
                    end
                end
            end
        end
    end

    PlayerData = newData
end

local function RequestOwnLockoutUpdate()
    if WaitingForInstanceInfo then
        return
    end
    WaitingForInstanceInfo = true
    RequestRaidInfo()
end

local function GetPlayerLockoutData(playerName)
    playerName = NormalizePlayerName(playerName)
    if playerName == GetLocalPlayerName() then
        return PlayerData
    end
    if CachedData[playerName] then
        return CachedData[playerName].data
    end
    return nil
end

local function IsPlayerLocked(playerName, raidIndex, bossIndex, difficulty)
    -- Returns true  = boss is available (player has NOT killed it)
    -- Returns false = boss is killed (player HAS killed it / locked out)
    -- Returns nil   = no data available
    playerName = NormalizePlayerName(playerName)

    local allData
    if playerName == GetLocalPlayerName() then
        allData = PlayerData
    elseif CachedData[playerName] then
        allData = CachedData[playerName].data
    end

    if not allData or not allData[raidIndex] then
        return nil
    end

    local killedBosses = allData[raidIndex][difficulty] or {}

    for _, bid in ipairs(killedBosses) do
        if bid == bossIndex then
            return false -- boss HAS been killed
        end
    end

    return true -- boss has NOT been killed (available)
end

-- ============================================================
-- UI CREATION & MANAGEMENT
-- ============================================================

local function CreateMainFrame()
    if MainFrame then
        return MainFrame
    end

    -- BasicFrameTemplateWithInset provides backdrop, title area, inset, and a close button.
    -- We do NOT create a second close button.
    MainFrame = CreateFrame("Frame", "SkitsammaRaidToolsFrame", UIParent, "BasicFrameTemplateWithInset")
    MainFrame:SetSize(FRAME_WIDTH, 550)
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

    -- Reset state when frame is hidden (by any means, including the template close button)
    MainFrame:HookScript("OnHide", function()
        ReadyCheckInProgress = false
    end)

    -- Restore saved position
    if SkitsammaRaidToolsDB and SkitsammaRaidToolsDB.framePos then
        local pos = SkitsammaRaidToolsDB.framePos
        MainFrame:ClearAllPoints()
        MainFrame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end

    -- Title
    local title = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -8)
    MainFrame.titleString = title
    UpdateTitle()

    -- --------------------------------------------------------
    -- HEADER SECTION (fixed, does not scroll)
    -- --------------------------------------------------------
    local headerFrame = CreateFrame("Frame", nil, MainFrame)
    headerFrame:SetPoint("TOPLEFT", 12, -30)
    headerFrame:SetPoint("TOPRIGHT", -32, -30)
    headerFrame:SetHeight(HEADER_HEIGHT)
    MainFrame.headerFrame = headerFrame

    -- "Player" label
    local playerLabel = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playerLabel:SetPoint("BOTTOMLEFT", 10, 5)
    playerLabel:SetWidth(NAME_COL_WIDTH)
    playerLabel:SetJustifyH("LEFT")
    playerLabel:SetText("Player")
    playerLabel:SetTextColor(1, 0.82, 0)

    -- Raid name headers (centered across their boss columns)
    for raidIdx, raid in ipairs(RAID_INSTANCES) do
        local range = RAID_COLUMN_RANGES[raidIdx]
        local x1 = COLUMN_POSITIONS[range.first]
        local x2 = COLUMN_POSITIONS[range.last] + BOSS_COL_WIDTH
        local width = x2 - x1

        local raidLabel = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        raidLabel:SetPoint("TOPLEFT", x1, -2)
        raidLabel:SetWidth(width)
        raidLabel:SetJustifyH("CENTER")
        raidLabel:SetText(raid.shortName)
        raidLabel:SetTextColor(1, 0.82, 0) -- gold

        -- Underline beneath raid name for visual grouping
        local underline = headerFrame:CreateTexture(nil, "ARTWORK")
        underline:SetColorTexture(1, 0.82, 0, 0.4)
        underline:SetHeight(1)
        underline:SetPoint("TOPLEFT", raidLabel, "BOTTOMLEFT", 5, -1)
        underline:SetPoint("TOPRIGHT", raidLabel, "BOTTOMRIGHT", -5, -1)
    end

    -- Boss name headers (per column)
    for gIdx = 1, TOTAL_BOSSES do
        local col = COLUMN_MAP[gIdx]
        local bossLabel = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bossLabel:SetPoint("BOTTOMLEFT", COLUMN_POSITIONS[gIdx], 5)
        bossLabel:SetWidth(BOSS_COL_WIDTH)
        bossLabel:SetJustifyH("CENTER")
        bossLabel:SetText(col.bossName)
        bossLabel:SetTextColor(0.85, 0.85, 0.85)
    end

    -- Horizontal separator under header
    local headerLine = MainFrame:CreateTexture(nil, "ARTWORK")
    headerLine:SetColorTexture(0.4, 0.4, 0.4, 0.8)
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", 12, -(30 + HEADER_HEIGHT))
    headerLine:SetPoint("TOPRIGHT", -32, -(30 + HEADER_HEIGHT))

    -- Vertical separators between raids (span from header to bottom)
    for _, sepX in ipairs(SEPARATOR_POSITIONS) do
        local sep = MainFrame:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        sep:SetWidth(1)
        sep:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 12 + sepX, -30)
        sep:SetPoint("BOTTOMLEFT", MainFrame, "BOTTOMLEFT", 12 + sepX, 12)
    end

    -- --------------------------------------------------------
    -- SCROLL SECTION (scrollable player list)
    -- --------------------------------------------------------
    local scrollFrame = CreateFrame("ScrollFrame", nil, MainFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 12, -(30 + HEADER_HEIGHT + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", -32, 12)
    MainFrame.scrollFrame = scrollFrame

    local contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetSize(CONTENT_WIDTH, 1)
    scrollFrame:SetScrollChild(contentFrame)
    MainFrame.contentFrame = contentFrame

    MainFrame.playerRows = {}
    MainFrame:Hide()

    return MainFrame
end

local function ClearPlayerRows()
    if not MainFrame or not MainFrame.contentFrame then
        return
    end
    for _, row in ipairs(MainFrame.playerRows or {}) do
        row:Hide()
    end
    MainFrame.playerRows = {}
end

local function AddPlayerRow(playerName, class, hasAddon)
    if not MainFrame or not MainFrame.contentFrame then
        return
    end

    local rowIndex = #MainFrame.playerRows
    local row = CreateFrame("Frame", nil, MainFrame.contentFrame)
    row:SetSize(CONTENT_WIDTH, ROW_HEIGHT)

    if rowIndex > 0 then
        local lastRow = MainFrame.playerRows[rowIndex]
        row:SetPoint("TOPLEFT", lastRow, "BOTTOMLEFT", 0, -ROW_SPACING)
    else
        row:SetPoint("TOPLEFT", MainFrame.contentFrame, "TOPLEFT", 0, 0)
    end

    -- Subtle alternating row background for readability
    if rowIndex % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.03)
    end

    -- Player name (class colored)
    local nameString = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameString:SetPoint("LEFT", 10, 0)
    nameString:SetWidth(NAME_COL_WIDTH)
    nameString:SetJustifyH("LEFT")
    nameString:SetText(playerName)

    nameString:SetTextColor(GetClassColor(class))

    row.nameString = nameString
    row.playerName = playerName
    row.hasAddon = hasAddon

    if not hasAddon then
        -- Show "No Addon" once, centered across the entire boss column area
        local noAddonStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        local startX = COLUMN_POSITIONS[1]
        local endX = COLUMN_POSITIONS[TOTAL_BOSSES] + BOSS_COL_WIDTH
        noAddonStr:SetPoint("LEFT", startX, 0)
        noAddonStr:SetWidth(endX - startX)
        noAddonStr:SetJustifyH("CENTER")
        noAddonStr:SetText("No Addon")
        noAddonStr:SetTextColor(0.5, 0.5, 0.5)
    else
        -- Boss columns: show kill status per boss
        local data = GetPlayerLockoutData(playerName)

        for gIdx = 1, TOTAL_BOSSES do
            local col = COLUMN_MAP[gIdx]
            local bossString = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            bossString:SetPoint("LEFT", COLUMN_POSITIONS[gIdx], 0)
            bossString:SetWidth(BOSS_COL_WIDTH)
            bossString:SetJustifyH("CENTER")

            if data then
                local isAvailable = IsPlayerLocked(playerName, col.raidIndex, col.bossIndex, CURRENT_DIFFICULTY)
                if isAvailable == nil then
                    bossString:SetText("-")
                    bossString:SetTextColor(0.5, 0.5, 0.5)
                elseif isAvailable then
                    -- Green: boss not killed yet (available)
                    bossString:SetText(GetDifficultyLetter())
                    bossString:SetTextColor(0, 1, 0)
                else
                    -- Red: boss already killed (locked out)
                    bossString:SetText(GetDifficultyLetter())
                    bossString:SetTextColor(1, 0, 0)
                end
            else
                bossString:SetText("-")
                bossString:SetTextColor(0.5, 0.5, 0.5)
            end

            row["bossString" .. gIdx] = bossString
        end
    end

    table.insert(MainFrame.playerRows, row)

    -- Adjust content frame height to fit all rows
    local contentHeight = #MainFrame.playerRows * (ROW_HEIGHT + ROW_SPACING)
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

-- ============================================================
-- ADDON COMMUNICATION
-- ============================================================

local function SendLockoutData(force)
    if not IsAddonActiveForCurrentGroup() then
        return
    end

    local now = NowTime()
    if not force and LastMessageTime["broadcast"] and (now - LastMessageTime["broadcast"]) < MESSAGE_RATE_LIMIT then
        return
    end

    local data = SerializeLockoutData(PlayerData)
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
    if channel ~= "RAID" then
        return
    end
    if not IsAddonActiveForCurrentGroup() then
        return
    end

    sender = NormalizePlayerName(sender)
    if sender == GetLocalPlayerName() then
        return
    end

    local data = DeserializeLockoutData(message)
    if data then
        CachedData[sender] = {
            data = data,
            timestamp = NowTime(),
        }
    end

    -- Refresh the display if frame is already open
    if MainFrame and MainFrame:IsShown() then
        RefreshPlayerList()
    end
end

-- ============================================================
-- EVENT HANDLERS
-- ============================================================

local function OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then
        return
    end

    -- Initialize SavedVariables
    if not SkitsammaRaidToolsDB then
        SkitsammaRaidToolsDB = {
            framePos = nil,
            difficulty = DEFAULT_DIFFICULTY,
        }
        print("|cFF00FF00SkitsammaRaidTools:|r Created new SavedVariables database.")
    else
        print("|cFF00FF00SkitsammaRaidTools:|r Loaded existing SavedVariables. Difficulty: " .. (SkitsammaRaidToolsDB.difficulty or DEFAULT_DIFFICULTY))
    end

    CURRENT_DIFFICULTY = SkitsammaRaidToolsDB.difficulty or DEFAULT_DIFFICULTY

    -- Register addon communication prefix
    C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

    -- Initialize player data structure for all raids
    InitPlayerData()

    DetectRaidDifficulty()
    if IsAddonActiveForCurrentGroup() then
        UpdateOwnLockoutData()
        RequestOwnLockoutUpdate()
    end
end

local function OnReadyCheck()
    -- Ready check started: fetch and broadcast lockout data.
    -- The frame does NOT automatically pop up; use /rlock to open it.
    DetectRaidDifficulty()

    if not IsAddonActiveForCurrentGroup() then
        return
    end

    UpdateOwnLockoutData()
    RequestOwnLockoutUpdate()
    SendLockoutData(true) -- force send on ready check

    -- Refresh if frame is already open
    if MainFrame and MainFrame:IsShown() then
        RefreshPlayerList()
    end
end

local function OnReadyCheckFinished()
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
    DetectRaidDifficulty()
    UpdateOwnLockoutData()

    -- Clear cached data from other players to force refresh
    CachedData = {}

    if not IsAddonActiveForCurrentGroup() then
        HideReadyCheckFrame()
        return
    end

    RequestOwnLockoutUpdate()
end

-- ============================================================
-- SLASH COMMANDS
-- ============================================================

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

-- ============================================================
-- EVENT INITIALIZATION
-- ============================================================

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
