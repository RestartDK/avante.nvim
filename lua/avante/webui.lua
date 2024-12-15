-- First check for external dependencies
local curl = require("plenary.curl")
local Utils = require("avante.utils")
local Path = require("avante.path")
local api = vim.api

-- Initialize random seed for UUID generation
math.randomseed(os.time())

-- UUID generation implementation
local uuid = {
  new = function()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
      local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
      return string.format("%x", v)
    end)
  end,
}

---@class avante.WebUI
local M = {}

-- Environment variable for the WebUI URL
M.webui_url_env = "WEBUI_URL"
-- Environment variable for the WebUI Bearer token
M.webui_bearer_token = "WEBUI_BEARER_TOKEN"

-- Get the WebUI URL from environment, fallback to localhost:3000
function M.get_webui_url() return vim.env[M.webui_url_env] or "http://localhost:3000" end
function M.get_webui_bearer_token() return vim.env[M.webui_bearer_token] end

function M.format_request(opts)
  local chat_id = uuid.new()
  local messages = {}
  local messages_map = {}
  local previous_id = nil
  local current_timestamp = os.time() * 1000

  for i, entry in ipairs(opts.messages) do
    local msg_id = uuid.new()
    local response_id = uuid.new()

    -- Create user message
    local user_message = {
      id = msg_id,
      parentId = previous_id,
      childrenIds = { response_id },
      role = "user",
      content = entry.request,
      timestamp = tonumber(entry.timestamp),
      models = { "anthropic.claude-3-5-sonnet-latest" },
    }

    -- Add user message to both structures
    table.insert(messages, user_message)
    messages_map[msg_id] = user_message

    -- If there's a response, create assistant message
    if entry.response then
      local assistant_message = {
        id = response_id,
        parentId = msg_id,
        childrenIds = {}, -- Will be updated if there's a next message
        role = "assistant",
        content = entry.response,
        timestamp = tonumber(entry.timestamp),
        models = { "anthropic.claude-3-5-sonnet-latest" },
      }

      -- Add assistant message to both structures
      table.insert(messages, assistant_message)
      messages_map[response_id] = assistant_message

      previous_id = response_id
    else
      previous_id = msg_id
    end

    -- Update previous message's childrenIds if there will be another message
    if i < #opts.messages and previous_id then
      local next_id = uuid.new()
      messages_map[previous_id].childrenIds = { next_id }
    end
  end

  -- Get the ID of the last message for currentId
  local current_id = messages[#messages].id

  return {
    chat = {
      id = chat_id,
      title = "Yoinked from nvim",
      models = { "anthropic.claude-3-5-haiku-latest" },
      params = {},
      history = {
        messages = messages_map,
        currentId = current_id,
      },
      messages = messages,
      tags = {},
      timestamp = current_timestamp,
    },
  }
end

function M.transfer_chat_history()
  -- Get the current buffer number
  local bufnr = api.nvim_get_current_buf()

  -- Load chat history for current buffer
  local chat_history = Path.history.load(bufnr)

  -- Prepare request data
  local request_data = M.format_request({ messages = chat_history })

  -- Show loading state
  Utils.info("Sending request to WebUI...")

  -- Make the API call
  curl.post(Utils.url_join(M.get_webui_url(), "api/v1/chats/new"), {
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. (M.get_webui_bearer_token() or ""),
    },
    body = vim.fn.json_encode(request_data),
    callback = function(response)
      -- Handle HTTP errors
      if not response or response.status < 200 or response.status >= 300 then
        Utils.error(
          string.format(
            "WebUI API Error: HTTP %d - %s",
            response and response.status or 0,
            response and response.body or "Connection failed"
          )
        )
        return
      end

      -- Parse response body
      local ok, json = pcall(vim.json.decode, response.body)
      if not ok then
        Utils.error("Failed to parse WebUI response: " .. response.body)
        return
      end

      -- Handle API-level errors
      if json.error then
        Utils.error("WebUI API Error: " .. json.error)
        return
      end

      Utils.info("Successfully received and processed response")
    end,
  })
end

return M
