---@omw-context global

local core = require("openmw.core")
local I = require("openmw.interfaces")

local M = {}

local API_MAJOR = 1
local PREFERRED_API_MINOR = 5
local EMIT_API_MINOR = 3
local MAX_SAFE_INTEGER = 9007199254740991

local unpackValues = table.unpack or unpack

local FALLBACK_PRESETS = {
    frost = {
        style = "smooth",
        radius = 6,
        outerColor = { 0.20, 0.65, 1.00 },
        coreColor = { 0.82, 0.96, 1.15 },
        baseColor = { 0.04, 0.13, 0.22 },
        coreRatio = 0.30,
        intensity = 1.25,
        opacity = 0.92,
        baseOpacity = 0.12,
        depthSoftness = 3,
        fogInfluence = 0.70,
    },
    fire = {
        style = "plasma",
        radius = 8,
        outerColor = { 1.00, 0.18, 0.025 },
        coreColor = { 1.35, 0.82, 0.28 },
        baseColor = { 0.28, 0.035, 0.005 },
        coreRatio = 0.22,
        intensity = 1.65,
        opacity = 0.95,
        baseOpacity = 0.12,
        depthSoftness = 3,
        fogInfluence = 0.25,
        styleScale = 10,
    },
    lightning = {
        style = "electric",
        radius = 5,
        outerColor = { 0.26, 0.52, 1.00 },
        coreColor = { 1.05, 1.22, 1.45 },
        baseColor = { 0.04, 0.09, 0.22 },
        coreRatio = 0.18,
        intensity = 1.75,
        opacity = 1.00,
        baseOpacity = 0.06,
        depthSoftness = 2,
        fogInfluence = 0.30,
        styleScale = 12,
    },
    laser = {
        style = "smooth",
        radius = 3,
        outerColor = { 1.00, 0.08, 0.04 },
        coreColor = { 1.40, 0.85, 0.70 },
        baseColor = { 0.24, 0.015, 0.008 },
        coreRatio = 0.22,
        intensity = 1.80,
        opacity = 1.00,
        baseOpacity = 0.08,
        depthSoftness = 1,
        fogInfluence = 0.20,
    },
    fishing_line = {
        style = "filament",
        radius = 0.10,
        minPixelWidth = 0.75,
        outerColor = { 0.36, 0.43, 0.50 },
        coreColor = { 0.78, 0.84, 0.90 },
        baseColor = { 0.11, 0.13, 0.15 },
        coreRatio = 0.35,
        intensity = 0.45,
        opacity = 0.80,
        baseOpacity = 0.35,
        depthSoftness = 1,
        fogInfluence = 1,
    },
    energy_blade = {
        style = "smooth",
        radius = 6,
        outerColor = { 0.05, 0.45, 1.00 },
        coreColor = { 1.15, 1.35, 1.60 },
        baseColor = { 0.02, 0.10, 0.22 },
        coreRatio = 0.50,
        intensity = 2.20,
        opacity = 1.00,
        baseOpacity = 0.10,
        depthSoftness = 2,
        fogInfluence = 0.25,
    },
}

local APPEARANCE_FIELDS = {
    "radius",
    "startRadius",
    "endRadius",
    "minPixelWidth",
    "outerColor",
    "coreColor",
    "coreRatio",
    "intensity",
    "opacity",
    "baseColor",
    "baseOpacity",
    "startFadeLength",
    "endFadeLength",
    "depthSoftness",
    "fogInfluence",
    "style",
    "styleScale",
    "plasmaFlowSpeed",
    "plasmaNoise",
    "seed",
    "originGlow",
    "longitudinal",
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function optionNumber(value, fallback, minimum, maximum)
    if not finiteNumber(value) then
        return fallback
    end
    return math.max(minimum, math.min(maximum, value))
end

local function now()
    local getRealTime = core.getRealTime
    if type(getRealTime) == "function" then
        local ok, value = pcall(getRealTime)
        if ok and finiteNumber(value) then
            return value
        end
    end

    local getSimulationTime = core.getSimulationTime
    if type(getSimulationTime) == "function" then
        local ok, value = pcall(getSimulationTime)
        if ok and finiteNumber(value) then
            return value
        end
    end
    return 0
end

local function guardedField(value, key)
    if value == nil then
        return nil, false
    end
    local ok, field = pcall(function()
        return value[key]
    end)
    return field, ok
end

local function copyPosition(value)
    local x, okX = guardedField(value, "x")
    local y, okY = guardedField(value, "y")
    local z, okZ = guardedField(value, "z")
    if not okX
        or not okY
        or not okZ
        or not finiteNumber(x)
        or not finiteNumber(y)
        or not finiteNumber(z)
    then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function copyColor(value)
    local first, okFirst = guardedField(value, 1)
    local second, okSecond = guardedField(value, 2)
    local third, okThird = guardedField(value, 3)
    if not okFirst
        or not okSecond
        or not okThird
        or not finiteNumber(first)
        or not finiteNumber(second)
        or not finiteNumber(third)
    then
        local named = copyPosition(value)
        if named == nil then
            return nil
        end
        first, second, third = named.x, named.y, named.z
    end
    if not finiteNumber(first)
        or not finiteNumber(second)
        or not finiteNumber(third)
    then
        return nil
    end
    return { first, second, third }
end

local function copyTable(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, child in pairs(value) do
        if type(child) == "table" then
            local nested = {}
            for nestedKey, nestedValue in pairs(child) do
                nested[nestedKey] = nestedValue
            end
            result[key] = nested
        else
            result[key] = child
        end
    end
    return result
end

local function detail(path, reason, message)
    return {
        path = path,
        reason = reason,
        message = message,
    }
end

local function derivedColors(color)
    local source = copyColor(color)
    if source == nil then
        return nil
    end
    for index = 1, 3 do
        if source[index] < 0 or source[index] > 4 then
            return nil
        end
    end

    local coreColor = {}
    local baseColor = {}
    for index = 1, 3 do
        coreColor[index] = math.min(4, 0.75 + source[index] * 0.45)
        baseColor[index] = math.min(1, source[index] * 0.22)
    end
    return source, coreColor, baseColor
end

local function presetAppearance(name)
    if name == nil then
        return {}
    end
    if type(name) ~= "string" or FALLBACK_PRESETS[name] == nil then
        return nil
    end
    return copyTable(FALLBACK_PRESETS[name])
end

local function mergedAppearance(spec)
    local appearance = presetAppearance(spec.preset)
    if appearance == nil then
        return nil, detail(
            "preset",
            "unknown_preset",
            "This older BeamFX fallback does not recognize that preset"
        )
    end

    if spec.color ~= nil then
        local outerColor, coreColor, baseColor = derivedColors(spec.color)
        if outerColor == nil then
            return nil, detail(
                "color",
                "invalid_color",
                "color must contain three finite components in the range 0..4"
            )
        end
        appearance.outerColor = outerColor
        appearance.coreColor = coreColor
        appearance.baseColor = baseColor
    end

    for _, field in ipairs(APPEARANCE_FIELDS) do
        if spec[field] ~= nil then
            appearance[field] = copyTable(spec[field])
        end
    end
    return appearance
end

local function pointList(spec)
    local hasPair = spec.from ~= nil or spec.to ~= nil
    local hasPoints = spec.points ~= nil
    if hasPair == hasPoints then
        return nil, detail(
            "points",
            "ambiguous_geometry",
            "Supply either from/to or points, but not both"
        )
    end

    if hasPair then
        local from = copyPosition(spec.from)
        local to = copyPosition(spec.to)
        if from == nil then
            return nil, detail(
                "from",
                "invalid_position",
                "from must contain finite x, y, and z values"
            )
        end
        if to == nil then
            return nil, detail(
                "to",
                "invalid_position",
                "to must contain finite x, y, and z values"
            )
        end
        return { from, to }
    end

    if type(spec.points) ~= "table" then
        return nil, detail(
            "points",
            "invalid_path",
            "points must be an array containing at least two positions"
        )
    end
    local count = #spec.points
    if count < 2 or count > 256 then
        return nil, detail(
            "points",
            "invalid_path",
            "points must contain between 2 and 256 positions"
        )
    end

    local points = {}
    for index = 1, count do
        points[index] = copyPosition(spec.points[index])
        if points[index] == nil then
            return nil, detail(
                "points[" .. tostring(index) .. "]",
                "invalid_position",
                "Each point must contain finite x, y, and z values"
            )
        end
    end
    return points
end

local function distance(left, right)
    local x = right.x - left.x
    local y = right.y - left.y
    local z = right.z - left.z
    return math.sqrt(x * x + y * y + z * z)
end

local function segmentsForPoints(points, appearance)
    local segments = {}
    local pathOffset = 0
    for index = 1, #points - 1 do
        local segment = {
            startPos = points[index],
            endPos = points[index + 1],
        }
        for field, value in pairs(appearance) do
            segment[field] = copyTable(value)
        end
        if type(appearance.longitudinal) == "table" then
            segment.longitudinal = copyTable(appearance.longitudinal)
            local baseOffset = segment.longitudinal.pathOffset or 0
            segment.longitudinal.pathOffset = baseOffset + pathOffset
        end
        segments[index] = segment
        pathOffset = pathOffset + distance(points[index], points[index + 1])
    end
    return segments
end

function M.new(options)
    if type(options) ~= "table" then
        error("BeamFX adapter options must be a table")
    end
    if type(options.producerId) ~= "string" or options.producerId == "" then
        error("BeamFX adapter requires a namespaced producerId")
    end

    local retryMinimum = optionNumber(
        options.retryMinimumSeconds,
        0.25,
        0.10,
        10
    )
    local retryMaximum = optionNumber(
        options.retryMaximumSeconds,
        5,
        retryMinimum,
        60
    )
    local warningInterval = optionNumber(
        options.warningIntervalSeconds,
        30,
        1,
        3600
    )
    local reconstructionRetry = optionNumber(
        options.reconstructionRetrySeconds,
        1,
        0.10,
        60
    )
    local logger = options.logger
    local reconstruct = options.reconstruct

    local state = {
        active = true,
        producer = nil,
        api = nil,
        apiMinor = nil,
        providerEpoch = nil,
        lastError = "provider_unavailable",
        nextRetryAt = 0,
        retryDelay = retryMinimum,
        warningTimes = {},
        needsReconstruction = true,
        reconstructionReason = "initial_registration",
        nextReconstructionAt = 0,
        reconstructing = false,
        emitSerial = 0,
    }

    local adapter = {}

    local function logWarning(key, message)
        local currentTime = now()
        local last = state.warningTimes[key]
        if last ~= nil and currentTime - last < warningInterval then
            return
        end
        state.warningTimes[key] = currentTime
        local line = "[" .. (options.displayName or options.producerId)
            .. "] " .. message
        if type(logger) == "function" then
            local ok = pcall(logger, line)
            if ok then
                return
            end
        end
        print(line)
    end

    local function scheduleRetry(errorCode, message)
        state.lastError = errorCode or "provider_unavailable"
        state.nextRetryAt = now() + state.retryDelay
        state.retryDelay = math.min(retryMaximum, state.retryDelay * 2)
        if message ~= nil then
            logWarning(state.lastError, message)
        end
    end

    local function markForReconstruction(reason)
        state.needsReconstruction = true
        state.reconstructionReason = reason or "producer_reacquired"
        state.nextReconstructionAt = 0
    end

    local function discardProducer(reason)
        state.producer = nil
        state.api = nil
        state.providerEpoch = nil
        markForReconstruction(reason)
    end

    local function inspectProvider()
        local api, found = guardedField(I, "BeamFX")
        if not found or api == nil then
            return nil, nil, "provider_unavailable"
        end

        local major, hasMajor = guardedField(api, "apiMajor")
        local minor, hasMinor = guardedField(api, "apiMinor")
        local register, hasRegister = guardedField(api, "registerProducer")
        local providerEpoch, hasEpoch = guardedField(api, "providerEpoch")
        local spaceKeyForCell, hasSpaceHelper =
            guardedField(api, "spaceKeyForCell")

        if not hasMajor or major ~= API_MAJOR then
            return nil, nil, "unsupported_api"
        end
        if not hasMinor
            or not finiteNumber(minor)
            or minor < 0
            or minor ~= math.floor(minor)
            or not hasRegister
            or type(register) ~= "function"
            or not hasEpoch
            or type(providerEpoch) ~= "function"
            or not hasSpaceHelper
            or type(spaceKeyForCell) ~= "function"
        then
            return nil, nil, "unsupported_api"
        end
        return api, minor
    end

    local function readEpoch(api)
        local providerEpoch = guardedField(api, "providerEpoch")
        if type(providerEpoch) ~= "function" then
            return nil, "unsupported_api"
        end
        local ok, epoch, err = pcall(providerEpoch)
        if not ok then
            return nil, "provider_unavailable"
        end
        if type(epoch) ~= "string" or epoch == "" then
            return nil, err or "provider_reset"
        end
        return epoch
    end

    local function ensureProducer()
        if not state.active then
            return nil, "adapter_inactive"
        end

        local currentTime = now()
        if state.producer == nil and currentTime < state.nextRetryAt then
            return nil, state.lastError
        end

        local api, minor, providerError = inspectProvider()
        if api == nil then
            if state.producer ~= nil then
                discardProducer(providerError)
            end
            scheduleRetry(
                providerError,
                providerError == "unsupported_api"
                    and "BeamFX API major 1 is unavailable; gameplay continues without beam visuals"
                    or "BeamFX is unavailable; gameplay continues without beam visuals"
            )
            return nil, providerError
        end

        local epoch, epochError = readEpoch(api)
        if epoch == nil then
            if state.producer ~= nil then
                discardProducer(epochError)
            end
            scheduleRetry(
                epochError,
                "BeamFX is resetting; beam visuals will retry automatically"
            )
            return nil, epochError
        end

        if state.producer ~= nil and state.providerEpoch == epoch then
            state.api = api
            state.apiMinor = minor
            return state.producer
        end

        if state.producer ~= nil then
            discardProducer("provider_epoch_changed")
            state.nextRetryAt = 0
        end
        if currentTime < state.nextRetryAt then
            return nil, state.lastError
        end

        local register = guardedField(api, "registerProducer")
        local requestedMinor = math.min(PREFERRED_API_MINOR, minor)
        local ok, producer, registrationError = pcall(register, {
            id = options.producerId,
            displayName = options.displayName or options.producerId,
            apiMajor = API_MAJOR,
            apiMinor = requestedMinor,
        })
        if not ok then
            scheduleRetry(
                "provider_unavailable",
                "BeamFX registration raised an error; visuals will retry"
            )
            return nil, "provider_unavailable"
        end
        if producer == nil then
            scheduleRetry(
                registrationError or "provider_unavailable",
                "BeamFX registration failed ("
                    .. tostring(registrationError)
                    .. "); visuals will retry"
            )
            return nil, registrationError or "provider_unavailable"
        end

        state.producer = producer
        state.api = api
        state.apiMinor = minor
        state.providerEpoch = epoch
        state.lastError = nil
        state.nextRetryAt = 0
        state.retryDelay = retryMinimum
        markForReconstruction("producer_registered")

        if minor < PREFERRED_API_MINOR then
            logWarning(
                "older_api_minor",
                "BeamFX API 1." .. tostring(minor)
                    .. " detected; API 1.5 fields may be unavailable; compatibility fallbacks remain active"
            )
        end
        return producer
    end

    local function producerMethod(producer, method)
        local operation, ok = guardedField(producer, method)
        if not ok or type(operation) ~= "function" then
            return nil
        end
        return operation
    end

    local function invoke(method, arguments, argumentCount, allowRetry)
        local producer, acquireError = ensureProducer()
        if producer == nil then
            return nil, acquireError
        end

        local operation = producerMethod(producer, method)
        if operation == nil then
            return nil, "unsupported_api", detail(
                method,
                "unsupported_method",
                "The active BeamFX provider does not expose this method"
            )
        end

        local ok, result, operationError, operationDetail = pcall(
            operation,
            producer,
            unpackValues(arguments, 1, argumentCount)
        )
        if not ok then
            logWarning(
                "operation_exception_" .. tostring(method),
                "BeamFX " .. tostring(method)
                    .. " raised an error; gameplay continues without this visual"
            )
            return nil, "adapter_exception", detail(
                method,
                "provider_exception",
                "The BeamFX call raised an unexpected Lua error"
            )
        end

        if (operationError == "stale_producer"
                or operationError == "provider_reset")
            and allowRetry
        then
            discardProducer(operationError)
            state.nextRetryAt = 0
            return invoke(method, arguments, argumentCount, false)
        end

        if result == nil and operationError ~= nil then
            logWarning(
                "operation_" .. tostring(method) .. "_"
                    .. tostring(operationError),
                "BeamFX " .. tostring(method) .. " failed ("
                    .. tostring(operationError) .. ")"
            )
        end
        return result, operationError, operationDetail
    end

    local function fallbackSpaceKey(spec)
        local hasCell = spec.cell ~= nil
        local hasSpaceKey = spec.spaceKey ~= nil
        if hasCell == hasSpaceKey then
            return nil, "invalid_spec", detail(
                "cell",
                "ambiguous_space",
                "Supply exactly one of cell or spaceKey"
            )
        end
        if hasSpaceKey then
            if type(spec.spaceKey) ~= "string" or spec.spaceKey == "" then
                return nil, "invalid_space_key", detail(
                    "spaceKey",
                    "invalid_space_key",
                    "spaceKey must be a nonempty string"
                )
            end
            return spec.spaceKey
        end

        local api = state.api
        local helper = guardedField(api, "spaceKeyForCell")
        if type(helper) ~= "function" then
            return nil, "unsupported_api"
        end
        local ok, spaceKey, spaceError = pcall(helper, spec.cell)
        if not ok then
            return nil, "invalid_space_key", detail(
                "cell",
                "invalid_cell",
                "BeamFX could not read this Cell"
            )
        end
        if type(spaceKey) ~= "string" or spaceKey == "" then
            return nil, spaceError or "invalid_space_key", detail(
                "cell",
                "invalid_space_key",
                "BeamFX could not derive a space key from this Cell"
            )
        end
        return spaceKey
    end

    local function nextFallbackBeamId()
        if state.emitSerial >= MAX_SAFE_INTEGER then
            state.emitSerial = 0
        end
        state.emitSerial = state.emitSerial + 1
        return "__beamfx_adapter_emit_" .. tostring(state.emitSerial)
    end

    local function fallbackEmit(spec)
        if type(spec) ~= "table" then
            return nil, "invalid_spec", detail(
                "",
                "expected_table",
                "emit expects a table"
            )
        end

        local spaceKey, spaceError, spaceDetail = fallbackSpaceKey(spec)
        if spaceKey == nil then
            return nil, spaceError, spaceDetail
        end
        local points, pointsDetail = pointList(spec)
        if points == nil then
            return nil, "invalid_spec", pointsDetail
        end
        local appearance, appearanceDetail = mergedAppearance(spec)
        if appearance == nil then
            return nil, "invalid_spec", appearanceDetail
        end

        local duration = spec.duration
        if duration == nil then
            duration = 0.25
        end
        if not finiteNumber(duration) or duration <= 0 then
            return nil, "invalid_lifecycle", detail(
                "duration",
                "invalid_duration",
                "duration must be a finite positive number"
            )
        end
        local fadeDuration = spec.fadeDuration
        if fadeDuration == nil then
            fadeDuration = math.min(0.10, duration)
        end
        if not finiteNumber(fadeDuration) or fadeDuration < 0 then
            return nil, "invalid_lifecycle", detail(
                "fadeDuration",
                "invalid_fade_duration",
                "fadeDuration must be a finite nonnegative number"
            )
        end
        fadeDuration = math.min(fadeDuration, duration)

        local beamId = nextFallbackBeamId()
        local result, operationError, operationDetail = invoke("upsert", {
            beamId,
            {
                spaceKey = spaceKey,
                lifecycle = {
                    mode = "transient",
                    duration = duration,
                    fadeDuration = fadeDuration,
                },
                audience = copyTable(
                    spec.audience or { mode = "same_space" }
                ),
                priority = spec.priority or "normal",
                maxSegments = #points - 1,
                segments = segmentsForPoints(points, appearance),
            },
        }, 2, true)
        if result == nil then
            return nil, operationError, operationDetail
        end
        return beamId
    end

    local function runReconstruction()
        if not state.needsReconstruction
            or state.reconstructing
            or state.producer == nil
        then
            return
        end
        if type(reconstruct) ~= "function" then
            state.needsReconstruction = false
            return
        end

        local currentTime = now()
        if currentTime < state.nextReconstructionAt then
            return
        end

        local producerAtStart = state.producer
        state.reconstructing = true
        local ok, accepted, reconstructionError = pcall(
            reconstruct,
            adapter,
            state.reconstructionReason
        )
        state.reconstructing = false

        if state.producer ~= producerAtStart then
            return
        end
        if not ok or accepted == false then
            state.nextReconstructionAt =
                currentTime + reconstructionRetry
            logWarning(
                "reconstruction_failed",
                "BeamFX visual reconstruction failed ("
                    .. tostring(ok and reconstructionError or accepted)
                    .. "); it will retry"
            )
            return
        end
        state.needsReconstruction = false
    end

    function adapter:update()
        if ensureProducer() ~= nil then
            runReconstruction()
        end
    end

    function adapter:invoke(method, ...)
        local argumentCount = select("#", ...)
        return invoke(method, { ... }, argumentCount, true)
    end

    function adapter:emit(spec)
        local producer, acquireError = ensureProducer()
        if producer == nil then
            return nil, acquireError
        end

        if state.apiMinor >= EMIT_API_MINOR
            and producerMethod(producer, "emit") ~= nil
        then
            return invoke("emit", { spec }, 1, true)
        end

        logWarning(
            "emit_fallback",
            "BeamFX emit is unavailable; using a transient upsert fallback"
        )
        return fallbackEmit(spec)
    end

    function adapter:spaceKeyForCell(cell)
        local producer, acquireError = ensureProducer()
        if producer == nil then
            return nil, acquireError
        end
        local helper = guardedField(state.api, "spaceKeyForCell")
        if type(helper) ~= "function" then
            return nil, "unsupported_api"
        end
        local ok, spaceKey, err = pcall(helper, cell)
        if not ok then
            return nil, "invalid_space_key"
        end
        return spaceKey, err
    end

    function adapter:apiMinor()
        return state.apiMinor
    end

    function adapter:isAvailable()
        return state.active and state.producer ~= nil
    end

    local function releaseCurrent(reason)
        local producer = state.producer
        if producer == nil then
            return
        end
        local operation = producerMethod(producer, "release")
        if operation ~= nil then
            pcall(operation, producer, reason or "consumer_cleanup")
        end
    end

    function adapter:reset(reason)
        releaseCurrent(reason or "consumer_reset")
        discardProducer(reason or "consumer_reset")
        state.active = true
        state.lastError = "provider_unavailable"
        state.nextRetryAt = 0
        state.retryDelay = retryMinimum
    end

    function adapter:release(reason)
        releaseCurrent(reason or "consumer_shutdown")
        state.active = false
        state.producer = nil
        state.api = nil
        state.apiMinor = nil
        state.providerEpoch = nil
        state.needsReconstruction = false
    end

    function adapter:resume(reason)
        if state.active then
            return
        end
        state.active = true
        state.lastError = "provider_unavailable"
        state.nextRetryAt = 0
        state.retryDelay = retryMinimum
        markForReconstruction(reason or "consumer_resumed")
    end

    return adapter
end

return M
