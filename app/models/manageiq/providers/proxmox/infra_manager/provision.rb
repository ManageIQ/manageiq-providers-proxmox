class ManageIQ::Providers::Proxmox::InfraManager::Provision < MiqProvision
  include Cloning

  def destination_type
    "Vm"
  end

  def dest_name
    get_option(:vm_target_name) || get_option(:vm_name)
  end

  def request_type
    "template"
  end

  def source_type
    "template"
  end

  def create_destination
    signal :clone_vm
  end

  def clone_vm
    $proxmox_log.info("Cloning template #{source.name} to #{dest_name}")
    start_clone(prepare_for_clone_task)
    signal :poll_clone_complete
  rescue => err
    $proxmox_log.error("Clone failed: #{err.message}")
    $proxmox_log.log_backtrace(err)
    raise MiqException::MiqProvisionError, err.message
  end

  def poll_clone_complete
    clone_complete? ? signal(:customize_hardware) : requeue_phase
  end

  def customize_hardware
    $proxmox_log.info("Applying hardware customization to VM #{phase_context[:new_vmid]}")
    upid = start_hardware_customization
    phase_context[:customize_task_upid] = upid
    signal :poll_customize_hardware_complete
  rescue => err
    $proxmox_log.error("Hardware customization failed: #{err.message}")
    $proxmox_log.log_backtrace(err)
    raise MiqException::MiqProvisionError, err.message
  end

  def poll_customize_hardware_complete
    customize_task_complete? ? signal(:resize_disk) : requeue_phase
  end

  def resize_disk
    $proxmox_log.info("Resizing boot disk for VM #{phase_context[:new_vmid]}")
    upid = start_resize_boot_disk
    phase_context[:customize_task_upid] = upid
    signal :poll_resize_disk_complete
  rescue => err
    $proxmox_log.error("Disk resize failed: #{err.message}")
    $proxmox_log.log_backtrace(err)
    raise MiqException::MiqProvisionError, err.message
  end

  def poll_resize_disk_complete
    customize_task_complete? ? signal(:rekey_tpm) : requeue_phase
  end

  def rekey_tpm
    $proxmox_log.info("Re-keying TPM for VM #{phase_context[:new_vmid]}")
    upid = start_tpm_rekey
    phase_context[:customize_task_upid] = upid
    signal :poll_rekey_tpm_complete
  rescue => err
    $proxmox_log.error("TPM re-key failed: #{err.message}")
    $proxmox_log.log_backtrace(err)
    raise MiqException::MiqProvisionError, err.message
  end

  def poll_rekey_tpm_complete
    customize_task_complete? ? signal(:perform_refresh) : requeue_phase
  end

  def perform_refresh
    new_vmid = phase_context[:new_vmid].to_s
    $proxmox_log.info("Performing targeted refresh for new VM with ems_ref: #{new_vmid}")
    EmsRefresh.refresh(InventoryRefresh::Target.new(
                         :manager     => source.ext_management_system,
                         :association => :vms_and_templates,
                         :manager_ref => {:ems_ref => new_vmid}
                       ))
    signal :poll_destination_in_vmdb
  end

  def poll_destination_in_vmdb
    new_vmid = phase_context[:new_vmid].to_s
    vm = source.ext_management_system.vms.find_by(:ems_ref => new_vmid)
    if vm
      $proxmox_log.info("Found VM in VMDB: #{vm.name} (ems_ref: #{vm.ems_ref})")
      phase_context[:destination_vm_id] = vm.id
      signal :finalize_destination
    else
      $proxmox_log.info("VM with ems_ref #{new_vmid} not found in VMDB, retrying...")
      requeue_phase
    end
  end

  def finalize_destination
    vm = Vm.find(phase_context[:destination_vm_id])
    self.destination = vm
    vm.raw_start if get_option(:vm_auto_start)
    $proxmox_log.info("Provisioning complete: #{vm.name}")
    signal :post_create_destination
  end

  private

  def with_provider_connection(...)
    source.ext_management_system.with_provider_connection(...)
  end

  def clone_complete?
    return true if phase_context[:clone_complete]

    upid = phase_context[:clone_task_upid]
    return phase_context[:clone_complete] = true unless upid

    check_task_status(upid)
  end

  def check_task_status(upid)
    node_id = upid.split(":")[1].presence || phase_context[:clone_node_id]
    with_provider_connection do |connection|
      status = connection.request(:get, "/nodes/#{node_id}/tasks/#{URI.encode_uri_component(upid)}/status")
      $proxmox_log.info("Task #{upid}: #{status['status']} (exit: #{status['exitstatus']})")

      case status["status"]
      when "stopped"
        raise MiqException::MiqProvisionError, "Clone failed: #{status['exitstatus']}" unless status["exitstatus"] == "OK"

        phase_context[:clone_complete] = true
      else
        false
      end
    end
  end
end
