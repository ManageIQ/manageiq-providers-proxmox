class ManageIQ::Providers::Proxmox::Inventory::Collector::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Collector
  def cluster_resources
    @cluster_resources ||= begin
      _log.info("=== Fetching cluster resources via /cluster/resources ===")
      resources = connection.cluster.resources
      _log.info("Fetched #{resources&.size || 0} resources from cluster")
      resources || []
    rescue => err
      _log.error("Failed to fetch cluster resources: #{err.message}")
      _log.error(err.backtrace.join("\n"))
      []
    end
  end

  def cluster_metrics
    @cluster_metrics ||= begin
      node_resources = cluster_resources.select { |r| r['type'] == 'node' }
      vm_resources = cluster_resources.select { |r| r['type'] == 'qemu' }
      
      total_cpu_cores = node_resources.sum { |n| n['maxcpu'] || 0 }
      total_mem = node_resources.sum { |n| n['maxmem'] || 0 }
      used_cpu = node_resources.sum { |n| (n['cpu'] || 0) * (n['maxcpu'] || 0) }
      used_mem = node_resources.sum { |n| n['mem'] || 0 }
      
      {
        :cpu_usage_rate_average => total_cpu_cores > 0 ? ((used_cpu / total_cpu_cores) * 100) : 0,
        :cpu_total => total_cpu_cores,
        :mem_usage_absolute_average => used_mem,
        :mem_total => total_mem,
        :mem_usage_rate_average => total_mem > 0 ? ((used_mem.to_f / total_mem) * 100) : 0,
        :host_count => node_resources.count,
        :vm_count_total => vm_resources.count,
        :vm_count_on => vm_resources.count { |v| v['status'] == 'running' },
        :vm_count_off => vm_resources.count { |v| v['status'] != 'running' }
      }
    end
  end
  
  def host_metrics_data(node_name)
    node_data = cluster_resources.find { |r| r['type'] == 'node' && r['node'] == node_name }
    return {} unless node_data
    
    {
      :cpu_usage_rate_average => (node_data['cpu'] || 0) * 100,
      :cpu_total => node_data['maxcpu'] || 0,
      :mem_usage_absolute_average => node_data['mem'] || 0,
      :mem_total => node_data['maxmem'] || 0,
      :mem_usage_rate_average => node_data['maxmem'] > 0 ? 
        ((node_data['mem'].to_f / node_data['maxmem']) * 100) : 0,
      :disk_usage_absolute_average => node_data['disk'] || 0,
      :disk_total => node_data['maxdisk'] || 0,
      :disk_usage_rate_average => node_data['maxdisk'] && node_data['maxdisk'] > 0 ?
        ((node_data['disk'].to_f / node_data['maxdisk']) * 100) : 0
    }
  end
  
  def vm_metrics_data(vmid)
    vm_data = cluster_resources.find { |r| r['type'] == 'qemu' && r['vmid'].to_s == vmid.to_s }
    return {} unless vm_data
    
    {
      :cpu_usage_rate_average => (vm_data['cpu'] || 0) * 100,
      :mem_usage_absolute_average => vm_data['mem'] || 0,
      :mem_total => vm_data['maxmem'] || 0,
      :mem_usage_rate_average => vm_data['maxmem'] > 0 ?
        ((vm_data['mem'].to_f / vm_data['maxmem']) * 100) : 0,
      :disk_usage_absolute_average => vm_data['disk'] || 0,
      :disk_total => vm_data['maxdisk'] || 0
    }
  end

  def vm_config(node, vmid)
    @vm_configs ||= {}
    @vm_configs["#{node}/#{vmid}"] ||= begin
      _log.debug("Fetching config for VM #{vmid} on node #{node}...")
      connection.get("nodes/#{node}/qemu/#{vmid}/config")
    rescue => e
      _log.warn("Could not retrieve configuration for VM #{vmid} on node #{node}: #{e.message}")
      nil
    end
  end

  def vm_guest_info(node, vmid)
    guest_info = {}

    begin
      network_data = connection.get("nodes/#{node}/qemu/#{vmid}/agent/network-get-interfaces")
      if network_data && network_data['result']
        interfaces = network_data['result'].reject { |iface| iface['name'] == 'lo' }

        guest_info[:ipaddresses] = interfaces.flat_map do |iface|
          (iface['ip-addresses'] || []).map { |ip| ip['ip-address'] }
        end.compact.uniq

        guest_info[:mac_addresses] = interfaces.map do |iface|
          iface['hardware-address']
        end.compact.uniq
      end
    rescue => e
      _log.debug("Failed to get network info for VM #{vmid}: #{e.message}")
    end

    begin
      hostname_data = connection.get("nodes/#{node}/qemu/#{vmid}/agent/get-host-name")
      guest_info[:hostname] = hostname_data.dig('result', 'host-name') if hostname_data
    rescue => e
      _log.debug("Failed to get hostname for VM #{vmid}: #{e.message}")
    end

    begin
      osinfo_data = connection.get("nodes/#{node}/qemu/#{vmid}/agent/get-osinfo")
      if osinfo_data && osinfo_data['result']
        os_result = osinfo_data['result']
        guest_info[:os_name] = os_result['pretty-name'] || os_result['name']
        guest_info[:os_version] = os_result['version-id']
        guest_info[:kernel_version] = os_result['kernel-release']
      end
    rescue => e
      _log.debug("Failed to get OS info for VM #{vmid}: #{e.message}")
    end

    guest_info
  rescue => err
    _log.warn("Failed to collect guest agent info for VM #{vmid}: #{err.message}")
    {}
  end

  def cluster_name
    @cluster_name ||= begin
      _log.info("=== Fetching cluster name ===")
      cluster_status = connection.get('cluster/status')
      name = cluster_status.find { |item| item['type'] == 'cluster' }&.dig('name')
      _log.info("Cluster name: #{name}")
      name
    rescue => err
      _log.error("Failed to fetch cluster name: #{err.message}")
      nil
    end
  end

  def nodes
    @nodes ||= begin
      result = cluster_resources.select { |r| r['type'] == 'node' }
      _log.info("Found #{result.size} nodes")
      result
    end
  end

  def node_status
    @node_status ||= begin
      status_by_node = {}
      nodes.each do |node_data|
        node_name = node_data['node']
        begin
          _log.debug("Fetching status for node #{node_name}...")
          status_by_node[node_name] = connection.get("nodes/#{node_name}/status")
        rescue => e
          _log.warn("Could not retrieve status for node #{node_name}: #{e.message}")
          status_by_node[node_name] = {}
        end
      end
      _log.info("Fetched status for #{status_by_node.size} nodes")
      status_by_node
    end
  end

  def node_network
    @node_network ||= begin
      network_by_node = {}
      nodes.each do |node_data|
        node_name = node_data['node']
        begin
          _log.debug("Fetching network config for node #{node_name}...")
          network_by_node[node_name] = connection.get("nodes/#{node_name}/network")
        rescue => e
          _log.warn("Could not retrieve network config for node #{node_name}: #{e.message}")
          network_by_node[node_name] = []
        end
      end
      _log.info("Fetched network config for #{network_by_node.size} nodes")
      network_by_node
    end
  end

  def vms
    @vms ||= begin
      result = cluster_resources.select { |r| r['type'] == 'qemu' }
      _log.info("Found #{result.size} QEMU VMs")
      result
    end
  end

  def snapshots
    snapshots = []
    vms.each do |vm|
      next unless vm['type'] == 'qemu'
      node = vm['node']
      vmid = vm['vmid']
      begin
        vm_snapshots = connection.get("nodes/#{node}/qemu/#{vmid}/snapshot")

        vm_snapshots.each do |snapshot|
          next if snapshot['name'] == 'current'

          snapshots << {
            'vm_or_template_id' => vmid,
            'node' => node,
            'name' => snapshot['name'],
            'description' => snapshot['description'],
            'create_time' => snapshot['snaptime'],
            'current' => snapshot['current'] || 0,
            'parent' => snapshot['parent']
          }
        end
      rescue => e
        _log.warn("Failed to collect snapshots for VM #{vmid}: #{e.message}") if respond_to?(:_log)
      end
    end
    snapshots
  end

  def containers
    @containers ||= begin
      result = cluster_resources.select { |r| r['type'] == 'lxc' }
      _log.info("Found #{result.size} LXC containers")
      result
    end
  end

  def storages
    @storages ||= begin
      result = cluster_resources.select { |r| r['type'] == 'storage' }
      _log.info("Found #{result.size} storages")
      result
    end
  end

  def pools
    @pools ||= begin
      result = cluster_resources.select { |r| r['type'] == 'pool' }
      _log.info("Found #{result.size} pools")
      result
    end
  end
end
