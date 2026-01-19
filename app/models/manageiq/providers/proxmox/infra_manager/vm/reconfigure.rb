module ManageIQ::Providers::Proxmox::InfraManager::Vm::Reconfigure
  def reconfigurable?
    active?
  end

  def max_total_vcpus
    128
  end

  def max_cpu_cores_per_socket(_total_vcpus = nil)
    128
  end

  def max_vcpus
    max_total_vcpus
  end

  def max_memory_mb
    4.terabyte / 1.megabyte
  end

  def validate_config_spec(_options = {})
    {}
  end

  def build_config_spec(task_options)
    task_options.deep_stringify_keys!
    
    spec = {}
    
    spec['cores'] = task_options['cores_per_socket'].to_i if task_options['cores_per_socket']
    
    if task_options['number_of_cpus']
      cores = task_options['cores_per_socket']&.to_i || cpu_cores_per_socket || 1
      sockets = (task_options['number_of_cpus'].to_f / cores).ceil
      spec['sockets'] = sockets
      spec['cores'] = cores
    end
    
    spec['memory'] = task_options['vm_memory'].to_i if task_options['vm_memory']
    
    spec['cpu'] = task_options['cpu_type'] if task_options['cpu_type']
    
    spec['description'] = task_options['description'] if task_options['description']
    
    spec['onboot'] = task_options['onboot'] ? 1 : 0 if task_options.key?('onboot')
    spec['boot'] = task_options['boot_order'] if task_options['boot_order']
    
    spec['protection'] = task_options['protection'] ? 1 : 0 if task_options.key?('protection')

    spec['disksAdd'] = spec_for_added_disks(task_options['disk_add']) if task_options['disk_add']
    spec['disksResize'] = spec_for_disks_resize(task_options['disk_resize']) if task_options['disk_resize']
    spec['disksEdit'] = spec_for_disks_resize(task_options['disk_resize']) if task_options['disk_resize']  # Alias
    spec['disksRemove'] = task_options['disk_remove'] if task_options['disk_remove']
    
    spec['networkAdapters'] = spec_for_network_adapters(task_options) if has_network_changes?(task_options)
    
    _log.info("Built config spec: #{spec.inspect}")
    spec
  end

  def spec_for_added_disks(disks)
    disks.collect do |disk|
      {
        'disk_size_in_mb' => disk['disk_size_in_mb'].to_i,
        'datastore' => disk['datastore'] || 'local-lvm',
        'thin_provisioned' => disk['thin_provisioned'] || true,
        'interface' => disk['interface'] || 'scsi'
      }
    end
  end

  def spec_for_disks_resize(disks)
    _log.info("spec_for_disks_resize called with: #{disks.inspect}")
    
    disks.collect do |d|
      filename = d['disk_name']
      disk = find_disk_by_filename(filename)

      raise MiqException::MiqVmError, "No disk with filename [#{filename}] was found" unless disk
      raise MiqException::MiqVmError, 'New disk size must be larger than the current one' unless disk_size_valid?(disk.size, d['disk_size_in_mb'])

      {
        'disk_name' => d['disk_name'],
        'disk_size_in_mb' => d['disk_size_in_mb'].to_i
      }
    end
  end

  def find_disk_by_filename(filename)
    hardware.disks.find_by(:filename => filename)
  end

  def disk_size_valid?(current_size, new_size_str)
    new_size = Integer(new_size_str)
    new_size.megabytes >= current_size
  rescue
    false
  end

  def has_network_changes?(task_options)
    task_options['network_adapter_add'].present? ||
      task_options['network_adapter_edit'].present? ||
      task_options['network_adapter_remove'].present?
  end

  def spec_for_network_adapters(task_options)
    # À implémenter plus tard
    {}
  end

  def raw_reconfigure(spec)
    ext_management_system.vm_reconfigure(self, :spec => spec)
  end
end