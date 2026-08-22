# Which tests the live rig can run right now.
#
#   ruby runnable.rb <test-plan.yaml> <situation>
#
# The plan's `available:` field is the standing answer about a capability; the
# situation observed on the phone is the live one, and the live one wins. Blocked
# is computed here and never typed into the plan.
require "yaml"

plan = YAML.load_file(ARGV[0])
situation = ARGV[1]

# Capabilities the rig supplies whatever the sky is doing.
present = %w[bench simulator iphone sondehub second-sonde receiver-retune
             network-outage hunter-driving hunter-on-foot]

present << "receiver" if %w[S-RECEIVER S-FLIGHT-BLE S-DESCENT-BLE S-TEST-SONDE].include?(situation)
present << "sonde-flying" if %w[S-FLIGHT S-FLIGHT-BLE S-DESCENT-BLE].include?(situation)
present << "sonde-descending" if situation == "S-DESCENT-BLE"
present << "sonde-landed" if situation == "S-LANDED"
present << "test-sonde" if situation == "S-TEST-SONDE"

plan["tests"].each do |t|
  next if t["tier"] == "unit"
  missing = (t["needs"] || []) - present
  verdict = if !missing.empty?
              "blocked - needs #{missing.join(', ')}"
            elsif t["status"] == "successful"
              "done"
            else
              "RUNNABLE"
            end
  puts [t["id"], t["tier"], verdict].join("\t")
end
