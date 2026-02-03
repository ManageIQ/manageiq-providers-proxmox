class ManageIQ::Providers::Proxmox::Inventory::Persister::TargetCollection < ManageIQ::Providers::Proxmox::Inventory::Persister::InfraManager
  def targeted?
    true
  end
end
