describe ManageIQ::Providers::Proxmox::InfraManager::Vm do
  include Spec::Support::EmsRefreshHelper

  let(:zone) { EvmSpecHelper.local_miq_server.zone }
  let(:ems)  { FactoryBot.create(:ems_proxmox_with_vcr_authentication, :zone => zone) }
  let(:vm)   { ems.vms.find_by(:ems_ref => "101") }

  before do
    NotificationType.seed
    with_vcr { ManageIQ::Providers::Proxmox::InfraManager::Refresher.refresh([ems]) }
  end

  describe "snapshot operations" do
    it "creates, deletes, and reverts snapshots" do
      with_vcr("vm/snapshot/workflow") do
        expect { vm.raw_create_snapshot("test_snap1", "Test snapshot 1") }.not_to raise_error
        expect { vm.raw_create_snapshot("test_snap2", "Test snapshot 2") }.not_to raise_error

        # Refresh to get snapshots in DB
        ManageIQ::Providers::Proxmox::InfraManager::Refresher.refresh([ems])

        snapshot1 = vm.snapshots.find_by(:name => "test_snap1")
        expect(snapshot1).not_to be_nil
        expect { vm.raw_remove_snapshot(snapshot1.id) }.not_to raise_error

        ManageIQ::Providers::Proxmox::InfraManager::Refresher.refresh([ems])

        # Revert to oldest snapshot should fail (ZFS limitation)
        oldest_snapshot = vm.snapshots.where.not(:name => "current").order(:create_time).first
        expect { vm.raw_revert_to_snapshot(oldest_snapshot.id) }.to raise_error(MiqException::MiqVmSnapshotError)

        # Revert to most recent snapshot should succeed
        recent_snapshot = vm.snapshots.where.not(:name => "current").order(:create_time => :desc).first
        expect { vm.raw_revert_to_snapshot(recent_snapshot.id) }.not_to raise_error
      end
    end
  end
end
