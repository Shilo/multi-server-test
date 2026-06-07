local nk = require("nakama")

local TICKETS = {}
local DEFAULT_ORCHESTRATOR_URL = "http://127.0.0.1:19100"
local DEFAULT_ORCHESTRATOR_KEY = "localdev-secret"
local TICKET_TTL_SECONDS = 30

local function env(context, key, fallback)
  if context.env and context.env[key] then
    return context.env[key]
  end
  return fallback
end

local function world_targets(world_id)
  if world_id == 1 then
    return {2, 3}
  elseif world_id == 2 or world_id == 3 then
    return {1}
  end
  return {}
end

local function ensure_world(context, world_id)
  local url = env(context, "ORCHESTRATOR_URL", DEFAULT_ORCHESTRATOR_URL) .. "/worlds/ensure"
  local headers = {
    ["Content-Type"] = "application/json",
    ["X-Orchestrator-Key"] = env(context, "ORCHESTRATOR_KEY", DEFAULT_ORCHESTRATOR_KEY)
  }
  local body = nk.json_encode({
    world_id = world_id,
    idle_shutdown_seconds = 10
  })
  local success, code, _, response_body = pcall(nk.http_request, url, "POST", headers, body, 5000)
  if not success then
    error(("orchestrator request failed: %s"):format(code))
  end
  if code >= 400 then
    error(("orchestrator returned %d: %s"):format(code, response_body))
  end
  local decoded = nk.json_decode(response_body)
  if not decoded.ok then
    error(("orchestrator failed: %s"):format(decoded.error or "unknown"))
  end
  return decoded.world
end

local function issue_ticket(user_id, world_id)
  local ticket = nk.uuid_v4()
  TICKETS[ticket] = {
    user_id = user_id,
    world_id = world_id,
    expires_at = os.time() + TICKET_TTL_SECONDS
  }
  return ticket
end

local function entry_response(context, user_id, world_id)
  local world = ensure_world(context, world_id)
  return nk.json_encode({
    world_id = world_id,
    endpoint = world,
    ticket = issue_ticket(user_id, world_id),
    allowed_targets = world_targets(world_id)
  })
end

local function rpc_join_world(context, payload)
  if not context.user_id or context.user_id == "" then
    error("join_world requires an authenticated Nakama session")
  end
  local request = {}
  if payload and payload ~= "" then
    request = nk.json_decode(payload)
  end
  local world_id = tonumber(request.world_id or 1)
  return entry_response(context, context.user_id, world_id)
end

local function rpc_transfer_world(context, payload)
  if not context.user_id or context.user_id == "" then
    error("transfer_world requires an authenticated Nakama session")
  end
  local request = nk.json_decode(payload)
  local target_world = tonumber(request.target_world or 1)
  return entry_response(context, context.user_id, target_world)
end

local function rpc_validate_ticket(_, payload)
  local request = nk.json_decode(payload)
  local ticket = request.ticket
  local world_id = tonumber(request.world_id or 0)
  local record = TICKETS[ticket]
  if not record then
    return nk.json_encode({ ok = false, error = "ticket not found" })
  end
  if record.expires_at < os.time() then
    TICKETS[ticket] = nil
    return nk.json_encode({ ok = false, error = "ticket expired" })
  end
  if record.world_id ~= world_id then
    return nk.json_encode({ ok = false, error = "wrong world" })
  end
  TICKETS[ticket] = nil
  return nk.json_encode({
    ok = true,
    user_id = record.user_id,
    world_id = record.world_id,
    allowed_targets = world_targets(world_id)
  })
end

nk.register_rpc(rpc_join_world, "join_world")
nk.register_rpc(rpc_transfer_world, "transfer_world")
nk.register_rpc(rpc_validate_ticket, "validate_ticket")

nk.logger_info("VirtuCade Nakama MVP runtime loaded")
