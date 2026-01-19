class ManageIQ::Providers::Proxmox::Inventory::Collector < ManageIQ::Providers::Inventory::Collector
  def connection
    @connection ||= manager.connect
  end
end
