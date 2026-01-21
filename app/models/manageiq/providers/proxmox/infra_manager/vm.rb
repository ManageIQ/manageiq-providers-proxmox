class ManageIQ::Providers::Proxmox::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include Operations

  POWER_STATES = {
    "running"   => "on",
    "stopped"   => "off",
    "paused"    => "paused",
    "suspended" => "suspended"
  }.freeze

  def self.calculate_power_state(raw_power_state)
    POWER_STATES[raw_power_state] || super
  end
end
