class ManageIQ::Providers::Proxmox::InfraManager::Host < Host
  def self.display_name(number = 1)
    n_('Host (Proxmox)', 'Hosts (Proxmox)', number)
  end
end
