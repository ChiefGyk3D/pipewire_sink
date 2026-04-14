-- Auto-select RØDECaster Pro II as default source (microphone input) when
-- it appears. Fixes WirePlumber failing to restore defaults because node
-- name suffixes change on every restart/replug.
--
-- NOTE: Only sets the default SOURCE (input), not the sink (output).
-- Output is handled by the combined sink (combined_out) which routes to
-- both the RØDECaster and HDMI for streaming setups.

local default_nodes = Plugin.find("default-nodes-api")

local nodes_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "node.name", "matches", "alsa_input.usb-R__DE_R__DECaster_Pro_II*" },
  },
}

nodes_om:connect("object-added", function (om, node)
  local name = node.properties["node.name"]
  local media_class = node.properties["media.class"]

  if not name or not media_class then return end

  if media_class == "Audio/Source" then
    Log.info("Setting default source to RØDECaster: " .. name)
    default_nodes:call("set-default-configured-node-name", "Audio/Source", name)
  end
end)

nodes_om:activate()
