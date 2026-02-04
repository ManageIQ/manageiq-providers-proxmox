module ManageIQ::Providers::Proxmox::InfraManager::EventParser
  def self.event_to_hash(event, ems_id)
    return nil if event['endtime'].blank?

    {
      :event_type => event['type'],
      :source     => "PROXMOX",
      :ems_ref    => event['upid'],
      :timestamp  => Time.at(event['endtime']).utc,
      :full_data  => event,
      :ems_id     => ems_id,
      :vm_ems_ref => event['id'],
      :vm_uid_ems => event['id'],
      :message    => "#{event['type']} - #{event['status']}"
    }
  end
end
