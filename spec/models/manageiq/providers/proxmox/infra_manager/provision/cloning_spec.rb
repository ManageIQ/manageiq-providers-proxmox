describe ManageIQ::Providers::Proxmox::InfraManager::Provision::Cloning do
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

  let(:connection) { double("ProxmoxConnection") }

  before do
    allow(provision).to receive(:with_provider_connection).and_yield(connection)
  end

  # ── build_clone_params ──────────────────────────────────────────────────────

  describe "#build_clone_params" do
    let(:base_params) { provision.send(:build_clone_params, 101, :name => "new-vm", :full_clone => true) }

    it "always includes newid and name" do
      expect(base_params).to include(:newid => 101, :name => "new-vm")
    end

    it "sets full=1 for a full clone" do
      expect(base_params[:full]).to eq(1)
    end

    it "omits full for a linked clone" do
      params = provision.send(:build_clone_params, 101, :name => "new-vm", :full_clone => false)
      expect(params).not_to have_key(:full)
    end

    it "includes storage when provided" do
      params = provision.send(:build_clone_params, 101, :name => "new-vm", :full_clone => true, :storage => "local-lvm")
      expect(params[:storage]).to eq("local-lvm")
    end

    it "omits storage when blank" do
      expect(base_params).not_to have_key(:storage)
    end

    it "includes description when provided" do
      params = provision.send(:build_clone_params, 101, :name => "new-vm", :full_clone => true, :description => "my vm")
      expect(params[:description]).to eq("my vm")
    end

    it "includes target node when it differs from source node" do
      params = provision.send(:build_clone_params, 101, {:name => "new-vm", :full_clone => true}, "vmpvetest2", "vmpvetest")
      expect(params[:target]).to eq("vmpvetest2")
    end

    it "omits target node when source and destination are the same" do
      params = provision.send(:build_clone_params, 101, {:name => "new-vm", :full_clone => true}, "vmpvetest", "vmpvetest")
      expect(params).not_to have_key(:target)
    end
  end

  # ── prepare_for_clone_task ──────────────────────────────────────────────────

  describe "#prepare_for_clone_task" do
    it "returns a full clone by default" do
      clone_opts = provision.prepare_for_clone_task
      expect(clone_opts[:full_clone]).to be(true)
      expect(clone_opts[:name]).to eq("new-vm")
    end

    it "returns a linked clone when linked_clone option is set" do
      provision.options[:linked_clone] = true
      clone_opts = provision.prepare_for_clone_task
      expect(clone_opts[:full_clone]).to be(false)
    end

    it "includes storage when a datastore is chosen" do
      storage = FactoryBot.create(:storage, :location => "local-lvm")
      provision.options[:placement_ds_name] = storage.id
      clone_opts = provision.prepare_for_clone_task
      expect(clone_opts[:storage]).to eq("local-lvm")
    end

    it "includes disk_format when set" do
      provision.options[:disk_format] = "qcow2"
      clone_opts = provision.prepare_for_clone_task
      expect(clone_opts[:format]).to eq("qcow2")
    end
  end

  # ── parse_extra_config ──────────────────────────────────────────────────────

  describe "#parse_extra_config" do
    it "returns empty hash when option is blank" do
      provision.options[:extra_config] = nil
      expect(provision.send(:parse_extra_config)).to eq({})
    end

    it "parses a valid JSON object into a symbol-keyed hash" do
      provision.options[:extra_config] = '{"tags":"prod,web","onboot":1}'
      result = provision.send(:parse_extra_config)
      expect(result).to eq(:tags => "prod,web", :onboot => 1)
    end

    it "returns empty hash and warns on invalid JSON" do
      provision.options[:extra_config] = "not json {"
      expect($proxmox_log).to receive(:warn).with(/invalid JSON/)
      expect(provision.send(:parse_extra_config)).to eq({})
    end

    it "returns empty hash and warns when JSON is not an object" do
      provision.options[:extra_config] = '"just a string"'
      expect($proxmox_log).to receive(:warn).with(/not a JSON object/)
      expect(provision.send(:parse_extra_config)).to eq({})
    end
  end

  # ── apply_hardware_customization ────────────────────────────────────────────

  describe "#apply_hardware_customization" do
    it "returns nil when no hardware options are set" do
      expect(connection).not_to receive(:request)
      result = provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
      expect(result).to be_nil
    end

    it "returns the UPID when Proxmox responds with one" do
      provision.options[:vm_memory] = 4096
      allow(connection).to receive(:request).with(:put, anything).and_return("UPID:vmpvetest:001:config:OK")

      result = provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
      expect(result).to eq("UPID:vmpvetest:001:config:OK")
    end

    it "returns nil when Proxmox responds without a UPID (sync task)" do
      provision.options[:vm_memory] = 4096
      allow(connection).to receive(:request).with(:put, anything).and_return(nil)

      result = provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
      expect(result).to be_nil
    end

    it "sends sockets, cores and memory to the config endpoint" do
      provision.options.merge!(
        :number_of_sockets => 2,
        :cores_per_socket  => 4,
        :vm_memory         => 4096
      )

      expect(connection).to receive(:request).with(:put, satisfy do |url|
        url.include?("sockets=2") &&
          url.include?("cores=4") &&
          url.include?("memory=4096")
      end).and_return(nil)

      provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
    end

    it "preserves the NIC model when changing the bridge" do
      provision.options[:vlan] = "vmbr1"
      allow(connection).to receive(:request).with(:get, /config/).and_return("net0" => "virtio=BC:24:11:E2:9F:14,bridge=vmbr0")

      expect(connection).to receive(:request).with(:put, satisfy do |url|
        url =~ /net0=virtio.*vmbr1/
      end).and_return(nil)

      provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
    end

    context "with extra_config" do
      it "merges extra_config keys into the PUT request" do
        provision.options.merge!(
          :vm_memory    => 2048,
          :extra_config => '{"tags":"prod","onboot":1}'
        )

        expect(connection).to receive(:request).with(:put, satisfy do |url|
          url.include?("tags=prod") && url.include?("onboot=1") && url.include?("memory=2048")
        end).and_return(nil)

        provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
      end

      it "standard dialog fields override conflicting extra_config keys" do
        provision.options.merge!(
          :vm_memory    => 4096,
          :extra_config => '{"memory":1024}'
        )

        expect(connection).to receive(:request).with(:put, satisfy do |url|
          url.include?("memory=4096") && url.exclude?("memory=1024")
        end).and_return(nil)

        provision.send(:apply_hardware_customization, connection, "vmpvetest", 101)
      end
    end
  end

  # ── resize_boot_disk ────────────────────────────────────────────────────────

  describe "#resize_boot_disk" do
    before do
      allow(connection).to receive(:request).with(:get, /config/).and_return(
        "scsi0" => "local-lvm:vm-101-disk-1,size=10G"
      )
    end

    it "returns nil when no disk size requested" do
      expect(connection).not_to receive(:request).with(:put, anything)
      expect(provision.send(:resize_boot_disk, connection, "vmpvetest", 101)).to be_nil
    end

    it "returns the UPID when Proxmox responds with one" do
      provision.options[:allocated_disk_storage] = 20
      allow(connection).to receive(:request).with(:put, anything).and_return("UPID:vmpvetest:002:resize:OK")

      result = provision.send(:resize_boot_disk, connection, "vmpvetest", 101)
      expect(result).to eq("UPID:vmpvetest:002:resize:OK")
    end

    it "sends a resize when requested size is larger than current" do
      provision.options[:allocated_disk_storage] = 20

      expect(connection).to receive(:request).with(:put, satisfy do |url|
        url.include?("disk=scsi0") && url.include?("size=%2B10G")
      end).and_return(nil)

      provision.send(:resize_boot_disk, connection, "vmpvetest", 101)
    end

    it "skips resize when requested size equals current size" do
      provision.options[:allocated_disk_storage] = 10
      expect(connection).not_to receive(:request).with(:put, anything)
      provision.send(:resize_boot_disk, connection, "vmpvetest", 101)
    end

    it "skips and warns when requested size is smaller than current" do
      provision.options[:allocated_disk_storage] = 5
      expect($proxmox_log).to receive(:warn).with(/smaller/)
      expect(connection).not_to receive(:request).with(:put, anything)
      provision.send(:resize_boot_disk, connection, "vmpvetest", 101)
    end
  end

  # ── customize_task_complete? ────────────────────────────────────────────────

  describe "#customize_task_complete?" do
    it "returns true immediately when no task is pending" do
      expect(provision.customize_task_complete?).to be(true)
    end

    it "returns true and clears the upid when the task has stopped successfully" do
      provision.phase_context[:customize_task_upid] = "UPID:vmpvetest:001:config:OK"
      provision.phase_context[:clone_node_id] = "vmpvetest"

      allow(connection).to receive(:request).with(:get, /status/).and_return(
        "status" => "stopped", "exitstatus" => "OK"
      )

      expect(provision.customize_task_complete?).to be(true)
      expect(provision.phase_context[:customize_task_upid]).to be_nil
    end

    it "returns false while the task is still running" do
      provision.phase_context[:customize_task_upid] = "UPID:vmpvetest:001:config:OK"
      provision.phase_context[:clone_node_id] = "vmpvetest"

      allow(connection).to receive(:request).with(:get, /status/).and_return(
        "status" => "running", "exitstatus" => nil
      )

      expect(provision.customize_task_complete?).to be(false)
    end

    it "raises on task failure" do
      provision.phase_context[:customize_task_upid] = "UPID:vmpvetest:001:config:OK"
      provision.phase_context[:clone_node_id] = "vmpvetest"

      allow(connection).to receive(:request).with(:get, /status/).and_return(
        "status" => "stopped", "exitstatus" => "ERROR"
      )

      expect { provision.customize_task_complete? }.to raise_error(MiqException::MiqProvisionError)
    end
  end

  # ── destination_node_id ─────────────────────────────────────────────────────

  describe "#destination_node_id" do
    it "returns nil when no host is selected" do
      expect(provision.send(:destination_node_id)).to be_nil
    end

    it "returns the host ems_ref when a host is selected" do
      host = FactoryBot.create(:host, :ext_management_system => ems, :ems_ref => "vmpvetest2")
      provision.options[:placement_host_name] = host.id
      expect(provision.send(:destination_node_id)).to eq("vmpvetest2")
    end
  end

  # ── start_clone ─────────────────────────────────────────────────────────────

  describe "#start_clone" do
    before do
      allow(connection).to receive(:request).with(:get, "/cluster/nextid").and_return("101")
      allow(connection).to receive(:request).with(:post, anything).and_return("UPID:vmpvetest:000A:clone:OK")
    end

    it "posts a clone request and stores the new vmid in phase_context" do
      expect(connection).to receive(:request).with(:post, satisfy do |url|
        url.include?("/qemu/900/clone") && url.include?("newid=101") && url.include?("name=new-vm")
      end).and_return("UPID:vmpvetest:000A:clone:OK")

      provision.start_clone(provision.prepare_for_clone_task)

      expect(provision.phase_context[:new_vmid]).to eq("101")
    end
  end
end
