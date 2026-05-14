describe ManageIQ::Providers::Proxmox::InfraManager::Provision do
  let(:zone)     { EvmSpecHelper.local_miq_server.zone }
  let(:ems)      { FactoryBot.create(:ems_proxmox_with_authentication, :zone => zone) }
  let(:template) { FactoryBot.create(:template_proxmox, :ext_management_system => ems, :ems_ref => "900") }
  let(:user)     { FactoryBot.create(:user_admin) }
  let(:request)  { FactoryBot.create(:miq_provision_request, :requester => user, :src_vm_id => template.id) }

  let(:options) do
    {
      :src_vm_id     => [template.id, template.name],
      :vm_name       => "new-vm",
      :number_of_vms => 1,
    }
  end

  let(:provision) do
    FactoryBot.create(
      :miq_provision_proxmox,
      :userid       => user.userid,
      :miq_request  => request,
      :source       => template,
      :request_type => "template",
      :state        => "pending",
      :status       => "Ok",
      :options      => options
    )
  end

  describe "#workflow_class" do
    it "returns the Proxmox ProvisionWorkflow class" do
      expect(provision.workflow_class).to eq(ManageIQ::Providers::Proxmox::InfraManager::ProvisionWorkflow)
    end
  end

  describe "#dest_name" do
    it "returns vm_target_name when set" do
      provision.options[:vm_target_name] = "preferred-name"
      expect(provision.dest_name).to eq("preferred-name")
    end

    it "falls back to vm_name" do
      expect(provision.dest_name).to eq("new-vm")
    end
  end

  describe "#destination_type" do
    it "is Vm" do
      expect(provision.destination_type).to eq("Vm")
    end
  end

  describe "#source_type / #request_type" do
    it "are both template" do
      expect(provision.source_type).to eq("template")
      expect(provision.request_type).to eq("template")
    end
  end
end
