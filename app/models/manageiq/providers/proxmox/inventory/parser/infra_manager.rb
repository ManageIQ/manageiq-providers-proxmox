class ManageIQ::Providers::Proxmox::Inventory::Parser::InfraManager < ManageIQ::Providers::Proxmox::Inventory::Parser
  attr_reader :collector, :persister

  def initialize(collector, persister)
    @collector = collector
    @persister = persister
  end

  def parse
    puts "=== Starting parse ==="
    clusters
    hosts
    vms
    storages
    snapshots
    puts "=== Parse completed ==="
  end

  def clusters
    cluster_name = collector.cluster_name || 'Proxmox Cluster'
    puts "Creating cluster: #{cluster_name}..."

    persister.clusters.build(
      :ems_ref => 'cluster',
      :uid_ems => 'cluster',
      :name    => cluster_name
    )
  end

  def snapshots
    puts "Parsing #{collector.snapshots.size} snapshots..."
    collector.snapshots.each do |snapshot_data|
      snap_name = snapshot_data['name']
      next if snap_name.blank?
      vm_uid = snapshot_data['vm_or_template_id'].to_s

      persister.snapshots.build(
        :uid             => "#{snapshot_data['vm_or_template_id']}_#{snapshot_data['name']}",
        :uid_ems         => "#{snapshot_data['vm_or_template_id']}_#{snapshot_data['name']}",
        :ems_ref         => snap_name,
        :name            => snap_name,
        :description     => snapshot_data['description'],
        :create_time     => snapshot_data['create_time'] ? Time.at(snapshot_data['create_time']).utc : nil,
        :current         => snapshot_data['current'] == 1,
        :parent_uid      => snapshot_data['parent'],
        :vm_or_template  => persister.vms.lazy_find(snapshot_data['vm_or_template_id'].to_s)
      )
    end
  end

  def hosts
    puts "Parsing #{collector.nodes.size} hosts..."

    node_networks = collector.node_network
    node_statuses = collector.node_status

    collector.nodes.each do |node_data|
      node_name = node_data['node']
      puts "  - Host: #{node_name}"

      network_config = node_networks[node_name] || []
      node_status = node_statuses[node_name] || {}

      node_ip = find_primary_ip(network_config)
      puts "    IP trouvée: #{node_ip || 'AUCUNE'}"

      pve_version = extract_pve_version(node_status['pveversion'])
      puts "    Version PVE: #{pve_version || 'AUCUNE'}"

      host = persister.hosts.build(
        :ems_ref          => node_name,
        :name             => node_name,
        :hostname         => node_name,
        :ipaddress        => node_ip,
        :vmm_vendor       => 'unknown',
        :vmm_product      => 'Proxmox VE',
        :vmm_version      => pve_version,
        :power_state      => node_data['status'] == 'online' ? 'on' : 'off',
        :connection_state => 'connected',
        :uid_ems          => node_name,
        :ems_cluster      => persister.clusters.lazy_find('cluster')
      )

      persister.host_hardwares.build(
        :host             => host,
        :cpu_total_cores  => node_data['maxcpu'],
        :memory_mb        => node_data['maxmem'] ? (node_data['maxmem'] / 1.megabyte).to_i : nil
      )
    end
  end

  def vms
    collector.vms.each do |vm_data|
      vm_attributes = {
        :ems_ref          => vm_data['vmid'].to_s,
        :uid_ems          => vm_data['vmid'].to_s,
        :name             => vm_data['name'] || "VM-#{vm_data['vmid']}",
        :vendor           => 'unknown',
        :raw_power_state  => vm_data['status'].to_s.downcase,
        :connection_state => 'connected',
        :location         => "#{vm_data['node']}/#{vm_data['type']}/#{vm_data['vmid']}",
        :host             => persister.hosts.lazy_find(vm_data['node']),
        :ems_cluster      => persister.clusters.lazy_find('cluster'),
        :template         => vm_data['template'] == 1
      }

      vm = persister.vms.build(vm_attributes)

      vm_config = collector.vm_config(vm_data['node'], vm_data['vmid'])

      guest_info = {}
      if vm_config['agent'].to_i == 1
        guest_info = collector.vm_guest_info(vm_data['node'], vm_data['vmid'])
      end

      # Récupération des valeurs CPU depuis vm_config (API /config)
      cpu_sockets = vm_config['sockets'].to_i
      cpu_cores = vm_config['cores'].to_i
      cpu_sockets = 1 if cpu_sockets == 0
      cpu_cores = 1 if cpu_cores == 0
      cpu_total = cpu_sockets * cpu_cores

      hardware_attributes = {
        :vm_or_template      => vm,
        :cpu_sockets         => cpu_sockets,
        :cpu_cores_per_socket => cpu_cores,
        :cpu_total_cores     => cpu_total,
        :memory_mb           => vm_config['memory'].to_i
      }

      if guest_info.present?
        hardware_attributes[:guest_os] = guest_info[:os_name] if guest_info[:os_name]
      end

      hardware = persister.hardwares.build(hardware_attributes)

      if guest_info[:mac_addresses].present?
        guest_info[:mac_addresses].each_with_index do |mac, index|
          persister.guest_devices.build(
            :hardware        => hardware,
            :device_name     => "eth#{index}",
            :device_type     => "ethernet",
            :controller_type => "ethernet",
            :address         => mac,
            :uid_ems         => "#{vm_data['vmid']}_#{mac}",
            :present         => true,
            :start_connected => true
          )
        end
      end

      if guest_info[:ipaddresses].present?
        ipv4_addresses = guest_info[:ipaddresses].select { |ip| !ip.include?(':') }
        ipv6_addresses = guest_info[:ipaddresses].select { |ip| ip.include?(':') }
        persister.networks.build(
          :hardware    => hardware,
          :ipaddress   => ipv4_addresses.first,
          :ipv6address => ipv6_addresses.first,
          :hostname    => guest_info[:hostname]
        )
      end

      if vm_config.present?
        primary_storage_assigned = false
        disk_keys = vm_config.keys.select { |k| k.to_s =~ /\A(?:scsi|virtio|ide|sata)\d+\z/ }

        disk_keys.each do |key|
          raw_disk_string = vm_config[key].to_s
          next if raw_disk_string.blank?

          is_cdrom = raw_disk_string.include?(',media=cdrom')

          storage_name, volume_spec = raw_disk_string.split(':', 2)
          volume_path = (volume_spec || raw_disk_string).split(',', 2).first
          size_in_bytes = nil
          if raw_disk_string =~ /size=(\d+)([KMGTP])?/i
            size = $1.to_i
            unit = $2.to_s.upcase
            multiplier = { "K" => 1.kilobyte, "M" => 1.megabyte, "G" => 1.gigabyte, "T" => 1.terabyte }[unit] || 1
            size_in_bytes = size * multiplier
          end

          storage_inventory_object = persister.storages.lazy_find(storage_name) if storage_name.present?

          if storage_inventory_object && !is_cdrom && !primary_storage_assigned
            vm.storage = storage_inventory_object
            primary_storage_assigned = true
          end

          persister.disks.build(
            :hardware        => hardware,
            :filename        => key.to_s,
            :storage         => storage_inventory_object,
            :device_name     => key.to_s,
            :location        => volume_path,
            :size            => size_in_bytes,
            :controller_type => key.to_s.gsub(/\d+\z/, ''),
            :disk_type       => is_cdrom ? 'cdrom' : 'disk',
            :mode            => 'persistent'
          )
        end
      end
    end
  end

  def storages
    puts "Parsing #{collector.storages.size} storages..."
    collector.storages.each do |storage_data|
      puts "  - Storage: #{storage_data['storage']}"
      persister.storages.build(
        :ems_ref      => storage_data['storage'],
        :name         => storage_data['storage'],
        :store_type   => storage_data['plugintype'] || storage_data['content'],
        :total_space  => storage_data['maxdisk'],
        :free_space   => (storage_data['maxdisk'] || 0) - (storage_data['disk'] || 0)
      )
    end
  end

  private

  def find_primary_ip(network_config)
    return nil if network_config.blank?

    primary_bridge = network_config.find do |iface|
      iface['type'] == 'bridge' &&
      iface['iface'] == 'vmbr0' &&
      iface['address'].present?
    end

    return primary_bridge['address'] if primary_bridge

    any_bridge = network_config.find do |iface|
      iface['type'] == 'bridge' &&
      iface['address'].present? &&
      !iface['iface'].include?('.')
    end

    return any_bridge['address'] if any_bridge

    any_interface = network_config.find do |iface|
      iface['address'].present? &&
      iface['iface'] != 'lo' &&
      !iface['iface'].include?('.')
    end

    any_interface&.dig('address')
  end

  def extract_pve_version(pveversion_string)
    return nil if pveversion_string.blank?

    if pveversion_string =~ /pve-manager\/([0-9.]+)/
      $1
    else
      pveversion_string
    end
  end
end