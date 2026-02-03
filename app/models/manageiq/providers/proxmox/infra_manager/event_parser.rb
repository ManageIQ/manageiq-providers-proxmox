module ManageIQ::Providers::Proxmox::InfraManager::EventParser
  def self.event_to_hash(event, ems_id)
    event_hash = {
      :event_type => "PROXMOX",
      :source     => 'PROXMOX',
      :ems_ref    => event[:id],
      :timestamp  => event[:timestamp],
      :full_data  => event,
      :ems_id     => ems_id
    }

    if event[:vm_id].present?
      vm_ems_ref = "#{event[:node_id]}/#{event[:vm_id]}"
      event_hash[:vm_ems_ref] = vm_ems_ref
      event_hash[:vm_uid_ems] = vm_ems_ref
    end

    event_hash
  end
end
