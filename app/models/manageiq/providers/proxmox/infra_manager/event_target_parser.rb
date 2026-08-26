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

    target_collection.add_target(:association => :vms_and_templates, :manager_ref => {:ems_ref => ems_event.vm_ems_ref})   if ems_event.vm_ems_ref.present?
    target_collection.add_target(:association => :hosts,             :manager_ref => {:ems_ref => ems_event.host.ems_ref}) if ems_event.host&.ems_ref.present?

    target_collection.targets
  end
end
