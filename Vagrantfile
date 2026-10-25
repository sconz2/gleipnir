# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Gleipnir: a sandboxed VM for Claude Code. See README.md.
# This file only creates the VM and hands over to install.sh, which does the
# real work and is the same entry point used on a VPS.

require 'json'

root = File.expand_path(__dir__)
config_file = File.join(root, 'config.json')

unless File.exist?(config_file)
  abort 'Gleipnir: config.json not found. Copy config.json.example to config.json and fill it in.'
end

settings = JSON.parse(File.read(config_file))
%w[name repo].each do |key|
  abort "Gleipnir: \"#{key}\" is required in config.json." if settings[key].to_s.strip.empty?
end

vm_settings = settings['vm'] || {}
ports = settings['ports'] || {}
hostname = settings['name'].downcase.gsub(/[^a-z0-9-]/, '-')

deploy_key = nil
if settings['deploy_key']
  deploy_key = File.expand_path(settings['deploy_key'])
  abort "Gleipnir: deploy key not found at #{deploy_key}." unless File.exist?(deploy_key)
end

# Where the scripts, config and key are uploaded: a folder only vagrant can read
upload = '/home/vagrant/.gleipnir'

Vagrant.require_version '>= 2.4'

Vagrant.configure('2') do |config|
  config.vm.box = 'bento/ubuntu-24.04'
  config.vm.hostname = hostname

  # Nothing from your Mac is shared into the VM. The project lives on the VM's own disk.
  config.vm.synced_folder '.', '/vagrant', disabled: true

  # The editor and the app, reachable only from your Mac's own localhost
  config.vm.network 'forwarded_port', guest: 8080, host: ports.fetch('editor', 8080), host_ip: '127.0.0.1'
  config.vm.network 'forwarded_port', guest: 5173, host: ports.fetch('app', 5173), host_ip: '127.0.0.1'

  config.vm.provider 'virtualbox' do |vb|
    vb.name = settings['name']
    vb.memory = vm_settings.fetch('memory', 3072)
    vb.cpus = vm_settings.fetch('cpus', 2)
  end

  # Upload Gleipnir's scripts, the config and the deploy key
  config.vm.provision 'shell', name: 'Gleipnir: preparing upload',
    inline: "rm -rf #{upload} && install -d -m 0700 -o vagrant -g vagrant #{upload}"
  config.vm.provision 'file', source: File.join(root, 'install.sh'), destination: "#{upload}/install.sh"
  config.vm.provision 'file', source: File.join(root, 'scripts'), destination: "#{upload}/scripts"
  config.vm.provision 'file', source: config_file, destination: "#{upload}/config.json"
  config.vm.provision 'file', source: deploy_key, destination: "#{upload}/deploy_key" if deploy_key

  # The same entry point as on a VPS
  install_args = "#{upload}/config.json"
  install_args += " #{upload}/deploy_key" if deploy_key
  config.vm.provision 'shell', name: 'Gleipnir: install', inline: "bash #{upload}/install.sh #{install_args}"

  # Tidy up: the key now lives only in dev's home inside the VM
  config.vm.provision 'shell', name: 'Gleipnir: cleaning up', inline: "rm -rf #{upload}"
end
