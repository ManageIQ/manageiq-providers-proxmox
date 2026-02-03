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

    if raw_event[:vm_id].present?
      vm_ems_ref = "#{raw_event[:node_id]}/#{raw_event[:vm_id]}"
      target_collection.add_target(:association => :vms, :manager_ref => {:ems_ref => vm_ems_ref})
    end

    if raw_event[:node_id].present?
      target_collection.add_target(:association => :hosts, :manager_ref => {:ems_ref => raw_event[:node_id]})
    end

    target_collection.targets
  end
end
