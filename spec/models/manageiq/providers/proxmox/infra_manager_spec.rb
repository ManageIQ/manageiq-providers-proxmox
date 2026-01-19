# spec/models/manageiq/providers/proxmox/infra_manager_spec.rb
describe ManageIQ::Providers::Proxmox::InfraManager do
  describe ".ems_type" do
    it "returns 'proxmox'" do
      expect(described_class.ems_type).to eq("proxmox")
    end
  end

  describe ".description" do
    it "returns 'Proxmox'" do
      expect(described_class.description).to eq("Proxmox")
    end
  end

  describe ".default_port" do
    it "returns 8006" do
      expect(described_class.default_port).to eq(8006)
    end
  end

  describe ".hostname_required?" do
    it "returns true" do
      expect(described_class.hostname_required?).to be_truthy
    end
  end

  context "validation" do
    let(:ems) do
      described_class.new(
        :name     => "Test Proxmox",
        :hostname => "proxmox.example.com",
        :port     => 8006
      )
    end

    it "requires credentials" do
      expect { ems.verify_credentials }.to raise_error(MiqException::MiqHostError)
    end
  end
end
