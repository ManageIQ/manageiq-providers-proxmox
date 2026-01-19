# coding: utf-8
lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'manageiq/providers/proxmox/version'

Gem::Specification.new do |spec|
  spec.name          = "manageiq-providers-proxmox"
  spec.version       = ManageIQ::Providers::Proxmox::VERSION
  spec.authors       = ["ManageIQ Authors"]

  spec.summary       = "ManageIQ plugin for the Proxmox provider."
  spec.description   = "ManageIQ plugin for the Proxmox provider."
  spec.homepage      = "https://github.com/ManageIQ/manageiq-providers-proxmox"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "rest-client", "~> 2.1"
  
  # Development dependencies
  spec.add_development_dependency "manageiq-style"
  spec.add_development_dependency "simplecov",  ">= 0.21.2"
end
