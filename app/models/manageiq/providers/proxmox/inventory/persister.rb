class ManageIQ::Providers::Proxmox::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  def initialize_inventory_collections
    add_collection(infra, :clusters)
    add_collection(infra, :hosts)
    add_collection(infra, :host_hardwares)
    add_collection(infra, :hardwares)
    add_collection(infra, :storages)
    add_collection(infra, :vms)
    add_collection(infra, :guest_devices)
    add_collection(infra, :disks)
    add_collection(infra, :networks)
    add_collection(infra, :snapshots) do |builder|
      builder.add_properties(
        :model_class => ManageIQ::Providers::Proxmox::InfraManager::Snapshot,
        :manager_ref => [:uid]
      )
    end
  end
end
