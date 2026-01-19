module ManageIQ::Providers::Proxmox::InfraManager::Vm::Operations::Snapshot
  extend ActiveSupport::Concern

  included do
    supports :snapshots
    supports :revert_to_snapshot
    supports_not :remove_all_snapshots, :reason => N_("Removing all snapshots is currently not supported")
  end

 def raw_create_snapshot(_name, desc, memory)
  with_provider_connection do |connection|
    snapshot_name = _name || "snapshot-#{Time.now.to_i}"
    params = { :snapname => snapshot_name }
    params[:description] = desc if desc
    params[:vmstate] = 1 if memory

    _log.info("Lancement de la création du snapshot '#{snapshot_name}' pour la VM #{name}...")
    upid = connection.post("nodes/#{location}/snapshot", params)

    if upid.present?
      node = upid.split(':')[1]
      raise "Impossible d'extraire le nœud de l'UPID : #{upid}" if node.blank?

      path = "nodes/#{node}/tasks/#{upid}/status"
      timeout = 300 
      
      response = {} 
      start_time = Time.now.utc

      loop do
        if Time.now.utc > start_time + timeout
          raise "La création du snapshot (tâche #{upid}) a expiré après #{timeout} secondes."
        end

        response = connection.get(path)
        break if response['status'] == 'stopped'
        
        sleep(5)
      end

      exit_status = response['exitstatus']
      unless exit_status == 'OK'
        _log.error("Snashopt creation failed,task #{upid}, Status: #{exit_status}")
        raise " Status Proxmox : #{exit_status}"
      end

      _log.info("Task Proxmox #{upid} successfuly terminated.")
    end


    _log.info("Snapshot '#{snapshot_name}' created, refresh of the VM running#{name}.")
    EmsRefresh.queue_refresh(self)

    snapshot_name
   end
  end


  def raw_remove_snapshot(snapshot_id)
    task = MiqTask.create(
      :name   => "Deleting snapshot for VM '#{name}'",
      :state  => 'Queued',
      :status => 'Ok',
      :userid => 'system' 
    )

    MiqQueue.put(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'remove_snapshot_async',
      :args        => [snapshot_id, task.id], 
      :zone        => my_zone,
      :role        => 'ems_operations',
      :msg_timeout => 3600 
    )

    task.id 
  end
  
  def remove_snapshot_async(snapshot_id, miq_task_id)
  task = MiqTask.find(miq_task_id)
  
  if task.context_data.nil?
    task.context_data = {}
    task.save!
  end
  
  phase = task.context_data[:phase]

  case phase
  when nil 
    _log.info("Phase 1: Initiating snapshot deletion for VM(id=#{id}), Snapshot(id=#{snapshot_id})")
    upid = raw_remove_snapshot_start(snapshot_id)

    task.context_data[:proxmox_upid] = upid
    task.context_data[:phase] = 'polling'
    task.message = "Snapshot deletion initiated on Proxmox (Task ID: #{upid}). Waiting for completion..."
    task.save!

    MiqQueue.put(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'remove_snapshot_async',
      :args        => [snapshot_id, miq_task_id],
      :zone        => my_zone,
      :role        => 'ems_operations',
      :deliver_on  => Time.now.utc + 10.seconds
    )

  when 'polling' 
    upid = task.context_data[:proxmox_upid]
    _log.info("Phase 2: Polling status for Proxmox task #{upid}")
    status, exit_status = raw_check_task_status(upid)

    _log.info("PROXMOX DEBUG POLLING: Status received: [#{status}], Exit Status: [#{exit_status}]")

    if status == 'running'
      MiqQueue.put(
        :class_name  => self.class.name,
        :instance_id => id,
        :method_name => 'remove_snapshot_async',
        :args        => [snapshot_id, miq_task_id],
        :zone        => my_zone,
        :role        => 'ems_operations',
        :deliver_on  => Time.now.utc + 20.seconds
      )
    elsif status == 'stopped' && exit_status == 'OK'
      _log.info("Proxmox task #{upid} completed successfully.")
      snapshot = snapshots.find_by(:id => snapshot_id)
      if snapshot
        _log.info("Deleting snapshot record (id: #{snapshot.id}, name: '#{snapshot.name}') from MIQ database.")
        snapshot.destroy
      end
   
      task.update!(
        :state   => MiqTask::STATE_FINISHED,
        :status  => MiqTask::STATUS_OK,
        :message => 'Snapshot deletion completed successfully.'
      )
      
      EmsRefresh.queue_refresh(self)
    else
      _log.error("Proxmox task #{upid} failed. Status: [#{status}], Exit Status: [#{exit_status}]")
      
      task.update!(
        :state   => MiqTask::STATE_FINISHED,
        :status  => MiqTask::STATUS_ERROR,
        :message => "Snapshot deletion failed on Proxmox. Final Status: '#{exit_status}'"
      )
    end
   end
  end 

  
  def raw_revert_to_snapshot(snapshot_id)
   task = MiqTask.create(
    :name   => "Reverting to snapshot for VM '#{name}'",
    :state  => MiqTask::STATE_QUEUED,
    :status => MiqTask::STATUS_OK,
    :userid => 'system'
   )

   MiqQueue.put(
    :class_name  => self.class.name,
    :instance_id => id,
    :method_name => 'revert_to_snapshot_async',
    :args        => [snapshot_id, task.id],
    :zone        => my_zone,
    :role        => 'ems_operations',
    :msg_timeout => 3600
   )

   task.id
 end

  def revert_to_snapshot_async(snapshot_id, miq_task_id)
   task = MiqTask.find(miq_task_id)
  
   if task.context_data.nil?
    task.context_data = {}
    task.save!
   end
  
  phase = task.context_data[:phase]

  case phase
  when nil 
    snapshot = snapshots.find_by(:id => snapshot_id)
    unless snapshot
      task.update!(
        :state   => MiqTask::STATE_FINISHED,
        :status  => MiqTask::STATUS_ERROR,
        :message => "Snapshot with ID #{snapshot_id} not found."
      )
      return
    end

   _log.info("Phase 1: Initiating snapshot revert for VM(id=#{id}), Snapshot(ems_ref='#{snapshot.ems_ref}')") 

    upid = raw_revert_to_snapshot_start(snapshot.ems_ref)

    task.context_data[:proxmox_upid] = upid
    task.context_data[:phase] = 'polling'
    task.message = "Snapshot revert initiated on Proxmox (Task ID: #{upid}). Waiting for completion..."
    task.save!

    MiqQueue.put(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'revert_to_snapshot_async',
      :args        => [snapshot_id, miq_task_id],
      :zone        => my_zone,
      :role        => 'ems_operations',
      :deliver_on  => Time.now.utc + 10.seconds
    )

   when 'polling' 
    upid = task.context_data[:proxmox_upid]
    _log.info("Phase 2: Polling status for Proxmox revert task #{upid}")
    status, exit_status = raw_check_task_status(upid)

    _log.info("PROXMOX DEBUG REVERT POLLING: Status received: [#{status}], Exit Status: [#{exit_status}]")

    if status == 'running'
      MiqQueue.put(
        :class_name  => self.class.name,
        :instance_id => id,
        :method_name => 'revert_to_snapshot_async',
        :args        => [snapshot_id, miq_task_id],
        :zone        => my_zone,
        :role        => 'ems_operations',
        :deliver_on  => Time.now.utc + 20.seconds
      )
    elsif status == 'stopped' && exit_status == 'OK'
      _log.info("Proxmox revert task #{upid} completed successfully.")
      
      task.update!(
        :state   => MiqTask::STATE_FINISHED,
        :status  => MiqTask::STATUS_OK,
        :message => 'Snapshot revert completed successfully.'
      )
      
      EmsRefresh.queue_refresh(self)
    else
      _log.error("Proxmox revert task #{upid} failed. Status: [#{status}], Exit Status: [#{exit_status}]")
      
      task.update!(
        :state   => MiqTask::STATE_FINISHED,
        :status  => MiqTask::STATUS_ERROR,
        :message => "Snapshot revert failed on Proxmox. Final Status: '#{exit_status}'"
      )
    end
   end
  end


  def raw_revert_to_snapshot_start(snapshot_name)
   with_provider_connection do |connection|

   _log.info("Initiating rollback to snapshot '#{snapshot_name}' on Proxmox for VM #{uid_ems}")

    path = "nodes/#{location}/snapshot/#{snapshot_name}/rollback"


    result = connection.post(path, {})
    
    _log.info("Proxmox rollback initiated. UPID: #{result}")
    result
   end
  end
  
  def snapshot_name_optional?
    true
  end

  def snapshot_description_required?
    false
  end

  def allowed_to_revert?
    current_state == 'off'
  end

  def revert_to_snapshot_denied_message(active = false)
    return revert_unsupported_message unless allowed_to_revert?
    _("Revert is not allowed for a snapshot that is the active one") if active
  end

  def remove_snapshot_denied_message(active = false)
    _("Delete is not allowed for a snapshot that is the active one") if active
  end

  def snapshotting_memory_allowed?
    current_state == 'on'
  end


  def raw_remove_snapshot_start(snapshot_id)
    snapshot = snapshots.find_by(:id => snapshot_id)
    raise "Snapshot with id [#{snapshot_id}] not found for VM [#{name}]" unless snapshot
    node, _type, vmid = location.split('/')
    api_path = "nodes/#{node}/qemu/#{vmid}/snapshot/#{snapshot.ems_ref}"
    _log.info("Calling Proxmox API: DELETE #{api_path}")
    with_provider_connection { |connection| connection.delete(api_path) }
  end

  def raw_check_task_status(upid)
    node = upid.split(':')[1]
    api_path = "nodes/#{node}/tasks/#{upid}/status"
    with_provider_connection do |connection|
      response = connection.get(api_path)
      [response['status'], response['exitstatus']]
    end
  end

  def revert_unsupported_message
    _("Revert is allowed only when VM is down. Current state is %{state}") % { :state => current_state }
  end
end
