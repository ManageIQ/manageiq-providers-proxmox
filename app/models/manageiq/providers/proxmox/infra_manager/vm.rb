class ManageIQ::Providers::Proxmox::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include Operations
  include RemoteConsole

  POWER_STATES = {
    "running"   => "on",
    "stopped"   => "off",
    "paused"    => "paused",
    "suspended" => "suspended"
  }.freeze

  def self.calculate_power_state(raw_power_state)
    POWER_STATES[raw_power_state] || super
  end

  def vm_path
    "/nodes/#{host.ems_ref}/qemu/#{ems_ref}"
  end
end
