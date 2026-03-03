class ManageIQ::Providers::Proxmox::Inventory::Collector < ManageIQ::Providers::Inventory::Collector
  def cluster
    @cluster ||= cluster_status&.find { |item| item["type"] == "cluster" }
  end

  def cluster_status
    @cluster_status ||= connection.request(:get, "/cluster/status") || []
  end

  def cluster_resources_by_type
    @cluster_resources_by_type ||= cluster_resources.group_by { |res| res["type"] }
  end

  def cluster_resources
    @cluster_resources ||= connection.request(:get, "/cluster/resources")
  end

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

  # Node-related helper methods shared across collectors
  def node_status(node_name)
    connection.request(:get, "/nodes/#{node_name}/status")
  rescue => e
    _log.warn("Failed to fetch status for node #{node_name}: #{e.message}")
    nil
  end

  def node_version(node_name)
    connection.request(:get, "/nodes/#{node_name}/version")
  rescue => e
    _log.warn("Failed to fetch version for node #{node_name}: #{e.message}")
    nil
  end

  def node_networks(node_name)
    connection.request(:get, "/nodes/#{node_name}/network")
  rescue => e
    _log.warn("Failed to fetch networks for node #{node_name}: #{e.message}")
    []
  end

  def node_ip(node_name)
    node_data = cluster_status.find { |item| item["type"] == "node" && item["name"] == node_name }
    node_data&.dig("ip")
  end

  def connection
    @connection ||= manager.connect
  end
end
