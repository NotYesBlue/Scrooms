-- Scroom Catch UI for Matcha

local Players = game:GetService("Players")
local LocalPlayer = Players and Players.LocalPlayer
local RunService = game:GetService("RunService")

if not LocalPlayer then
    warn("[ScroomCatch] Join the game before running this script.")
    return
end

local state = _G.__SCROOM_UI_STATE or {}
state.version = (state.version or 0) + 1
_G.__SCROOM_UI_STATE = state

pcall(function()
    if state.heartbeat then
        state.heartbeat:Disconnect()
    end
end)

pcall(function()
    UI.RemoveTab("Scroom Catch")
end)

local function getSpeed()
    if UI.GetValue("sc_instant_progress") then
        return 100000
    end

    return tonumber(UI.GetValue("sc_progress_speed")) or 50
end

local playerGui

local function getPlayerGui()
    if not playerGui or not playerGui.Parent then
        playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    end

    return playerGui
end

local function isMinigameActive(name)
    local gui = getPlayerGui()
    return gui and gui:FindFirstChild(name) ~= nil
end

local function getAutoRingDelay()
    return tonumber(UI.GetValue("sc_auto_ring_delay")) or 0.58
end

local mainGcCache
local mainWatchdogClock = 0
local mainWatchdogRescanAt = 0
local instantMainApplied = false

local function applyInstantMain(active)
    if not UI.GetValue("sc_instant_progress") or instantMainApplied then
        return
    end

    local drainOk, drainWrites = pcall(applygc, active, "_drainMult", 0)
    local unlockOk, unlockWrites = pcall(applygc, active, "_locked", false)
    local progressOk, progressWrites = pcall(applygc, active, "_progress", 1)

    if drainOk and unlockOk and progressOk and (tonumber(progressWrites) or 0) > 0 then
        instantMainApplied = true
        print("[ScroomCatch] instant catch applied; writes",
            tostring(progressWrites), tostring(drainWrites), tostring(unlockWrites))
    else
        warn("[ScroomCatch] instant catch apply failed or wrote nothing:",
            tostring(progressWrites), tostring(drainWrites), tostring(unlockWrites))
    end
end

local function patchMainMinigame()
    if not isMinigameActive("MainMinigame") then
        return 0
    end

    local active = mainGcCache
    if not active then
        active = findgc("_progressMult", {
            _progressMult = "number",
            _drainMult = "number",
            _progress = "number",
            _locked = "boolean",
            _zone = "table",
            _marker = "table",
            _item = "table",
            _rope = "table"
        })
    end

    if not active or #active == 0 then
        return 0
    end

    mainGcCache = active

    local gainOk, gainChanged = pcall(function()
        return applygc(active, "_progressMult", getSpeed())
    end)

    local lossOk = pcall(function()
        return applygc(
            active,
            "_drainMult",
            UI.GetValue("sc_no_loss") and 0 or 1
        )
    end)

    if UI.GetValue("sc_skip_start_lock") then
        pcall(applygc, active, "_locked", false)
    end

    if not gainOk or not lossOk then
        mainGcCache = nil
        mainWatchdogRescanAt = tick() + 1
        return 0
    end

    applyInstantMain(active)
    return gainChanged or 0
end

local wasMainActive = false
local tuneGcCache
local tunePatchApplied = false
local tuneWatchdogRescanAt = 0
local tuneScanAttempts = 0
local TUNE_RESCAN_DELAY = 0.12
local wasRingActive = isMinigameActive("RingMinigame")
local ringAutoClock = 0
local ringAutoPending = false
local autoStartClickDue = nil
local autoStartAwaitingUi = false
local autoStartRetryAt = nil
local autoStartRecoveryAt = nil
local autoStartAttempts = 0
local AUTO_START_MAX_ATTEMPTS = 3
local AUTO_START_RETRY_DELAY = 0.8
local AUTO_START_RECOVERY_DELAY = 2.5

local function clearTuneCaches()
    tuneGcCache = nil
    tunePatchApplied = false
    tuneWatchdogRescanAt = 0
    tuneScanAttempts = 0
end

local function clearAutoStart()
    autoStartClickDue = nil
    autoStartAwaitingUi = false
    autoStartRetryAt = nil
    autoStartRecoveryAt = nil
    autoStartAttempts = 0
end

local function queueAutoStart(delay)
    if not UI.GetValue("sc_enabled")
        or not UI.GetValue("sc_auto_start_ring") then
        clearAutoStart()
        return
    end

    autoStartAwaitingUi = false
    autoStartRetryAt = nil
    autoStartRecoveryAt = nil
    autoStartAttempts = 0
    autoStartClickDue = tick() + (delay or 0.35)
end

local function hasCatchMinigameOpen()
    return isMinigameActive("RingMinigame")
        or isMinigameActive("TuningMinigame")
        or isMinigameActive("MainMinigame")
end

local function finishMainMinigame()
    if not UI.GetValue("sc_enabled") or not isMinigameActive("MainMinigame") then
        return 0
    end

    local active = mainGcCache
    if not active then
        active = findgc("_progressMult", {
            _progressMult = "number",
            _drainMult = "number",
            _progress = "number",
            _locked = "boolean",
            _zone = "table",
            _marker = "table",
            _item = "table",
            _rope = "table"
        })
    end

    if not active or #active == 0 then
        return 0
    end

    mainGcCache = active
    pcall(applygc, active, "_drainMult", 0)
    pcall(applygc, active, "_locked", false)

    local ok, changed = pcall(applygc, active, "_progress", 1)
    if not ok then
        mainGcCache = nil
        return 0
    end

    return changed or 0
end

local function maintainMainPatch(deltaTime)
    if not isMinigameActive("MainMinigame") then
        mainWatchdogClock = 0
        mainWatchdogRescanAt = 0
        mainGcCache = nil
        instantMainApplied = false
        return
    end

    mainWatchdogClock = mainWatchdogClock + deltaTime
    if mainWatchdogClock < 0.15 then
        return
    end
    mainWatchdogClock = 0

    local active = mainGcCache
    if not active then
        if tick() < mainWatchdogRescanAt then
            return
        end
        mainWatchdogRescanAt = tick() + 1
        active = findgc("_progressMult", {
            _progressMult = "number",
            _drainMult = "number",
            _progress = "number",
            _locked = "boolean",
            _zone = "table",
            _marker = "table",
            _item = "table",
            _rope = "table"
        })

        if not active or #active == 0 then
            return
        end

        mainGcCache = active
    end

    local gainOk = pcall(applygc, active, "_progressMult", getSpeed())
    local lossOk = pcall(
        applygc,
        active,
        "_drainMult",
        UI.GetValue("sc_no_loss") and 0 or 1
    )

    if UI.GetValue("sc_skip_start_lock") then
        pcall(applygc, active, "_locked", false)
    end

    applyInstantMain(active)

    if not gainOk or not lossOk then
        mainGcCache = nil
        mainWatchdogRescanAt = tick() + 1
    end
end

local function maintainTunePatch()
    if not isMinigameActive("TuningMinigame") then
        clearTuneCaches()
        return
    end

    local instantTune = UI.GetValue("sc_instant_tune")
    if not instantTune then
        return
    end

    if tunePatchApplied then
        return
    end

    local active = tuneGcCache
    if not active then
        if tick() < tuneWatchdogRescanAt or tuneScanAttempts >= 2 then
            return
        end

        tuneScanAttempts = tuneScanAttempts + 1
        tuneWatchdogRescanAt = tick() + TUNE_RESCAN_DELAY
        active = findgc("_targetTime", {
            _targetTime = "number",
            _elapsed = "number",
            _target = "number",
            _needleX = "number",
            _needleVel = "number",
            _purity = "number",
            _dwell = "number",
            _ui = "table"
        })

        if not active or #active == 0 then
            if tuneScanAttempts >= 2 then
                print("[ScroomCatch] frequency controller not found after 2 scans")
            end
            return
        end

        tuneGcCache = active
    end

    local okElapsed, changed = pcall(applygc, active, "_elapsed", 999)
    local writeCount = tonumber(changed) or 0
    if okElapsed and writeCount > 0 then
        tunePatchApplied = true
        print("[ScroomCatch] frequency: elapsed forced; writes", tostring(writeCount))
    else
        tuneGcCache = nil
        tuneWatchdogRescanAt = tick() + TUNE_RESCAN_DELAY
        if tuneScanAttempts >= 2 then
            print("[ScroomCatch] frequency patch did not update elapsed after 2 scans")
        end
    end
end

local function runPatchNow()
    if not UI.GetValue("sc_enabled") then
        return 0
    end

    if isMinigameActive("MainMinigame") then
        mainGcCache = nil
        return patchMainMinigame()
    end

    if isMinigameActive("TuningMinigame") and UI.GetValue("sc_instant_tune") then
        clearTuneCaches()
        maintainTunePatch()
        return tunePatchApplied and 1 or 0
    end

    if isMinigameActive("RingMinigame")
        and UI.GetValue("sc_auto_ring") then
        ringAutoClock = 0
        ringAutoPending = true
        return 1
    end

    return 0
end

local autoStartKeybind
local lastAutoStartToggleAt = 0

local function toggleAutoStartFromKeybind()
    local now = tick()
    if now - lastAutoStartToggleAt < 0.25 then
        return
    end

    lastAutoStartToggleAt = now
    local enabled = not UI.GetValue("sc_auto_start_ring")
    UI.SetValue("sc_auto_start_ring", enabled)

    if not enabled or not UI.GetValue("sc_enabled") then
        clearAutoStart()
    elseif isMinigameActive("MainMinigame") then
        wasMainActive = true
    elseif not hasCatchMinigameOpen() then
        queueAutoStart(0.35)
    else
        clearAutoStart()
    end

    print("[ScroomCatch] Auto Start :", enabled and "ON" or "OFF")
end

UI.AddTab("Scroom Catch", function(tab)
    local settings = tab:Section("Catch Settings", "Left")

    settings:Toggle("sc_enabled", "Enabled", true, function(enabled)
        -- Do not reuse a controller that belonged to an earlier minigame.
        mainGcCache = nil
        instantMainApplied = false
        clearTuneCaches()
        mainWatchdogClock = 0
        mainWatchdogRescanAt = 0
        ringAutoPending = false
        clearAutoStart()

        if enabled and UI.GetValue("sc_auto_start_ring") then
            if isMinigameActive("MainMinigame") then
                wasMainActive = true
            elseif not hasCatchMinigameOpen() then
                queueAutoStart(0.35)
            else
                clearAutoStart()
            end
        end
    end)
    settings:Toggle("sc_auto_ring", "Auto Ring Minigame", false, function(enabled)
        if enabled and UI.GetValue("sc_enabled")
            and isMinigameActive("RingMinigame") then
            ringAutoClock = 0
            ringAutoPending = true
        else
            ringAutoPending = false
        end
    end)
    settings:SliderFloat(
        "sc_auto_ring_delay",
        "Auto Ring Delay (seconds)",
        0.1,
        0.58,
        0.58,
        "%.2f"
    )
    settings:Toggle("sc_auto_start_ring", "Auto Start", false, function(enabled)
        if not enabled or not UI.GetValue("sc_enabled") then
            clearAutoStart()
            return
        end

        if isMinigameActive("MainMinigame") then
            wasMainActive = true
            return
        end

        if hasCatchMinigameOpen() then
            return
        end

        queueAutoStart(0.35)
    end)
    autoStartKeybind = settings:Keybind(
        "sc_patch_key",
        state.patchKey or 0x50,
        "click"
    )
    autoStartKeybind:AddToHotkey("Auto Start", "sc_auto_start_ring")
    settings:SliderInt(
        "sc_progress_speed",
        "Progress Speed",
        1,
        50,
        50,
        function()
            if UI.GetValue("sc_enabled") then
                runPatchNow()
            end
        end
    )
    settings:Toggle("sc_instant_progress", "Instant Catch", false, function()
        instantMainApplied = false
        if UI.GetValue("sc_enabled") then
            runPatchNow()
        end
    end)
    settings:Toggle("sc_instant_tune", "Instant Frequency Minigame", false, function(enabled)
        if enabled then
            clearTuneCaches()
        else
            tunePatchApplied = false
        end
    end)
    settings:Toggle("sc_skip_start_lock", "Skip Main Start Lock", true, function()
        if UI.GetValue("sc_enabled") then
            runPatchNow()
        end
    end)

    settings:Toggle("sc_no_loss", "Prevent Progress Loss", true, function()
        if UI.GetValue("sc_enabled") then
            runPatchNow()
        end
    end)
    settings:Button("Finish Main Minigame", function()
        print("[ScroomCatch] finish main:", finishMainMinigame())
    end)
    local actions = tab:Section("Actions", "Right")
    actions:Button("Reset", function()
        UI.SetValue("sc_progress_speed", 50)
        UI.SetValue("sc_instant_progress", false)
        UI.SetValue("sc_instant_tune", false)
        UI.SetValue("sc_skip_start_lock", true)
        UI.SetValue("sc_no_loss", true)
        UI.SetValue("sc_auto_ring", false)
        UI.SetValue("sc_auto_ring_delay", 0.58)
        UI.SetValue("sc_auto_start_ring", false)
        UI.SetValue("sc_enabled", false)
    end)
end)

local version = state.version
local wasTuningActive = false
local keyWasActive = false

state.heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
    if not _G.__SCROOM_UI_STATE
        or _G.__SCROOM_UI_STATE.version ~= version then
        state.heartbeat:Disconnect()
        return
    end

    if not UI.GetValue("sc_enabled") then
        keyWasActive = false
    elseif autoStartKeybind then
        local key = autoStartKeybind:GetKey()
        if key ~= nil then
            state.patchKey = key
        end

        local keyActive = autoStartKeybind:IsEnabled()
        if keyActive and not keyWasActive then
            toggleAutoStartFromKeybind()
        end
        keyWasActive = keyActive
    end

    local mainActive = isMinigameActive("MainMinigame")
    if mainActive and not wasMainActive then
        -- A newly-created UI means the old GC table is no longer trustworthy.
        mainGcCache = nil
        mainWatchdogClock = 0.15
        mainWatchdogRescanAt = 0
        instantMainApplied = false
    end
    if wasMainActive and not mainActive
        and UI.GetValue("sc_enabled")
        and UI.GetValue("sc_auto_start_ring") then
        -- The game blocks Cast for 0.75 seconds after a catch ends.
        queueAutoStart(0.9)
    end
    wasMainActive = mainActive

    local anyCatchMinigame = hasCatchMinigameOpen()
    if anyCatchMinigame and autoStartAwaitingUi then
        autoStartAwaitingUi = false
        autoStartRetryAt = nil
        autoStartRecoveryAt = nil
        autoStartAttempts = 0
    end

    if autoStartClickDue and tick() >= autoStartClickDue then
        autoStartClickDue = nil
        if UI.GetValue("sc_enabled")
            and UI.GetValue("sc_auto_start_ring")
            and not anyCatchMinigame then
            local clicked, clickError = pcall(mouse1click)
            autoStartAttempts = autoStartAttempts + 1
            autoStartAwaitingUi = true
            autoStartRetryAt = tick() + AUTO_START_RETRY_DELAY
            if clicked then
                print("[ScroomCatch] auto start cast click sent; attempt", autoStartAttempts)
            else
                warn("[ScroomCatch] auto start click failed:", clickError)
            end
        end
    end

    if autoStartAwaitingUi
        and autoStartRetryAt
        and tick() >= autoStartRetryAt then
        autoStartAwaitingUi = false
        autoStartRetryAt = nil
        if not anyCatchMinigame
            and autoStartAttempts < AUTO_START_MAX_ATTEMPTS then
            autoStartClickDue = tick() + 0.2
        elseif not anyCatchMinigame then
            autoStartRecoveryAt = tick() + AUTO_START_RECOVERY_DELAY
        end
    end

    if autoStartRecoveryAt and tick() >= autoStartRecoveryAt then
        autoStartRecoveryAt = nil
        if UI.GetValue("sc_enabled")
            and UI.GetValue("sc_auto_start_ring")
            and not anyCatchMinigame then
            print("[ScroomCatch] auto start watchdog: retrying after no minigame appeared")
            queueAutoStart(0.25)
        end
    end

    local ringActive = isMinigameActive("RingMinigame")
    if ringActive and not wasRingActive then
        ringAutoClock = 0
        ringAutoPending = UI.GetValue("sc_enabled")
            and UI.GetValue("sc_auto_ring")
    elseif not ringActive then
        ringAutoClock = 0
        ringAutoPending = false
    end
    wasRingActive = ringActive

    if ringActive and ringAutoPending then
        ringAutoClock = ringAutoClock + deltaTime
        if ringAutoClock >= getAutoRingDelay() then
            if UI.GetValue("sc_enabled") and UI.GetValue("sc_auto_ring") then
                pcall(mouse1click)
            end
            ringAutoPending = false
        end
    end

    local tuningActive = isMinigameActive("TuningMinigame")
    if tuningActive and not wasTuningActive then
        clearTuneCaches()
    end
    wasTuningActive = tuningActive

    local ok, err = pcall(function()
        if not UI.GetValue("sc_enabled") then
            return
        end

        -- Keeps a live main controller patched without repeated full-GC scans.
        maintainTunePatch()
        maintainMainPatch(deltaTime)
    end)

    if not ok then
        warn("[ScroomCatch] heartbeat error:", err)
    end
end)

print("[ScroomCatch] Scrooms Script Loaded")
