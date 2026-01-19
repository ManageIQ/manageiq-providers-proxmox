class ManageIQ::Providers::Proxmox::InfraManager::Vm < ManageIQ::Providers::InfraManager::Vm
  include Operations
  include RemoteConsole
  include ManageIQ::Providers::Proxmox::InfraManager::Vm::Reconfigure
  include ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Configuration
#  include Reconfigure

  supports :terminate
  supports :reboot_guest
  supports :reset
  supports :suspend
  supports :start
  supports :stop
  supports :shutdown_guest
  supports :reconfigure_disksize do
    'Cannot resize disks of a VM with snapshots' if snapshots.count > 1
  end
  supports :reconfigure_disks do
    if storage.blank?
      _('storage is missing')
    elsif ext_management_system.blank?
      _('The virtual machine is not associated with a provider')
    elsif !ext_management_system.supports?(:reconfigure_disks)
      _('The provider does not support reconfigure disks')
    end
  end



  POWER_STATES = {
    'running'   => 'on',
    'stopped'   => 'off',
    'paused'    => 'paused',
    'suspended' => 'suspended'
  }.freeze

  def power_state
    self.class.calculate_power_state(raw_power_state)
  end


  def self.calculate_power_state(raw_power_state)
    POWER_STATES[raw_power_state] || super
  end

  def raw_start
    with_provider_connection do |connection|
      connection.post("nodes/#{location}/status/start")
    end
    self.update!(:raw_power_state => 'running')
  end

  def raw_stop
    with_provider_connection do |connection|
      connection.post("nodes/#{location}/status/stop")
    end
    self.update!(:raw_power_state => 'stopped')
  end

  def raw_suspend
    with_provider_connection do |connection|
      connection.post("nodes/#{location}/status/suspend")
    end
    self.update!(:raw_power_state => 'paused')
  end

  def raw_reboot_guest
    with_provider_connection do |connection|
      connection.post("nodes/#{location}/status/reboot")
    end
  end

  def raw_reset
    with_provider_connection do |connection|
      connection.post("nodes/#{location}/status/reset")
    end
  end

  def raw_shutdown_guest
    with_provider_connection do |connection|
      connection.post("nodes/#{location}/status/shutdown")
    end
    self.update!(:raw_power_state => 'stopped')
  end

  def remove_snapshot_queue(snap_id, userid = "system")
    task_opts = {
      :action => "removing snapshot for VM '#{name}'",
      :userid => userid
    }
    
    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'remove_snapshot_async',
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :args        => [snap_id]
    }
    
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def params_for_create_snapshot
    {
      :fields => [
        {
          :component  => 'textarea',
          :name       => 'description',
          :id         => 'description',
          :label      => _('Description'),
          :isRequired => true,
          :validate   => [{:type => 'required'}],
        },
        {
          :component  => 'switch',
          :name       => 'memory',
          :id         => 'memory',
          :label      => _('Snapshot VM memory'),
          :onText     => _('Yes'),
          :offText    => _('No'),
          :isDisabled => current_state != 'on',
          :helperText => _('Snapshotting the memory is only available if the VM is powered on.'),
        },
      ],
    }
  end
    def raw_resize_disk(disk_name, new_size_gb)
    raise MiqException::MiqVmError, "VM has no EMS, unable to resize disk" unless ext_management_system
    
    _log.info("Resizing disk #{disk_name} to #{new_size_gb}GB for VM #{name}")
    
    with_provider_connection do |connection|
      node = host.name
      vmid = ems_ref
      
      # Convertir la taille en format Proxmox (ex: "50G")
      size = "#{new_size_gb}G"
      
      # Appel API Proxmox pour redimensionner le disque
      connection.put("/nodes/#{node}/qemu/#{vmid}/resize", {
        disk: disk_name,
        size: size
      })
      
      _log.info("Disk #{disk_name} resized successfully to #{new_size_gb}GB")
    end
  rescue => err
    _log.error("Error resizing disk: #{err}")
    raise MiqException::MiqVmError, "Unable to resize disk: #{err}"
  end

  def resize_disk_queue(userid, disk_name, new_size_gb)
    task_opts = {
      :action => "Resizing disk #{disk_name} to #{new_size_gb}GB for VM '#{name}'",
      :userid => userid
    }
    
    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'raw_resize_disk',
      :args        => [disk_name, new_size_gb],
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :miq_callback => {
        :class_name  => task_opts[:class_name],
        :instance_id => task_opts[:instance_id],
        :method_name => :queue_callback_on_exceptions,
        :args        => ['Finished']
      }
    }
    
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  supports :resize_disk do
    if !ext_management_system
      _("The VM is not connected to a provider")
    elsif !%w[poweredOn poweredOff].include?(power_state)
      _("The VM must be powered on or off to resize disk")
    end
  end

end


