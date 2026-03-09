class ManageIQ::Providers::Proxmox::InfraManager::ProvisionWorkflow < ManageIQ::Providers::InfraManager::ProvisionWorkflow
  def initialize(values, requester, options = {})
    values ||= {}
    values[:number_of_vms] ||= 1
    values[:linked_clone] ||= false
    super
  end

  def self.default_dialog_file
    'miq_provision_proxmox_dialogs_template'
  end

  def supports_pxe?
    false
  end

  def supports_iso?
    false
  end

  def supports_cloud_init?
    false
  end

  def dialog_name_from_automate(message = 'get_dialog_name', extra_attrs = {})
    super(message, extra_attrs)
  end

  def update_field_visibility(_options = {})
    show_fields(:edit, %i[linked_clone])
  end

  def allowed_storages(_options = {})
    src = get_source_and_targets
    return [] if src.blank? || src[:ems].nil?

    load_ar_obj(src[:ems]).storages.collect { |s| ci_to_hash_struct(s) }
  end

  def allowed_hosts(_options = {})
    src = get_source_and_targets
    return [] if src.blank? || src[:ems].nil?

    load_ar_obj(src[:ems]).hosts.collect { |h| ci_to_hash_struct(h) }
  end

  def allowed_number_of_vms(_options = {})
    (1..50).index_with(&:to_s)
  end

  def allowed_templates(_options = {})
    return {} unless @ems

    @ems.miq_templates.each_with_object({}) { |t, h| h[t.id] = t.name }
  end

  def allowed_disk_formats(_options = {})
    {
      # TODO: Implement storage selected specific formats
    }
  end

  def validate_vm_name(_field, values, _dlg, _fld, _value)
    vm_name = get_value(values[:vm_name])
    return _("VM Name is required") if vm_name.blank?
    return _("VM Name '%{name}' already exists") % {:name => vm_name} if @ems&.vms&.find_by(:name => vm_name)

    nil
  end
end
