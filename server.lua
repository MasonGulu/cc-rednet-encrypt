--- Server module
-- @module server

local ecc = require("ecc")
local common = require("common")
local modem = peripheral.find("modem")
local expect = require("cc.expect").expect
assert(modem, "Modem not found.")
rednet.open(peripheral.getName(modem))

settings.define("rne.enable_screen", {
  description = "Enable logging information to the screen.",
  default = true,
  type = "boolean"
})

local doLogging = settings.get("rne.enable_screen")

--- Default server settings
-- @table api
local api = {
  maxConnectionAge=(1000 * 60 * 3), -- Maximum time since last message for a connection to be considered valid
  maxMessageAge = 300, -- Maximum time from a message being sent that it's still accepted and processed
  msgHandle = function(self, id, msg)
    print("Message recieved: "..textutils.serialize(msg))
  end, -- Message handling function of signature function(self, id, message)
  uuidCacheLength = 10, -- Amount of message UUIDs to cache to prevent repeat attacks
}
api.__index = api

function api:validateMessageSigniture(id, message)
  if not self:verifyAge(id) then
    -- connection is too old
    return false
  elseif ecc.verify(self.activeConnections[id].public, message.message, message.sig) then
    return true
  end
  self:sendMessage(id, common.messageTypes.error, common.error.sig_invalid)
  return false
end

function api:verifyAge(id)
  local connection = self.activeConnections[id]
  if (not connection) or (connection.lastMessage + self.maxConnectionAge < os.epoch("utc")) then
    -- This computer is either not in the cache, or the cache has timed out
    print("  Connection is either too old, or this computer is not in the cache.")
    self.activeConnections[id] = nil
    self:sendMessage(id, common.messageTypes.error, common.error.key_failure)
    return false
  end
  return true
end

--- Send an unencrypted message
-- @tparam number id
-- @tparam string type
-- @param message
function api:sendMessage(id, type, message)
  expect(1, id, "number")
  expect(2, type, "string")
  local toSend = {type=type, message=message, sig=ecc.sign(self.private, message)}
  rednet.send(id, toSend, self.protocol)
end

--- Send an encrypted message
-- @tparam number id
-- @param table message
-- @treturn bool Message was sent
function api:sendEncryptedMessage(id, message)
  expect(1, id, "number")
  expect(2, message, "table")
  message.uuid = message.uuid or common.generateUUID()
  if self:verifyAge(id) then
    local encryptedMessage = ecc.encrypt(textutils.serialize(message), self.activeConnections[id])
    self:sendMessage(id, common.messageTypes.encrypted, encryptedMessage)
    return true
  end
  return false
end

local function getLengthOfArbritaryT(T)
  local len = 0
  for k,v in pairs(T) do
    len = len + 1
  end
  return len
end

--- Start the server
function api:start()
  if doLogging then
    local width, height = term.getSize()
    topBar = window.create(term.current(), 1, 1, width, 1)
    topBar.setBackgroundColor(colors.blue)
    topBar.setTextColor(colors.white)
    bottomArea = window.create(term.current(), 1, 2, width, height-1)
    term.redirect(bottomArea)
    print("Server started for "..self.protocol)
  end
  while true do
    if doLogging then
      topBar.setCursorPos(1,1)
      topBar.clear()
      topBar.write(string.format("%s@%s\127C%2u", self.protocol, self.hostname, getLengthOfArbritaryT(self.activeConnections)))
    end
    local id, response, protocol = rednet.receive(self.protocol, self.maxConnectionAge/1000)
    if protocol == self.protocol and type(response) == "table" then
      if doLogging then
        print(string.format("%u Message from %u",os.epoch("utc"), id))
      end
      if response.type == common.messageTypes.key_exchange then
        -- peform key exchange
        if doLogging then
          term.setTextColor(colors.lime)
          print("  Key exchange")
          term.setTextColor(colors.white)
        end
        if ecc.verify(response.message, response.message, response.sig) then
          self.activeConnections[id] = {
            id = id,
            public = response.message,
            common = ecc.exchange(self.private, response.message),
            lastMessage = os.epoch("utc"),
            uuids = {},
          }
          self:sendMessage(id, common.messageTypes.key_exchange, self.public)
        else
          if doLogging then
            print("  Invalid signature")
          end
          self:sendMessage(id, common.messageTypes.error, common.error.sig_invalid)
        end
      else
        local signatureValid = self:validateMessageSigniture(id, response)
        if response.type == common.messageTypes.encrypted and signatureValid then
          local decrypt = ecc.decrypt(response.message, self.activeConnections[id].common)
          local status, decryptT = pcall(textutils.unserialise, string.char(unpack(decrypt)))
          if status then
            -- Ensure that this message's uuid is different, if not then this message may be a replay attack. So invalidate the connection and force a new keypair generation.
            local currentTime = os.epoch("utc")
            local messageTooOld = (decryptT.epoch == nil) or (decryptT.epoch + self.maxMessageAge < currentTime)
            local uuidAlreadySeen = common.valueInTable(self.activeConnections[id].uuids, decryptT.uuid) or (decryptT.uuid == nil)
            if type(decryptT.epoch)=="number" and doLogging then print(string.format("  Message is %ums old", currentTime - decryptT.epoch)) end
            if messageTooOld or uuidAlreadySeen then
              -- This uuid has already been sent in a message, or this message doesn't contain a uuid
              -- Or the epoch in the message is too old
              if doLogging then
                term.setTextColor(colors.yellow)
                if messageTooOld then
                  print("  Message too old.")
                else
                  print("  Message contains duplicate uuid.")
                end
                term.setTextColor(colors.white)
              end
              -- self.activeConnections[id] = nil
              -- self:sendMessage(id, common.messageTypes.error, common.error.key_failure) 
              -- invalidating the connection results in allowing duplicate messages, ignoring is probably better behavior
            else
              if #self.activeConnections[id].uuids > self.uuidCacheLength then
                table.remove(self.activeConnections[id].uuids, 1)
              end
              self.activeConnections[id].uuids[#self.activeConnections[id].uuids+1] = decryptT.uuid
              self.activeConnections[id].lastMessage = currentTime
              if doLogging then
                term.setTextColor(colors.green)
                print("  Valid message, passing to msgHandle")
                term.setTextColor(colors.white)
              end
              local err
              status, err = pcall(self.msgHandle, self, id, decryptT)
              if not status and doLogging then
                term.setTextColor(colors.red)
                print("  !!msgHandle threw an error:")
                print(err)
                term.setTextColor(colors.white)
              end
            end
          elseif signatureValid then
            -- The signiture is correct, but the decrypted message is not a deserializable string
            -- Either our common encryption key is incorrect, or someone attempted to send a non-table item
            -- Regardless this is not supported and we'll just send a key error back
            if doLogging then
              term.setTextColor(colors.red)
              print("  Invalid key")
              term.setTextColor(colors.white)
            end
            self:sendMessage(id, common.messageTypes.error, common.error.key_failure)
          else
            if doLogging then
              term.setTextColor(colors.red)
              print("  Invalid signature")
              term.setTextColor(colors.white)
            end
            self:sendMessage(id, common.messageTypes.error, common.error.sig_invalid)
          end
        end
      end
    elseif doLogging then
      print("No messages recieved.. Clearing cache..")
    end
    -- Done processing request
    for k,v in pairs(self.activeConnections) do
      if v.lastMessage + self.maxConnectionAge < os.epoch("utc") then
        -- this connection has expired
        self.activeConnections[k] = nil -- wipe it from memory
      end
    end
  end
end

--- Create a new server object
-- @tparam string protocol
-- @tparam string hostname
-- @treturn table server object
function api.new(protocol, hostname)
  rednet.host(protocol, hostname)
  local o = {}
  o.protocol = protocol
  o.hostname = hostname
  o.private, o.public = ecc.keypair()
  o.activeConnections = {} -- indexed by rednet ID
  -- Each entry will contain:
  -- id: rednet id
  -- public: public key
  -- common: common key
  -- lastMessage: time of last key exchange; if too old forget this connection
  -- username: nil, or string username of logged in user on this connection
  -- uuids: the uuids of the last 10 send messages
  setmetatable(o, api)
  return o
end

return api
