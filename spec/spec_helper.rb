if ENV['CI']
  require 'simplecov'
  SimpleCov.start
end

Dir[Rails.root.join("spec/shared/**/*.rb")].sort.each { |f| require f }
Dir[File.join(__dir__, "support/**/*.rb")].sort.each { |f| require f }

require "manageiq/providers/proxmox"

VCR.configure do |config|
  config.cassette_library_dir = File.join(ManageIQ::Providers::Proxmox::Engine.root, 'spec/vcr_cassettes')

  VcrSecrets.define_all_cassette_placeholders(config, :proxmox)

  ip_mappings = {}

  config.before_record do |interaction|
    if interaction.request.headers['Cookie']
      interaction.request.headers['Cookie'] = ['PVEAuthCookie=PVE_AUTH_COOKIE']
    end
    interaction.response.body.gsub!(/"ticket":"[^"]+"/, '"ticket":"PVE_AUTH_TICKET"')
    interaction.response.body.gsub!(/"CSRFPreventionToken":"[^"]+"/, '"CSRFPreventionToken":"PVE_CSRF_TOKEN"')

    # Mask IP addresses and replace with RFC 5737 test ranges and use last octet
    interaction.response.body.gsub!(/\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/) do |ip|
      next ip if ip.start_with?('192.0.2.', '198.51.100.', '203.0.113.') # already masked

      unless ip_mappings[ip]

        last_octet = ip.split('.').last
        ip_mappings[ip] = "192.0.2.#{last_octet}"
      end
      ip_mappings[ip]
    end
  end
end
