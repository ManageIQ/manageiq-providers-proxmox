module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Configuration
  extend ActiveSupport::Concern

  def raw_reconfigure(spec)
    run_command_via_parent(:vm_reconfigure, :spec => spec)
  end

  def cpu_total_cores
    hardware.cpu_total_cores || 1
  end

  def cpu_cores_per_socket
    hardware.cpu_cores_per_socket || 1
  end

  def cpu_sockets
    hardware.cpu_sockets || 1
  end

  def ram_size
    hardware.memory_mb || 512
  end
  def raw_resize_disk(disk_name, size_increase_gb)
    ext_management_system.vm_resize_disk(self, 
      :disk_name => disk_name, 
      :size_increase_gb => size_increase_gb
    )
  end
  
end