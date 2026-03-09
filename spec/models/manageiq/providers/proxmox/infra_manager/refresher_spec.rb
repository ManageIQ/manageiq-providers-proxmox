describe ManageIQ::Providers::Proxmox::InfraManager::Refresher do
  include Spec::Support::EmsRefreshHelper

  let(:ems) { FactoryBot.create(:ems_proxmox_with_vcr_authentication) }

  describe ".refresh" do
    context "full-refresh" do
      it "performs a full refresh" do
        with_vcr { described_class.refresh([ems]) }

        assert_counts
        assert_ems_counts
        assert_specific_cluster
        assert_specific_host
        assert_specific_host_hardware
        assert_specific_host_storages
        assert_specific_host_networks
        assert_specific_host_switches
        assert_specific_vm
        assert_specific_template
      end

      context "with an archived VM" do
        let!(:archived_vm) { FactoryBot.create(:vm_proxmox, :ems_ref => "100") }

        it "doesn't reconnect an archived VM with the same ems_ref" do
          with_vcr { described_class.refresh([ems]) }

          expect(archived_vm.reload).to be_archived
          expect(ems.vms.find_by(:ems_ref => "100")).not_to eq(archived_vm)
        end
      end
    end

    context "targeted-refresh" do
      let(:targets) { [target] }
      before        { with_vcr { described_class.refresh([ems]) } }

      context "with a Host target" do
        let(:target) { ems.hosts.find_by(:ems_ref => "vmpvetest") }
        before       { with_vcr("targeted-refresh/host") { described_class.refresh(targets) } }

        it "doesn't impact unrelated inventory" do
          assert_counts
          assert_ems_counts
          assert_specific_cluster
          assert_specific_vm
          assert_specific_template
        end

        it "updates the host's power state" do
          expect(target.reload.power_state).to eq("on")
        end
      end

      context "with a VM target" do
        let(:target) { ems.vms.find_by(:ems_ref => "100") }
        before       { with_vcr("targeted-refresh/vm") { described_class.refresh(targets) } }

        it "doesn't impact unrelated inventory" do
          assert_counts
          assert_ems_counts
          assert_specific_cluster
          assert_specific_host
          assert_specific_template
        end

        it "updates the VMs's power state" do
          expect(target.reload.power_state).to eq("on")
        end
      end
    end
  end

  def assert_counts
    expect(Vm.count).to               eq(6)
    expect(MiqTemplate.count).to      eq(14)
    expect(Host.count).to             eq(2)
    expect(Storage.count).to          eq(5)
    expect(EmsCluster.count).to       eq(1)
    expect(HostStorage.count).to      be >= 2
  end

  def assert_ems_counts
    expect(ems.vms.count).to           eq(6)
    expect(ems.miq_templates.count).to eq(14)
    expect(ems.hosts.count).to         eq(2)
    expect(ems.storages.count).to      eq(5)
    expect(ems.ems_clusters.count).to  eq(1)
  end

  def assert_specific_cluster
    cluster = ems.ems_clusters.find_by(:ems_ref => "cluster")
    expect(cluster).to have_attributes(
      :name    => "pvetest",
      :uid_ems => "cluster",
      :ems_ref => "cluster"
    )
  end

  def assert_specific_host
    host = ems.hosts.find_by(:ems_ref => "vmpvetest")
    expect(host).to have_attributes(
      :name             => "vmpvetest",
      :hostname         => "vmpvetest",
      :vmm_vendor       => "proxmox",
      :vmm_version      => "9.1.5",
      :vmm_product      => "Proxmox VE",
      :vmm_buildnumber  => "80cf92a64bef6889",
      :power_state      => "on",
      :connection_state => "connected",
      :uid_ems          => "vmpvetest",
      :ems_ref          => "vmpvetest",
      :ems_cluster      => ems.ems_clusters.find_by(:ems_ref => "cluster")
    )
  end

  def assert_specific_host_hardware
    host = ems.hosts.find_by(:ems_ref => "vmpvetest")
    expect(host.hardware).to have_attributes(
      :cpu_total_cores      => 8,
      :cpu_cores_per_socket => 8,
      :cpu_sockets          => 1,
      :memory_mb            => 32_096
    )
    expect(host.hardware.cpu_type).to be_present
    expect(host.hardware.cpu_speed).to be_present
    expect(host.hardware.disk_capacity).to be_present
  end

  def assert_specific_host_storages
    host = ems.hosts.find_by(:ems_ref => "vmpvetest")
    expect(host.storages.count).to be >= 2
    expect(host.host_storages.count).to be >= 2

    # Test for a specific local storage
    local_storage = host.storages.find_by(:location => "local")
    expect(local_storage).to have_attributes(
      :store_type         => "dir",
      :multiplehostaccess => 0
    )
    expect(local_storage.name).to include("local")
    expect(local_storage.total_space).to be_present
    expect(local_storage.free_space).to be_present
  end

  def assert_specific_host_networks
    host = ems.hosts.find_by(:ems_ref => "vmpvetest")
    expect(host.hardware.guest_devices.where(:device_type => "ethernet").count).to be >= 1

    # Test that network adapters have proper attributes
    network_adapter = host.hardware.guest_devices.where(:device_type => "ethernet").first
    expect(network_adapter).to have_attributes(
      :controller_type => "ethernet",
      :device_type     => "ethernet"
    )
    expect(network_adapter.device_name).to be_present
    expect(network_adapter.uid_ems).to be_present
  end

  def assert_specific_host_switches
    host = ems.hosts.find_by(:ems_ref => "vmpvetest")
    expect(host.switches.count).to be >= 1

    # Test for virtual bridge
    switch = host.switches.first
    expect(switch.name).to be_present
    expect(switch.uid_ems).to be_present

    # Test that the switch has associated VLANs
    expect(switch.lans.count).to be >= 1

    # Test host-switch relationship
    host_switch = host.host_switches.first
    expect(host_switch.switch).to eq(switch)
  end

  def assert_specific_vm
    vm = ems.vms.find_by(:ems_ref => "100")
    expect(vm).to have_attributes(
      :vendor          => "proxmox",
      :name            => "vmpvevm1",
      :location        => "vmpvetest/100",
      :host            => ems.hosts.find_by(:ems_ref => "vmpvetest"),
      :ems_cluster     => ems.ems_clusters.find_by(:ems_ref => "cluster"),
      :uid_ems         => "100",
      :ems_ref         => "100",
      :power_state     => "on",
      :raw_power_state => "running",
      :tools_status    => "toolsOk"
    )

    assert_specific_vm_hardware(vm)
    assert_specific_vm_disks(vm)
    assert_specific_vm_networks(vm)
    assert_specific_vm_os(vm)
  end

  def assert_specific_vm_hardware(vm)
    expect(vm.hardware).to have_attributes(
      :cpu_total_cores => 4,
      :memory_mb       => 2048,
      :disk_capacity   => 10_737_418_240
    )
  end

  def assert_specific_vm_disks(vm)
    expect(vm.hardware.disks.count).to be >= 3

    scsi0 = vm.hardware.disks.find_by(:device_name => "scsi0")
    expect(scsi0).to have_attributes(
      :device_type     => "disk",
      :controller_type => "scsi",
      :size            => 10_737_418_240,
      :location        => "scsi0",
      :filename        => "local-lvm:vm-100-disk-1"
    )

    scsi1 = vm.hardware.disks.find_by(:device_name => "scsi1")
    expect(scsi1).to have_attributes(
      :device_type     => "disk",
      :controller_type => "scsi",
      :size            => 2_147_483_648,
      :location        => "scsi1"
    )

    scsi2 = vm.hardware.disks.find_by(:device_name => "scsi2")
    expect(scsi2).to have_attributes(
      :device_type     => "disk",
      :controller_type => "scsi",
      :size            => 3_221_225_472,
      :location        => "scsi2"
    )
  end

  def assert_specific_vm_networks(vm)
    expect(vm.hardware.networks.count).to be >= 1

    ens18 = vm.hardware.networks.find_by(:description => "ens18")
    expect(ens18).to have_attributes(
      :hostname  => "vmpvevm1",
      :ipaddress => "192.0.2.253"
    )

    guest_device = vm.hardware.guest_devices.find_by(:device_name => "ens18")
    expect(guest_device).to have_attributes(
      :device_type     => "ethernet",
      :controller_type => "ethernet",
      :address         => "bc:24:11:e2:9f:14"
    )
  end

  def assert_specific_vm_os(vm)
    expect(vm.operating_system).to have_attributes(
      :product_name => "Debian GNU/Linux 13 (trixie)"
    )
  end

  def assert_specific_template
    template = ems.miq_templates.find_by(:ems_ref => "900")
    expect(template).to have_attributes(
      :vendor          => "proxmox",
      :name            => "debian-13-2025-11-17T19-50-19Z-00000000",
      :location        => "vmpvetest/900",
      :host            => ems.hosts.find_by(:ems_ref => "vmpvetest"),
      :ems_cluster     => ems.ems_clusters.find_by(:ems_ref => "cluster"),
      :uid_ems         => "900",
      :ems_ref         => "900",
      :power_state     => "never",
      :raw_power_state => "never"
    )
  end
end
