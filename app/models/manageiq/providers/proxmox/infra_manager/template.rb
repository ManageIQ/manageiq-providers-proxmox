class ManageIQ::Providers::Proxmox::InfraManager::Template < ManageIQ::Providers::Proxmox::InfraManager::Vm
  def self.base_model
    ManageIQ::Providers::Proxmox::InfraManager::Vm
  end
end
