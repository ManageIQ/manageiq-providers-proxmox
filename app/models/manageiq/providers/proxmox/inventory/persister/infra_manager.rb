class ManageIQ::Providers::Proxmox::Inventory::Persister::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Persister
  def initialize_inventory_collections
    add_collection(infra, :clusters)
    add_collection(infra, :hosts)
    add_collection(infra, :host_hardwares)
    add_collection(infra, :storages)
    add_collection(infra, :host_storages)
    add_collection(infra, :guest_devices, :parent_inventory_collections => %i[vms_and_templates])
    add_collection(infra, :hardwares, :parent_inventory_collections => %i[vms_and_templates])
    add_collection(infra, :operating_systems, :parent_inventory_collections => %i[vms_and_templates])
    add_collection(infra, :vms_and_templates, {}, {:without_sti => true}) do |builder|
      builder.vm_template_shared
      # Proxmox doesn't have a good unique reference that isn't the VM ID which
      # can be used to reconnect VMs from storage.
      #
      # Additionally Proxmox reuses VM IDs so a new VM will get the same ID
      # as a previously deleted VM which would then be reconnected.
      builder.add_properties(:custom_reconnect_block => nil)
    end
  end
end
