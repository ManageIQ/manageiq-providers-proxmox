class ManageIQ::Providers::Proxmox::Inventory::Parser::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Parser
  def parse
    clusters
    hosts
    storages
    networks
    vms
  end

  def clusters
    cluster_data = collector.cluster
    return unless cluster_data

    persister.clusters.build(
      :ems_ref => cluster_data["id"],
      :uid_ems => cluster_data["id"],
      :name    => cluster_data["name"]
    )
  end

  def hosts
    cluster_data = collector.cluster
    cluster = cluster_data ? persister.clusters.lazy_find(cluster_data["id"]) : nil

    collector.nodes.each do |host|
      node_name = host["node"]
      ems_ref = host["id"].gsub("node/", "")
      details = collector.node_details[node_name] || {}
      status = details[:status] || {}
      version = details[:version] || {}

      host_obj = persister.hosts.build(
        :ems_ref          => ems_ref,
        :uid_ems          => ems_ref,
        :name             => node_name,
        :hostname         => node_name,
        :ipaddress        => details[:ip],
        :vmm_vendor       => "proxmox",
        :vmm_product      => "Proxmox VE",
        :vmm_version      => version["version"],
        :vmm_buildnumber  => version["repoid"],
        :power_state      => host["status"] == "online" ? "on" : "off",
        :connection_state => host["status"] == "online" ? "connected" : "disconnected",
        :ems_cluster      => cluster
      )

      hardware = parse_host_hardware(host_obj, host, status)
      parse_host_operating_system(host_obj)
      parse_host_network_adapters(hardware, details[:networks])
      parse_host_switches(host_obj, hardware, details[:networks])
    end
  end

  def storages
    parsed_storages = {}

    collector.storages.each do |storage|
      next unless storage["status"] == "available"

      storage_name = storage["storage"]
      node_name = storage["node"]
      shared = storage["shared"] == 1
      ems_ref = shared ? storage_name : "#{node_name}/#{storage_name}"

      unless parsed_storages[ems_ref]
        total_space = storage["maxdisk"]
        used_space = storage["disk"]
        free_space = total_space && used_space ? total_space - used_space : nil

        parsed_storages[ems_ref] = persister.storages.build(
          :ems_ref            => ems_ref,
          :name               => shared ? storage_name : "#{storage_name} (#{node_name})",
          :store_type         => storage["plugintype"],
          :total_space        => total_space,
          :free_space         => free_space,
          :multiplehostaccess => shared,
          :location           => storage_name
        )
      end

      persister.host_storages.build(
        :storage => persister.storages.lazy_find(ems_ref),
        :host    => persister.hosts.lazy_find(node_name)
      )
    end
  end

  def networks
    collector.networks.each do |network|
    end
  end

  def vms
    cluster_data = collector.cluster
    cluster = cluster_data ? persister.clusters.lazy_find(cluster_data["id"]) : nil

    collector.vms.each do |vm|
      ems_ref  = vm["id"].gsub("qemu/", "")
      template = vm["template"] == 1
      config   = vm["config"] || {}
      status   = vm["status"] || {}
      node_name = vm["node"]

      vm_obj = persister.vms_and_templates.build(
        :type            => "#{persister.manager.class}::#{template ? "Template" : "Vm"}",
        :ems_ref         => ems_ref,
        :uid_ems         => ems_ref,
        :name            => vm["name"],
        :template        => template,
        :raw_power_state => template ? "never" : (status["qmpstatus"] || vm["status"]),
        :host            => persister.hosts.lazy_find(node_name),
        :ems_cluster     => cluster,
        :location        => "#{node_name}/#{vm["vmid"]}",
        :vendor          => "proxmox",
        :description     => config["description"],
        :tools_status    => parse_tools_status(config, vm["agent_info"])
      )

      hardware = parse_hardware(vm_obj, config, status)
      parse_disks(hardware, config, node_name)
      parse_networks(hardware, vm)
      parse_operating_system(vm_obj, vm["agent_info"], config)
      parse_snapshots(vm_obj, vm["snapshots"])
    end
  end

  def parse_snapshots(vm_obj, snapshots)
    return unless snapshots

    current_snapshot = snapshots.find { |s| s["name"] == "current" }
    current_parent = current_snapshot&.dig("parent")

    snapshots.each do |snapshot|
      next if snapshot["name"] == "current"

      parent = nil
      if snapshot["parent"].present?
        parent = persister.snapshots.lazy_find(
          :vm_or_template => vm_obj,
          :uid            => snapshot["parent"]
        )
      end

      persister.snapshots.build(
        :uid_ems        => snapshot["name"],
        :uid            => snapshot["name"],
        :ems_ref        => snapshot["name"],
        :parent_uid     => snapshot["parent"],
        :parent         => parent,
        :name           => snapshot["name"],
        :description    => snapshot["description"],
        :create_time    => snapshot["snaptime"] ? Time.zone.at(snapshot["snaptime"].to_i) : nil,
        :current        => snapshot["name"] == current_parent,
        :vm_or_template => vm_obj
      )
    end
  end

  def parse_tools_status(config, agent_info)
    return "toolsNotInstalled" unless config["agent"].to_s.start_with?("1")

    agent_info.present? ? "toolsOk" : "toolsNotRunning"
  end

  def parse_hardware(vm_obj, config, status)
    persister.hardwares.build(
      :vm_or_template  => vm_obj,
      :cpu_total_cores => status["cpus"] || (config["cores"].to_i * config.fetch("sockets", 1).to_i),
      :memory_mb       => (status["maxmem"] || (config["memory"].to_i * 1024 * 1024)) / 1024 / 1024,
      :disk_capacity   => status["maxdisk"]
    )
  end

  def parse_disks(hardware, config, node_name)
    disk_keys = config.keys.grep(/^(scsi|ide|sata|virtio|nvme)\d+$/)

    disk_keys.each do |disk_id|
      disk_str = config[disk_id]
      next if disk_str.include?("media=cdrom")

      size_bytes = parse_disk_size(disk_str)
      storage_name = disk_str.split(":").first
      storage_ems_ref = storage_ems_ref_for(storage_name, node_name)

      persister.disks.build(
        :hardware        => hardware,
        :device_name     => disk_id,
        :device_type     => "disk",
        :controller_type => disk_id.gsub(/\d+$/, ""),
        :size            => size_bytes,
        :location        => disk_id,
        :filename        => disk_str.split(",").first,
        :storage         => persister.storages.lazy_find(storage_ems_ref)
      )
    end
  end

  def storage_ems_ref_for(storage_name, node_name)
    storage_info = collector.storages_by_name["#{node_name}/#{storage_name}"]
    return storage_name unless storage_info

    storage_info["shared"] == 1 ? storage_name : "#{node_name}/#{storage_name}"
  end

  def parse_disk_size(disk_str)
    return nil unless disk_str

    size_match = disk_str.match(/size=(\d+)([TGMK]?)/)
    return nil unless size_match

    size = size_match[1].to_i
    unit = size_match[2]

    case unit
    when "T" then size * 1024 * 1024 * 1024 * 1024
    when "G" then size * 1024 * 1024 * 1024
    when "M" then size * 1024 * 1024
    when "K" then size * 1024
    else size
    end
  end

  def parse_networks(hardware, vm)
    agent_networks = vm["networks"]
    return unless agent_networks

    agent_networks.each do |iface|
      next if iface["name"] == "lo"

      mac = iface["hardware-address"]&.downcase
      ipv4 = iface["ip-addresses"]&.find { |ip| ip["ip-address-type"] == "ipv4" }
      ipv6 = iface["ip-addresses"]&.find { |ip| ip["ip-address-type"] == "ipv6" }

      network = persister.networks.build(
        :hardware    => hardware,
        :description => iface["name"],
        :hostname    => vm["hostname"],
        :ipaddress   => ipv4&.dig("ip-address"),
        :ipv6address => ipv6&.dig("ip-address")
      )

      persister.guest_devices.build(
        :hardware        => hardware,
        :uid_ems         => "#{vm["vmid"]}-#{iface["name"]}",
        :device_name     => iface["name"],
        :device_type     => "ethernet",
        :controller_type => "ethernet",
        :address         => mac,
        :network         => network
      )
    end
  end

  def parse_mac(net_config)
    net_config&.match(/([0-9a-fA-F:]{17})/)&.[](1)&.downcase
  end

  def parse_operating_system(vm_obj, agent_info, config)
    product_name = if agent_info.present?
                     agent_info["pretty-name"] || agent_info["name"]
                   else
                     map_ostype(config["ostype"])
                   end

    persister.operating_systems.build(
      :vm_or_template => vm_obj,
      :product_name   => product_name || "Unknown"
    )
  end

  def map_ostype(ostype)
    case ostype.to_s
    when /^w/  then "Windows"
    when "l26" then "Linux"
    when "l24" then "Linux (2.4 kernel)"
    else ostype
    end
  end

  private

  def parse_host_hardware(host_obj, host, status)
    cpuinfo = status["cpuinfo"] || {}
    memory = status["memory"] || {}
    rootfs = status["rootfs"] || {}

    persister.host_hardwares.build(
      :host                 => host_obj,
      :cpu_type             => cpuinfo["model"] || "Unknown",
      :cpu_speed            => cpuinfo["mhz"]&.to_f&.round,
      :cpu_total_cores      => cpuinfo["cpus"] || host["maxcpu"],
      :cpu_cores_per_socket => cpuinfo["cores"] || 1,
      :cpu_sockets          => cpuinfo["sockets"] || 1,
      :memory_mb            => memory["total"] ? (memory["total"] / 1.megabyte) : (host["maxmem"] / 1.megabyte),
      :disk_capacity        => rootfs["total"]
    )
  end

  def parse_host_operating_system(host_obj)
    # Currently there is no suitable API Endpoint to determine the underlying base OS like Debian
    persister.host_operating_systems.build(
      :host         => host_obj,
      :name         => "Proxmox VE",
      :product_name => "Debian",
      :version      => "N/A",
      :build_number => "N/A"
    )
  end

  def parse_host_network_adapters(hardware, networks)
    return if networks.blank?

    networks.each do |iface|
      next unless iface["type"] == "eth"

      persister.host_guest_devices.build(
        :hardware        => hardware,
        :uid_ems         => iface["iface"],
        :device_name     => iface["iface"],
        :device_type     => "ethernet",
        :controller_type => "ethernet",
        :present         => iface["active"] == 1,
        :address         => iface["address"],
        :location        => iface["iface"]
      )
    end
  end

  def parse_host_switches(host_obj, hardware, networks)
    return if networks.blank?

    switches = {}

    networks.each do |iface|
      next unless iface["type"] == "bridge"

      switch = persister.host_virtual_switches.build(
        :host    => host_obj,
        :uid_ems => iface["iface"],
        :name    => iface["iface"]
      )
      switches[iface["iface"]] = switch

      persister.host_switches.build(:host => host_obj, :switch => switch)

      persister.host_virtual_lans.build(
        :switch  => switch,
        :uid_ems => iface["iface"],
        :name    => iface["iface"],
        :tag     => ""
      )

      link_pnics_to_switch(hardware, iface["bridge_ports"], switch)
    end
  end

  def link_pnics_to_switch(hardware, bridge_ports, switch)
    return if bridge_ports.blank?

    bridge_ports.to_s.split.each do |pnic_name|
      pnic = persister.host_guest_devices.find_or_build_by(:hardware => hardware, :uid_ems => pnic_name)
      pnic.assign_attributes(:switch => switch)
    end
  end
end
