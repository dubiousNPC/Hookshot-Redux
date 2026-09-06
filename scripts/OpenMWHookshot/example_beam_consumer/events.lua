---@omw-context none

local events = {}

-- Global event names share ONE namespace with every other loaded mod, so
-- these stay prefixed with the mod identity.
--
-- The rope is a continuously-updated visual, not a one-shot: the player
-- script streams endpoint updates while the hookshot is out and sends a
-- single end event when it retracts. That mirrors the update/end pair in
-- HOOKSHOT_INTEGRATION_EXAMPLE.lua rather than the old fire-and-forget
-- FIRE_HOOK event, which could only ever draw one static segment.
events.ROPE_UPDATE = "Dubious_HookShot_RopeUpdate"
events.ROPE_END = "Dubious_HookShot_RopeEnd"

return events
