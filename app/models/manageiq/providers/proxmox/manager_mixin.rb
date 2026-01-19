# app/models/manageiq/providers/proxmox/manager_mixin.rb
module ManageIQ::Providers::Proxmox::ManagerMixin
  extend ActiveSupport::Concern

  def connect(options = {})
    raise MiqException::MiqHostError, _("No credentials defined") if missing_credentials?(options[:auth_type])

    username = options[:user] || authentication_userid(options[:auth_type])
    password = options[:pass] || authentication_password(options[:auth_type])
    hostname = options[:hostname] || address
    port     = options[:port] || self.port || 8006

    self.class.raw_connect(hostname, port, username, password)
  end

  module ClassMethods
    def raw_connect(hostname, port, username, password, verify_ssl = false)
      require 'rest-client'
      require 'json'
      
      url = "https://#{hostname}:#{port}/api2/json"
      
      auth_response = RestClient::Request.execute(
        method:     :post,
        url:        "#{url}/access/ticket",
        payload:    {username: username, password: password},
        verify_ssl: verify_ssl
      )
      
      auth_data = JSON.parse(auth_response.body)
      
      ProxmoxConnection.new(
        url:        url,
        ticket:     auth_data['data']['ticket'],
        csrf_token: auth_data['data']['CSRFPreventionToken'],
        verify_ssl: verify_ssl
      )
    rescue RestClient::Unauthorized
      raise MiqException::MiqInvalidCredentialsError, _("Invalid username or password")
    rescue => err
      raise MiqException::MiqHostError, _("Unable to connect: %{error}") % {:error => err.message}
    end
  end

  class ProxmoxConnection
    attr_reader :url, :ticket, :csrf_token, :verify_ssl

    def initialize(url:, ticket:, csrf_token:, verify_ssl: false)
      @url = url
      @ticket = ticket
      @csrf_token = csrf_token
      @verify_ssl = verify_ssl
    end

    def get(path)
      execute_request(:get, path)
    end

    def post(path, payload = {})
      execute_request(:post, path, payload)
    end

    def put(path, payload = {})
      execute_request(:put, path, payload)
    end

    def delete(path)
      execute_request(:delete, path)
    end

    private

    def execute_request(method, path, payload = nil)
      options = {
        method:     method,
        url:        "#{url}#{path}",
        headers:    headers,
        verify_ssl: verify_ssl
      }
      
      options[:payload] = payload if payload && !payload.empty?

      response = RestClient::Request.execute(options)
      JSON.parse(response.body)
    rescue RestClient::Exception => err
      raise MiqException::MiqHostError, 
            _("Proxmox API error: %{error}") % {:error => err.message}
    end

    def headers
      {
        'Cookie'              => "PVEAuthCookie=#{ticket}",
        'CSRFPreventionToken' => csrf_token
      }
    end
  end
end
