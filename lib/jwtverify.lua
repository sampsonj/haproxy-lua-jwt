--
-- JWT Validation implementation for HAProxy Lua host
--
-- Copyright (c) 2019. Adis Nezirovic <anezirovic@haproxy.com>
-- Copyright (c) 2019. Baptiste Assmann <bassmann@haproxy.com>
-- Copyright (c) 2019. Nick Ramirez <nramirez@haproxy.com>
-- Copyright (c) 2019. HAProxy Technologies LLC
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, version 2 of the License
--
-- Use HAProxy 'lua-load' to load optional configuration file which
-- should contain config table.
-- Default/fallback config
if not config then
    config = {
        debug = true,
        publicKey = nil,
        issuer = nil,
        audience = nil,
        allowUrlParam = nil,
        urlParamName = nil
    }
end

local json   = require 'json'
local base64 = require 'base64'
local openssl = {
    pkey = require 'openssl.pkey',
    digest = require 'openssl.digest',
    x509 = require 'openssl.x509'
}

local function log(msg)
    if config.debug then
        core.Debug(tostring(msg))
    end
end

local TRUE_VALS = {
    ['true'] = true,
    ['TRUE'] = true,
    ['True'] = true
}
local function toboolean(str)
    if str == nil then
        return false
    end

    assert(type(str) == 'string', 'str must be string')

    if TRUE_VALS[str] == true then
        return true
    end

    return false
end

local function dump(o)
    if type(o) == 'table' then
       local s = '{ '
       for k,v in pairs(o) do
          if type(k) ~= 'number' then k = '"'..k..'"' end
          s = s .. '['..k..'] = ' .. dump(v) .. ','
       end
       return s .. '} '
    else
       return tostring(o)
    end
end

function readAll(file)
    log("Reading file " .. file)
    local f = assert(io.open(file, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

local function decodeJwtAuthHeader(authorizationHeader)
    local headerFields = core.tokenize(authorizationHeader, " .")

    if #headerFields ~= 4 then
        log("Improperly formated Authorization header. Should be 'Bearer' followed by 3 token sections.")
        return nil
    end

    if headerFields[1] ~= 'Bearer' then
        log("Improperly formated Authorization header. Missing 'Bearer' property.")
        return nil
    end

    local token = {}
    token.header = headerFields[2]
    token.headerdecoded = json.decode(base64.decode(token.header))

    token.payload = headerFields[3]
    token.payloaddecoded = json.decode(base64.decode(token.payload))

    token.signature = headerFields[4]
    token.signaturedecoded = base64.decode(token.signature)

    log('Authorization header: ' .. authorizationHeader)
    log('Decoded JWT header: ' .. dump(token.headerdecoded))
    log('Decoded JWT payload: ' .. dump(token.payloaddecoded))

    return token
end

local function decodeJwtUrlParam(apiTokenParam)
    if apiTokenParam == nil then
      log("URL param API token not found.")
      return nil
    end

    local jwtFields = core.tokenize(apiTokenParam, ".")

    if jwtFields == nil or jwtFields[1] == nil 
        or jwtFields[2] == nill or jwtFields[3] == nill then
      log("Improperly formatted URL param API token.")
      return nil
    end

    local token = {}
    token.header = jwtFields[1]
    token.headerdecoded = json.decode(base64.decode(token.header))

    token.payload = jwtFields[2]
    token.payloaddecoded = json.decode(base64.decode(token.payload))

    token.signature = jwtFields[3]
    token.signaturedecoded = base64.decode(token.signature)

    log('API token URL param: ' .. apiTokenParam)
    log('Decoded JWT header: ' .. dump(token.headerdecoded))
    log('Decoded JWT payload: ' .. dump(token.payloaddecoded))

    return token
end

local function algorithmIsValid(token)
    if token.headerdecoded.alg == nil then
        log("No 'alg' provided in JWT header.")
        return false
    elseif token.headerdecoded.alg ~= 'RS256' then
        log("RS256 supported. Incorrect alg in JWT: " .. token.headerdecoded.alg)
        return false
    end

    return true
end

local function signatureIsValid(token, publicKey)
    local digest = openssl.digest.new('SHA256')
    digest:update(token.header .. '.' .. token.payload)
    local vkey = openssl.pkey.new(publicKey)
    local isVerified = vkey:verify(token.signaturedecoded, digest)
    return isVerified
end

local function expirationIsValid(token)
  return os.difftime(token.payloaddecoded.exp, core.now().sec) > 0
end

local function issuerIsValid(token, expectedIssuer)
  return token.payloaddecoded.iss == expectedIssuer
end

local function audienceIsValid(token, expectedAudience)
  return token.payloaddecoded.aud == expectedAudience
end

function jwtverify(txn)
    local pem = config.publicKey
    local issuer = config.issuer
    local audience = config.audience
    local allowUrlParam = config.allowUrlParam
    local urlParamName = config.urlParamName

    -- 1. Decode and parse the JWT
    local token = decodeJwtAuthHeader(txn.sf:req_hdr("Authorization"))
    if token == nil and allowUrlParam == true and urlParamName ~= nil then
      token = decodeJwtUrlParam(txn.sf:url_param(urlParamName))
    end

    if token == nil then
      log("Token could not be decoded.")
      goto out
    end

    -- 2. Verify the signature algorithm is supported (RS256)
    if algorithmIsValid(token) == false then
        log("Algorithm not valid.")
        goto out
    end

    -- 3. Verify the signature with the certificate
    if signatureIsValid(token, pem) == false then
      log("Signature not valid.")
      goto out
    end

    -- 4. Verify that the token is not expired
    if expirationIsValid(token) == false then
      log("Token is expired.")
      goto out
    end

    -- 5. Verify the issuer
    if issuer ~= nil and issuerIsValid(token, issuer) == false then
      log("Issuer not valid.")
      goto out
    end

    -- 6. Verify the audience
    if audience ~= nil and audienceIsValid(token, audience) == false then
      log("Audience not valid.")
      goto out
    end

    -- 7. Add scopes to variable
    if token.payloaddecoded.scope ~= nil then
      txn.set_var(txn, "txn.oauth_scopes", token.payloaddecoded.scope)
    else
      txn.set_var(txn, "txn.oauth_scopes", "")
    end

    -- 8. Set authorized variable
    log("req.authorized = true")
    txn.set_var(txn, "txn.authorized", true)

    -- exit
    do return end

    -- way out. Display a message when running in debug mode
 ::out::
   log("req.authorized = false")
   txn.set_var(txn, "txn.authorized", false)
end

-- Called after the configuration is parsed.
-- Loads the OAuth public key for validating the JWT signature.
core.register_init(function()
  local publicKeyPath = os.getenv("OAUTH_PUBKEY_PATH")
  local pem = readAll(publicKeyPath)
  config.publicKey = pem
  config.issuer = os.getenv("OAUTH_ISSUER")
  config.audience = os.getenv("OAUTH_AUDIENCE")
  config.allowUrlParam = toboolean(os.getenv("OAUTH_ALLOW_URL_PARAM"))
  config.urlParamName = os.getenv("OAUTH_URL_PARAM_NAME")

  log("PublicKeyPath: " .. publicKeyPath)
  log("Issuer: " .. (config.issuer or "<none>"))
  log("Audience: " .. (config.audience or "<none>"))
  log("AllowUrlParam: " .. (tostring(config.allowUrlParam) or "<none>"))
  log("UrlParamName: " .. (config.urlParamName or "<none>"))
end)

-- Called on a request.
core.register_action('jwtverify', {'http-req'}, jwtverify, 0)
