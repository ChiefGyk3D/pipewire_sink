-- Auto-select RØDECaster Pro II as default sink and source when it appears.
-- Fixes WirePlumber failing to restore defaults because node name suffixes
-- change on every restart/replug (e.g. analog-stereo.19 -> analog-stereo.20).

local default_nodes = Plugin.find("default-nodes-api")

local nodes_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "node.name", "matches", "alsa_*.usb-R__DE_R__DECaster_Pro_II*" },
  },
}

nodes_om:connect("object-added", function (om, node)
  local name = node.properties["node.name"]
  local media_class = node.properties["media.class"]

  if not name or not media_class then return end

  if media_class == "Audio/Sink" then
    Log.info("Setting default sink to RØDECaster: " .. name)
    default_nodes:call("set-default-configured-node-name", "Audio/Sink", name)
  elseif media_class == "Audio/Source" then
    Log.info("Setting default source to RØDECaster: " .. name)
    default_nodes:call("set-default-configured-node-name", "Audio/Source", name)
  end
end)

nodes_om:activate()
