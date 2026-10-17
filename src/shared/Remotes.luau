--!strict
--[[
    CursedGems :: Remotes
    ------------------------------------------------------------------
    The complete client/server wire: two RemoteEvents and one RemoteFunction.
    Deliberately tiny.

    Architecture rule: the server owns ALL state; clients send INTENT and
    receive FACTS. When the first client-initiated verb arrives it gets ONE
    audited channel (a single `{ verb, data }` event) rather than a new remote
    per feature, so input validation and rate limiting live in exactly one place
    instead of being reinvented at each call site.

      StateSync     server -> client           coalesced snapshot, 4 Hz
      Feedback      server -> client           batched cosmetic results
      RequestState  client -> server -> client one-shot full snapshot

    Phase 1 note: there is no client -> server channel at all, because Phase 1
    has nothing for a client to ask for. Both interactive verbs (gem pickup and
    summoning) are server-owned ProximityPrompts, and ProximityPromptService
    delivers those straight to the server, so the client never sends intent and
    there is therefore nothing to validate.

    An unused `Action` event - and the rate limiter written to guard it - were
    built here first and then REMOVED once it was clear Phase 1 has no client
    verbs. An inert channel is not free scaffolding: it is a promise nothing
    keeps, and it invites a later phase to trust it before it is wired. Both
    land together with the first real verb (fishing in Phase 2, or a quest
    hand-in in Phase 3), which is also when `Config.Net` regains its action
    budget. Recorded here because it is a decision, not an oversight.


    On the server this module CREATES the instances; on the client it WAITS
    for them. Importing it from either side is therefore always safe and
    neither side can race the other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "CursedGemsRemotes"
local REPLICATION_TIMEOUT = 30

local Remotes = {}

local function getFolder(): Instance
    if RunService:IsServer() then
        local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
        if existing then
            return existing
        end
        local folder = Instance.new("Folder")
        folder.Name = FOLDER_NAME
        folder.Parent = ReplicatedStorage
        return folder
    end

    local replicated = ReplicatedStorage:WaitForChild(FOLDER_NAME, REPLICATION_TIMEOUT)
    if not replicated then
        error(
            string.format(
                "[CursedGems] Remotes folder never replicated within %ds",
                REPLICATION_TIMEOUT
            )
        )
    end
    return replicated
end

local folder: Instance = getFolder()

local function ensure(className: string, name: string): Instance
    local existing = folder:FindFirstChild(name)
    if existing then
        return existing
    end

    if RunService:IsServer() then
        local created = Instance.new(className)
        created.Name = name
        created.Parent = folder
        return created
    end

    local replicated = folder:WaitForChild(name, REPLICATION_TIMEOUT)
    if not replicated then
        error(string.format("[CursedGems] Remote %s never replicated", name))
    end
    return replicated
end

Remotes.Folder = folder
Remotes.StateSync = ensure("RemoteEvent", "StateSync") :: RemoteEvent
Remotes.Feedback = ensure("RemoteEvent", "Feedback") :: RemoteEvent
Remotes.RequestState = ensure("RemoteFunction", "RequestState") :: RemoteFunction

return Remotes
