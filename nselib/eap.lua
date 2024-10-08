---
-- EAP (Extensible Authentication Protocol) library supporting a
-- limited subset of features.
--
-- The library was designed and tested against hostapd v0.6.10
-- The EAP protocol names are the ones specified in:
-- http://www.iana.org/assignments/eap-numbers/eap-numbers.xml
--
-- Scripts can use the library to start an eap session and then to
-- send identity and nak responses to identity and authentication
-- requests made by AP authenticators to analyze their behaviour.
--
-- The following sample code illustrates how to respond to an identity
-- request:
--
-- <code>
-- pcap:pcap_open(iface.device, 512, true, "ether proto 0x888e")
-- ...
-- local _, _, l2_data, l3_data, _ = pcap:pcap_receive()
-- local pkt = eap.parse(l2_data .. l3_data3)
-- if pkt then
--   if pkt.eap.type == eap.eap_t.IDENTITY and pkt.eap.code == eap.code_t.REQUEST then
--     eap.send_identity_response(iface, pkt.eap.id, "anonymous")
--   end
-- end
-- </code>
--
--
-- @copyright Same as Nmap--See https://nmap.org/book/man-legal.html
--
-- @author Riccardo Cecolin <n@rikiji.de>
--

local math = require "math"
local nmap = require "nmap"
local packet = require "packet"
local stdnse = require "stdnse"
local string = require "string"
_ENV = stdnse.module("eap", stdnse.seeall)

-- Created 02/23/2012 - v0.1

local ETHER_BROADCAST = "01:80:c2:00:00:03"
local ETHER_HEADER_SIZE = 14
local EAPOL_HEADER_SIZE = 4
local EAP_HEADER_SIZE = 5

eapol_t = {
  PACKET = 0,
  START  = 1,
  LOGOFF = 2,
  KEY    = 3,
  ASF    = 4,
}

eapol_str = {
  [0] = "EAP Packet",
  [1] = "EAPOL Start",
  [2] = "EAPOL Logoff",
  [3] = "EAPOL Key",
  [4] = "EAPOL Encapsulated ASF Alert",
}

code_t = {
  REQUEST   = 1,
  RESPONSE  = 2,
  SUCCESS   = 3,
  FAILURE   = 4,
  INITIATE  = 5,
  FINISH    = 6,
}

code_str = {
  [1] = "Request",
  [2] = "Response",
  [3] = "Success",
  [4] = "Failure",
  [5] = "Initiate",
  [6] = "Finish",
}

eap_t = {
  IDENTITY     = 1,
  NAK          = 3,
  MD5          = 4,
  TLS          = 13,
  TTLS         = 21,
  PEAP         = 25,
  MSCHAP       = 29,
}

eap_str = {
  [0] = "Reserved",
  [1] = "Identity",
  [2] = "Notification",
  [3] = "Legacy Nak",
  [4] = "MD5-Challenge",
  [5] = "One-Time Password (OTP)",
  [6] = "Generic Token Card (GTC)",
  [7] = "Allocated",
  [8] = "Allocated",
  [9] = "RSA Public Key Authentication",
  [10] = "DSS Unilateral",
  [11] = "KEA",
  [12] = "KEA-VALIDATE",
  [13] = "EAP-TLS",
  [14] = "Defender Token (AXENT)",
  [15] = "RSA Security SecurID EAP",
  [16] = "Arcot Systems EAP",
  [17] = "EAP-Cisco Wireless",
  [18] = "GSM Subscriber Identity Modules (EAP-SIM)",
  [19] = "SRP-SHA1",
  [20] = "Unassigned",
  [21] = "EAP-TTLS",
  [22] = "Remote Access Service",
  [23] = "EAP-AKA Authentication",
  [24] = "EAP-3Com Wireless",
  [25] = "PEAP",
  [26] = "MS-EAP-Authentication",
  [27] = "Mutual Authentication w/Key Exchange (MAKE)",
  [28] = "CRYPTOCard",
  [29] = "EAP-MSCHAP-V2",
  [30] = "DynamID",
  [31] = "Rob EAP",
  [32] = "Protected One-Time Password",
  [33] = "MS-Authentication-TLV",
  [34] = "SentriNET",
  [35] = "EAP-Actiontec Wireless",
  [36] = "Cogent Systems Biometrics Authentication EAP",
  [37] = "AirFortress EAP",
  [38] = "EAP-HTTP Digest",
  [39] = "SecureSuite EAP",
  [40] = "DeviceConnect EAP",
  [41] = "EAP-SPEKE",
  [42] = "EAP-MOBAC",
  [43] = "EAP-FAST",
  [44] = "ZoneLabs EAP (ZLXEAP)",
  [45] = "EAP-Link",
  [46] = "EAP-PAX",
  [47] = "EAP-PSK",
  [48] = "EAP-SAKE",
  [49] = "EAP-IKEv2",
  [50] = "EAP-AKA'",
  [51] = "EAP-GPSK",
  [52] = "EAP-pwd",
  [53] = "EAP-EKE Version 1",
  [54] = "EAP Method Type for PT-EAP",
  [55] = "TEAP",
  -- 56-253 Unassigned
  [254] = "Reserved for the Expanded Type",
  [255] = "Experimental",
}

local make_eapol = function (arg)
  if not arg.src then return nil end
  if not arg.type then arg.type = eapol_t.PACKET end
  if not arg.version then arg.version = 1 end
  if not arg.payload then arg.payload = "" end

  local p = packet.Frame:new()
  p.mac_src = arg.src
  p.mac_dst = packet.mactobin(ETHER_BROADCAST)
  p.ether_type = packet.ETHER_TYPE_EAPOL

  p.buf = string.pack(">BBs2", arg.version, arg.type, arg.payload)
  p:build_ether_frame()
  return p.frame_buf
end

local make_eap = function (arg)

  if not arg.header then return nil end
  if not arg.code then arg.code = code_t.REQUEST end
  if not arg.id then arg.id = math.random(0,255) end
  if not arg.type then arg.type = eap_t.IDENTITY end
  if not arg.payload then arg.payload = "" end

  local bin_payload = arg.payload
  arg.header.payload = string.pack(">BBI2B", arg.code, arg.id, #bin_payload + EAP_HEADER_SIZE, arg.type) .. bin_payload

  local v = make_eapol(arg.header)
  stdnse.debug2("make eapol %s", arg.header.src)

  return v
end

parse = function (pkt)
  local tb = {}

  stdnse.debug2("packet size: 0x%x", #pkt )

  -- parsing ethernet header
  tb.mac_src, tb.mac_dst, tb.ether_type = string.unpack(">c6c6I2", pkt)
  tb.mac_src_str = stdnse.tohex(tb.mac_src)
  tb.mac_dst_str = stdnse.tohex(tb.mac_dst)

  -- parsing eapol header
  tb.version, tb.type, tb.length = string.unpack(">BBI2", pkt, ETHER_HEADER_SIZE + 1)

  stdnse.debug1("mac_src: %s, mac_dest: %s, ether_type: 0x%X",
  tb.mac_src_str, tb.mac_dst_str, tb.ether_type)

  if tb.ether_type ~= packet.ETHER_TYPE_EAPOL then return nil, "not an eapol packet" end

  stdnse.debug2("version: %X, type: %s, length: 0x%X",
  tb.version, eapol_str[tb.type] or "unknown",
  tb.length)

  tb.eap = {}

  if tb.length > 0 then
    -- parsing body

    tb.eap.code, tb.eap.id, tb.eap.length, tb.eap.type = string.unpack(">BBI2B", pkt,
    ETHER_HEADER_SIZE + EAPOL_HEADER_SIZE + 1)
    stdnse.debug2("code: %s, id: 0x%X, length: 0x%X, type: %s",
    code_str[tb.eap.code] or "unknown",
    tb.eap.id, tb.eap.length, eap_str[tb.eap.type] or "unknown" )
    if tb.length ~= tb.eap.length then
      stdnse.debug1("WARNING length mismatch: 0x%X and 0x%X", tb.length, tb.eap.length )
    end
  end

  tb.eap.body = {}

  -- parsing payload
  if tb.length > 5 and tb.eap.type == eap_t.IDENTITY then
    tb.eap.body.identity = string.unpack("z", pkt,
    ETHER_HEADER_SIZE + EAPOL_HEADER_SIZE + EAP_HEADER_SIZE + 1)
    stdnse.debug1("identity: %s", tb.eap.body.identity )
  end

  if tb.length > 5 and tb.eap.type == eap_t.MD5  then
    tb.eap.body.challenge = string.unpack("s1", pkt, ETHER_HEADER_SIZE + EAPOL_HEADER_SIZE + EAP_HEADER_SIZE + 1)
  end

  return tb
end

send_identity_response = function (iface, id, identity)

  if not iface then
    stdnse.debug1("no interface given")
    return
  end

  local dnet = nmap.new_dnet()
  local tb = {src = iface.mac, type = eapol_t.PACKET}
  local response = make_eap{header = tb, code = code_t.RESPONSE, type = eap_t.IDENTITY, id = id, payload = identity}

  dnet:ethernet_open(iface.device)
  dnet:ethernet_send(response)
  dnet:ethernet_close()
end

send_nak_response = function (iface, id, auth)

  if not iface then
    stdnse.debug1("no interface given")
    return
  end

  local dnet = nmap.new_dnet()
  local tb = {src = iface.mac, type = eapol_t.PACKET}
  local response = make_eap{header = tb, code = code_t.RESPONSE, type = eap_t.NAK, id = id, payload = string.pack("B",auth)}

  dnet:ethernet_open(iface.device)
  dnet:ethernet_send(response)
  dnet:ethernet_close()
end


send_start = function (iface)

  if not iface then
    stdnse.debug1("no interface given")
    return
  end

  local dnet = nmap.new_dnet()
  local start = make_eapol{type = eapol_t.START, src = iface.mac}

  dnet:ethernet_open(iface.device)
  dnet:ethernet_send(start)
  dnet:ethernet_close()

end

return _ENV;
