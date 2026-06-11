class ManageIQ::Providers::Proxmox::InfraManager::EventTargetParser
  attr_reader :ems_event

  def initialize(ems_event)
    @ems_event = ems_event
  end

  def parse
    target_collection = InventoryRefresh::TargetCollection.new(
      :manager => ems_event.ext_management_system,
      :event   => ems_event
    )

    raw_event = ems_event.full_data
    vm_id = raw_event['id']
    node = raw_event['node']

    if vm_id.present?
      target_collection.add_target(:association => :vms_and_templates, :manager_ref => {:ems_ref => vm_id.to_s})
    end

    if node.present?
      target_collection.add_target(:association => :hosts, :manager_ref => {:ems_ref => node})
    end

    target_collection.targets
  end
end
