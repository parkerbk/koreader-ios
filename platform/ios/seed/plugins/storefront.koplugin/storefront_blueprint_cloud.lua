--- Storefront Blueprint Cloud Sync & Sharing Module
--- Connects to the Cloudflare Worker backend for shortcode-based blueprint sharing.
---
--- @module StorefrontBlueprintCloud

local json = require("json")
local logger = require("logger")
local socketutil = require("socketutil")
local BlueprintMgr = require("storefront_blueprint_mgr")

local M = {}

M.BASE_URL = "https://storefront-blueprint.ultimatejimmy.workers.dev"

local function getHttpModule()
    local ok_http, http = pcall(require, "socket.http")
    if ok_http and http then return http end
    return nil
end

--- Normalizes a user-input shortcode (e.g. "sf-a8k2m9" -> "A8K2M9").
--- @param code string
--- @return string
function M.normalizeCode(code)
    if not code or type(code) ~= "string" then return "" end
    local clean = code:upper():gsub("[%s%-_#]+", "")
    -- If user prefixed with SF, strip it if length is greater than 6
    if clean:sub(1, 2) == "SF" and #clean > 6 then
        clean = clean:sub(3)
    end
    return clean
end

--- Uploads a blueprint to the Cloudflare backend and returns a shortcode.
--- @param blueprint table The blueprint table to upload
--- @param callback fun(success: boolean, result: table|string) Callback with result { code, url, expires_at } or error string
function M.uploadBlueprint(blueprint, callback)
    local ok_val, val_err = BlueprintMgr.validateBlueprint(blueprint)
    if not ok_val then
        if callback then callback(false, val_err or "Invalid blueprint data") end
        return
    end

    local ok_enc, payload = pcall(json.encode, blueprint)
    if not ok_enc or not payload then
        if callback then callback(false, "Failed to encode blueprint JSON") end
        return
    end

    local http_req = getHttpModule()
    if not http_req then
        if callback then callback(false, "LuaSocket HTTP module not available") end
        return
    end

    local function do_request()
        local response_body = {}
        local headers = {
            ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#payload),
        }

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok_req, res_code = pcall(function()
            local payload_sent = false
            local params = {
                url = M.BASE_URL .. "/blueprint",
                method = "POST",
                headers = headers,
                source = function()
                    if not payload_sent then
                        payload_sent = true
                        return payload
                    end
                    return nil
                end,
                sink = function(chunk)
                    if chunk then table.insert(response_body, chunk) end
                    return 1
                end,
            }
            local _, c = http_req.request(params)
            return c
        end)
        socketutil:reset_timeout()

        local code = tonumber(res_code) or 0
        local body_str = table.concat(response_body)

        if ok_req and (code == 200 or code == 201) then
            local ok_json, parsed = pcall(json.decode, body_str)
            if ok_json and type(parsed) == "table" and parsed.code then
                if callback then callback(true, parsed) end
                return
            elseif ok_json and type(parsed) == "table" and parsed.shortcode then
                parsed.code = parsed.shortcode
                if callback then callback(true, parsed) end
                return
            end
        end

        local err_msg = "Cloud upload failed (HTTP " .. tostring(res_code) .. ")"
        if body_str and body_str ~= "" then
            local ok_j, err_obj = pcall(json.decode, body_str)
            if ok_j and err_obj and err_obj.error then
                err_msg = tostring(err_obj.error)
                if err_msg:find("repo_id") or err_msg:find("device_uuid") then
                    err_msg = "Backend not deployed: please deploy storefront-blueprint worker to Cloudflare"
                end
            end
        end
        if callback then callback(false, err_msg) end
    end

    -- Run asynchronously if NetworkMgr is available
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        NetworkMgr:runWhenOnline(do_request)
    else
        do_request()
    end
end

--- Fetches a blueprint from the Cloudflare backend by shortcode.
--- @param shortcode string 6-character alphanumeric code
--- @param callback fun(success: boolean, result: table|string) Callback with blueprint table or error string
function M.fetchBlueprint(shortcode, callback)
    local clean_code = M.normalizeCode(shortcode)
    if not clean_code or clean_code == "" then
        if callback then callback(false, "Please enter a valid shortcode") end
        return
    end

    local http_req = getHttpModule()
    if not http_req then
        if callback then callback(false, "LuaSocket HTTP module not available") end
        return
    end

    local function do_request()
        local response_body = {}
        local headers = {
            ["User-Agent"] = "KOReader-Storefront-Plugin/1.0",
            ["Accept"] = "application/json",
        }

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok_req, res_code = pcall(function()
            local params = {
                url = string.format("%s/blueprint/%s", M.BASE_URL, clean_code),
                method = "GET",
                headers = headers,
                sink = function(chunk)
                    if chunk then table.insert(response_body, chunk) end
                    return 1
                end,
            }
            local _, c = http_req.request(params)
            return c
        end)
        socketutil:reset_timeout()

        local code = tonumber(res_code) or 0
        local body_str = table.concat(response_body)

        if ok_req and code == 200 then
            local ok_json, parsed = pcall(json.decode, body_str)
            if ok_json and type(parsed) == "table" then
                -- Check if response wraps blueprint inside a data property
                local bp = parsed.blueprint or parsed.data or parsed
                local valid, val_err = BlueprintMgr.validateBlueprint(bp)
                if valid then
                    if callback then callback(true, bp) end
                    return
                else
                    if callback then callback(false, "Invalid blueprint schema: " .. tostring(val_err)) end
                    return
                end
            end
        end

        local err_msg = "Could not find blueprint for code " .. clean_code .. " (HTTP " .. tostring(res_code) .. ")"
        if code == 404 then
            err_msg = "Blueprint code '" .. clean_code .. "' not found or expired."
        end
        if callback then callback(false, err_msg) end
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        NetworkMgr:runWhenOnline(do_request)
    else
        do_request()
    end
end

return M
