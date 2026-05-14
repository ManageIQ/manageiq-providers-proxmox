describe ManageIQ::Providers::Proxmox::InfraManager::Vm::Reconfigure do
  let(:zone) { EvmSpecHelper.local_miq_server.zone }
  let(:ems)  { FactoryBot.create(:ems_proxmox, :zone => zone) }
  let(:host) do
    FactoryBot.create(:host_proxmox, :ext_management_system => ems).tap do |h|
      h.hardware = FactoryBot.create(:hardware, :cpu_sockets => 2, :cpu_total_cores => 8)
    end
  end
  let(:storage) { FactoryBot.create(:storage, :name => "local-lvm", :store_type => "LVM", :location => "local-lvm") }
  let(:vm) do
    FactoryBot.create(
      :vm_proxmox,
      :name                  => "test-vm",
      :ems_ref               => "101",
      :ext_management_system => ems,
      :host                  => host,
      :raw_power_state       => "stopped",
      :hardware              => FactoryBot.create(:hardware, :cpu_sockets => 1, :cpu_cores_per_socket => 2, :memory_mb => 2048)
    ).tap { |v| v.storages << storage }
  end

  describe "#reconfigurable?" do
    let(:vm_active)   { FactoryBot.create(:vm_proxmox, :ext_management_system => ems) }
    let(:vm_template) { FactoryBot.create(:vm_proxmox, :ext_management_system => ems, :template => true) }
    let(:vm_orphaned) { FactoryBot.create(:vm_proxmox) }

    it "returns true for active vm" do
      expect(vm_active.reconfigurable?).to be_truthy
    end

    it "returns false for template" do
      expect(vm_template.reconfigurable?).to be_falsey
    end

    it "returns false for orphaned vm" do
      expect(vm_orphaned.reconfigurable?).to be_falsey
    end
  end

  describe "#max_vcpus" do
    it "returns host cpu_sockets when host exists" do
      expect(vm.max_vcpus).to eq(2)
    end

    it "returns 1 when no host" do
      vm.update(:host => nil)
      expect(vm.max_vcpus).to eq(1)
    end
  end

  describe "#max_total_vcpus" do
    it "returns 128" do
      expect(vm.max_total_vcpus).to eq(128)
    end
  end

  describe "#max_cpu_cores_per_socket" do
    it "returns 128" do
      expect(vm.max_cpu_cores_per_socket).to eq(128)
    end
  end

  describe "#max_memory_mb" do
    it "returns 4TB in MB" do
      expect(vm.max_memory_mb).to eq(4.terabytes / 1.megabyte)
    end
  end

  describe "#scsi_controller_types" do
    it "returns supported controller types" do
      expect(vm.scsi_controller_types).to eq(%w[scsi virtio sata ide])
    end
  end

  describe "#scsi_controller_default_type" do
    it "returns scsi" do
      expect(vm.scsi_controller_default_type).to eq('scsi')
    end
  end

  describe "#build_config_spec" do
    it "builds spec with memory" do
      spec = vm.build_config_spec(:vm_memory => 4096)
      expect(spec[:memory]).to eq(4096)
    end

    it "builds spec with cpu" do
      spec = vm.build_config_spec(:number_of_cpus => 4, :cores_per_socket => 2)
      expect(spec[:cores]).to eq(2)
      expect(spec[:sockets]).to eq(2)
    end

    it "builds spec with disk operations" do
      spec = vm.build_config_spec(:disk_add => [{:disk_size_in_mb => 10_240}])
      expect(spec[:_disk_ops]).to eq({:add => [{:disk_size_in_mb => 10_240}]})
    end

    it "builds spec with network operations" do
      spec = vm.build_config_spec(:network_adapter_add => [{:network => 'vmbr0'}])
      expect(spec[:_network_ops]).to eq({:add => [{:network => 'vmbr0'}]})
    end

    context "running VM" do
      before { vm.update(:raw_power_state => "running") }

      it "raises error when adding CPUs without hotplug" do
        expect { vm.build_config_spec(:number_of_cpus => 8) }
          .to raise_error(MiqException::MiqVmError, /CPU hotplug not enabled/)
      end

      it "raises error when adding memory without hotplug" do
        expect { vm.build_config_spec(:vm_memory => 4096) }
          .to raise_error(MiqException::MiqVmError, /Memory hotplug requires/)
      end

      context "with CPU hotplug enabled" do
        before { vm.update(:cpu_hot_add_enabled => true) }

        it "raises error when reducing CPUs" do
          allow(vm).to receive(:cpu_total_cores).and_return(4)
          expect { vm.build_config_spec(:number_of_cpus => 2) }
            .to raise_error(MiqException::MiqVmError, /Cannot reduce CPUs/)
        end

        it "allows adding CPUs" do
          spec = vm.build_config_spec(:number_of_cpus => 4)
          expect(spec[:sockets]).to eq(2)
        end
      end

      context "with memory hotplug enabled" do
        before { vm.update(:memory_hot_add_enabled => true) }

        it "raises error when reducing memory" do
          expect { vm.build_config_spec(:vm_memory => 1024) }
            .to raise_error(MiqException::MiqVmError, /Cannot reduce memory/)
        end

        it "allows adding memory" do
          spec = vm.build_config_spec(:vm_memory => 4096)
          expect(spec[:memory]).to eq(4096)
        end
      end
    end
  end

  describe "#build_disk_value" do
    it "builds disk string with defaults" do
      result = vm.send(:build_disk_value, "local-lvm", 10, {})
      expect(result).to eq("local-lvm:10,ssd=1,discard=on,iothread=1")
    end

    it "builds disk string with custom options" do
      result = vm.send(:build_disk_value, "local-lvm", 10, {
                         'ssd_emulation' => false,
                         'discard'       => false,
                         'iothread'      => false,
                         'cache'         => 'writeback'
                       })
      expect(result).to eq("local-lvm:10,cache=writeback")
    end

    it "includes backup and replicate options" do
      result = vm.send(:build_disk_value, "local-lvm", 10, {
                         'backup'    => false,
                         'replicate' => false
                       })
      expect(result).to include("backup=0")
      expect(result).to include("replicate=0")
    end
  end

  describe "#find_disk_slot" do
    let!(:disk) do
      FactoryBot.create(:disk, :hardware => vm.hardware, :location => "scsi0", :filename => "local-lvm:vm-101-disk-0")
    end

    it "returns slot directly if already a slot pattern" do
      expect(vm.send(:find_disk_slot, {'disk_name' => 'scsi0'})).to eq('scsi0')
      expect(vm.send(:find_disk_slot, {'disk_name' => 'virtio1'})).to eq('virtio1')
      expect(vm.send(:find_disk_slot, {'disk_name' => 'ide2'})).to eq('ide2')
    end

    it "finds slot by filename" do
      expect(vm.send(:find_disk_slot, {'disk_name' => 'local-lvm:vm-101-disk-0'})).to eq('scsi0')
    end

    it "finds slot by database id" do
      expect(vm.send(:find_disk_slot, {'id' => "disk#{disk.id}"})).to eq('scsi0')
    end

    it "returns nil for unknown disk" do
      expect(vm.send(:find_disk_slot, {'disk_name' => 'nonexistent'})).to be_nil
    end
  end

  describe "#find_nic_slot" do
    let!(:nic) do
      FactoryBot.create(:guest_device, :hardware => vm.hardware, :device_type => "ethernet", :location => "net0", :address => "bc:24:11:00:00:01")
    end

    it "returns nic_id directly if valid pattern" do
      expect(vm.send(:find_nic_slot, {'nic_id' => 'net0'}, {})).to eq('net0')
      expect(vm.send(:find_nic_slot, {'nic_id' => 'net5'}, {})).to eq('net5')
    end

    it "extracts slot from name" do
      expect(vm.send(:find_nic_slot, {'name' => 'net1 (vmbr0)'}, {})).to eq('net1')
    end

    it "extracts slot from nested network name" do
      spec = {'id' => 'network1', 'network' => {'name' => 'net2 (vmbr1)'}}
      expect(vm.send(:find_nic_slot, spec, {})).to eq('net2')
    end

    it "finds slot by database id" do
      expect(vm.send(:find_nic_slot, {'id' => "network#{nic.id}"}, {})).to eq('net0')
    end

    it "returns nil for unknown nic" do
      expect(vm.send(:find_nic_slot, {'id' => 'network99999'}, {})).to be_nil
    end
  end

  describe "#parse_nic_config" do
    it "parses config with MAC" do
      result = vm.send(:parse_nic_config, "virtio=BC:24:11:AA:BB:CC,bridge=vmbr0")
      expect(result).to eq({:model => "virtio", :bridge => "vmbr0", :mac => "BC:24:11:AA:BB:CC"})
    end

    it "parses config without MAC" do
      result = vm.send(:parse_nic_config, "e1000,bridge=vmbr1")
      expect(result).to eq({:model => "e1000", :bridge => "vmbr1", :mac => nil})
    end

    it "handles nil input" do
      result = vm.send(:parse_nic_config, nil)
      expect(result).to eq({:model => "virtio", :bridge => "vmbr0", :mac => nil})
    end
  end

  describe "#encode_nic" do
    it "encodes nic with MAC" do
      result = vm.send(:encode_nic, {:model => 'virtio', :bridge => 'vmbr0', :mac => 'BC:24:11:AA:BB:CC'})
      expect(URI.decode_www_form_component(result)).to eq("virtio=BC:24:11:AA:BB:CC,bridge=vmbr0")
    end

    it "encodes nic without MAC" do
      result = vm.send(:encode_nic, {'network_adapter_type' => 'e1000', 'network' => 'vmbr1'})
      expect(URI.decode_www_form_component(result)).to eq("e1000,bridge=vmbr1")
    end

    it "uses defaults when not specified" do
      result = vm.send(:encode_nic, {})
      expect(URI.decode_www_form_component(result)).to eq("virtio,bridge=vmbr0")
    end
  end

  describe "#next_slot" do
    it "returns first slot when none exist" do
      config = {}
      expect(vm.send(:next_slot, config, 'scsi')).to eq('scsi0')
      expect(vm.send(:next_slot, config, 'net')).to eq('net0')
    end

    it "returns next available slot" do
      config = {'scsi0' => 'disk1', 'scsi1' => 'disk2', 'net0' => 'nic1'}
      expect(vm.send(:next_slot, config, 'scsi')).to eq('scsi2')
      expect(vm.send(:next_slot, config, 'net')).to eq('net1')
    end

    it "handles gaps in slot numbers" do
      config = {'scsi0' => 'disk1', 'scsi5' => 'disk2'}
      expect(vm.send(:next_slot, config, 'scsi')).to eq('scsi6')
    end
  end

  describe "#compact_ops" do
    it "extracts and renames operation keys" do
      options = {:disk_add => [{:size => 10}], :disk_remove => [{:id => 1}]}
      result = vm.send(:compact_ops, options, :disk_add, :disk_resize, :disk_remove)
      expect(result).to eq({:add => [{:size => 10}], :remove => [{:id => 1}]})
    end

    it "returns nil when no operations" do
      result = vm.send(:compact_ops, {}, :disk_add, :disk_resize, :disk_remove)
      expect(result).to be_nil
    end
  end
end
