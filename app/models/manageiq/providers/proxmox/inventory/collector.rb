class ManageIQ::Providers::Proxmox::Inventory::Collector < ManageIQ::Providers::Inventory::Collector
  private

  def collect_vm_details(vm)
    base   = "/nodes/#{vm["node"]}/qemu/#{vm["vmid"]}"
    config = connection.request(:get, "#{base}/config")
    status = connection.request(:get, "#{base}/status/current")

    details = {
      "config"   => config,
      "status"   => status,
      "name"     => config&.dig("name"),
      "template" => config&.dig("template")
    }

    begin
      details["snapshots"] = connection.request(:get, "#{base}/snapshot")
    rescue RuntimeError => err
      $proxmox_log.warn("Failed to collect snapshots for VM #{vm["vmid"]}: #{err.message}")
    end

    if status&.dig("status") == "running" && config&.dig("agent")&.to_s&.start_with?("1")
      begin
        details["agent_info"] = connection.request(:get, "#{base}/agent/get-osinfo")&.dig("result")
        details["networks"]   = connection.request(:get, "#{base}/agent/network-get-interfaces")&.dig("result")
        details["hostname"]   = connection.request(:get, "#{base}/agent/get-host-name")&.dig("result", "host-name")
      rescue RuntimeError => err
        $proxmox_log.warn("Proxmox agent not responding for VM #{vm["vmid"]}: #{err.message}")
      end
    end

    vm.merge(details)
  end
end
