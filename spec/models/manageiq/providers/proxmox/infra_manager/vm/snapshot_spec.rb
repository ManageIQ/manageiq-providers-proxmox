describe ManageIQ::Providers::Proxmox::InfraManager::Vm do
  include Spec::Support::EmsRefreshHelper

  let(:zone) { EvmSpecHelper.local_miq_server.zone }
  let(:ems)  { FactoryBot.create(:ems_proxmox_with_vcr_authentication, :zone => zone) }
  let(:host) { FactoryBot.create(:host_proxmox, :ems_ref => "vmpvetest2", :ext_management_system => ems) }
  let(:vm)   { FactoryBot.create(:vm_proxmox, :name => "test-vm", :ems_ref => "101", :ext_management_system => ems, :host => host) }

  before { NotificationType.seed }

  describe "#raw_create_snapshot" do
    it "creates a snapshot" do
      with_vcr("vm/snapshot/create") do
        expect { vm.raw_create_snapshot("test_snap", "Test snapshot") }.not_to raise_error
      end
    end
  end

  describe "#raw_remove_snapshot" do
    let!(:snapshot) { FactoryBot.create(:snapshot, :vm_or_template => vm, :name => "test_snap", :uid_ems => "test_snap", :ems_ref => "test_snap") }

    it "removes a snapshot" do
      with_vcr("vm/snapshot/remove") do
        expect { vm.raw_remove_snapshot(snapshot.id) }.not_to raise_error
      end
    end
  end

  describe "#raw_revert_to_snapshot" do
    let!(:snapshot) { FactoryBot.create(:snapshot, :vm_or_template => vm, :name => "test_snap", :uid_ems => "test_snap", :ems_ref => "test_snap") }

    it "reverts to a snapshot" do
      with_vcr("vm/snapshot/revert") do
        expect { vm.raw_revert_to_snapshot(snapshot.id) }.not_to raise_error
      end
    end
  end
end
