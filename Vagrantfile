# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Gleipnir: sandboxed VMs for Claude Code, one per project. See README.md.
#
# Each file in machines/ defines one VM, named after the file:
#   machines/my-project.json  ->  vagrant up my-project
#
# Its other files are found by the same name, unless its config points elsewhere:
#   keys/my-project        the repo's deploy key (needed for SSH repo URLs), or "deploy_key"
#   env/my-project.env     the project's .env (optional), or "env_file"
#   env/my-project/        one .env per app, named after it, e.g. backend.env (optional,
#                          for projects with "apps"), or "env_dir"
#   claude/my-project.md   a starter CLAUDE.md for the project (optional; falls back to
#                          claude/default.md), or "claude_file"
#   context/my-project/    background files for Claude, copied to /srv/context in the
#                          machine (optional), or "context_dir"
#
# This file only creates the VMs and hands over to install.sh, which does the
# real work and is the same entry point used on a VPS.

require 'json'

root = File.expand_path(__dir__)

# A bare `vagrant destroy` would destroy every machine, and each one holds the only
# copy of its unpushed work and its database. Make it name the machines it destroys.
words = ARGV.reject { |arg| arg.start_with?('-') }
if words.first == 'destroy' && words.size == 1
  abort 'Gleipnir: name the machine to destroy, e.g. vagrant destroy my-project'
end

# Where each VM receives the scripts, config, key and .env: a folder only vagrant can read
upload = '/home/vagrant/.gleipnir'

# Taken inside the machine (SSH, the proxy, the database, the editor), so no app can use them
reserved_ports = [22, 3128, 3129, 3138, 3139, 5432, 8080]

# The base image's version, pinned with the other versions in scripts/versions.sh
box_version = File.read(File.join(root, 'scripts', 'versions.sh'))[/^BOX_VERSION=(\S+)$/, 1]
abort 'Gleipnir: scripts/versions.sh has no BOX_VERSION.' unless box_version

# --- Read every machine config ------------------------------------------------
machines = Dir.glob(File.join(root, 'machines', '*.json')).sort.map do |file|
  name = File.basename(file, '.json')
  where = "machines/#{name}.json"

  unless name.match?(/\A[a-z0-9][a-z0-9-]*\z/)
    abort "Gleipnir: #{where}: use only lowercase letters, digits and dashes in the file name."
  end

  begin
    settings = JSON.parse(File.read(file))
  rescue JSON::ParserError => e
    abort "Gleipnir: #{where} isn't valid JSON: #{e.message}"
  end

  abort "Gleipnir: #{where}: \"repo\" is required." if settings['repo'].to_s.strip.empty?

  # A machine's other files: the path its config gives (relative to this folder),
  # otherwise the default named after the machine. A path the config gives must exist.
  find = lambda do |setting, default|
    if settings[setting]
      path = File.expand_path(settings[setting], root)
      abort "Gleipnir: #{where}: #{setting} not found at #{path}." unless File.file?(path)
      path
    else
      path = File.join(root, default)
      File.file?(path) ? path : nil
    end
  end

  # The same for a folder
  find_dir = lambda do |setting, default|
    if settings[setting]
      path = File.expand_path(settings[setting], root)
      abort "Gleipnir: #{where}: #{setting} not found at #{path}." unless File.directory?(path)
      path
    else
      path = File.join(root, default)
      File.directory?(path) ? path : nil
    end
  end

  # The deploy key: keys/<name>. SSH repo URLs can't be cloned without one.
  key = find.call('deploy_key', "keys/#{name}")
  if key.nil? && settings['repo'].match?(%r{\A(ssh://|[^/@:]+@[^:]+:)})
    abort "Gleipnir: #{where}: no deploy key at keys/#{name}. Create one with:\n" \
          "  ssh-keygen -t ed25519 -f keys/#{name} -C \"#{name} VM\" -N \"\""
  end

  # The project's .env: env/<name>.env, and each app's: env/<name>/<app>.env
  env_file = find.call('env_file', "env/#{name}.env")
  env_dir = find_dir.call('env_dir', "env/#{name}")

  # A starter CLAUDE.md for the project: claude/<name>.md, else claude/default.md
  claude_file = find.call('claude_file', "claude/#{name}.md")
  claude_file ||= File.join(root, 'claude', 'default.md') if File.file?(File.join(root, 'claude', 'default.md'))

  # Background files for Claude: context/<name>/, a folder
  context_dir = find_dir.call('context_dir', "context/#{name}")

  # The apps' dev server ports. Without "apps", one app whose server listens on 5173
  # in the machine and on ports.app on your computer. With "apps", each app's port is
  # the same in both places. (The machine checks the rest of each app's settings.)
  ports = settings['ports'] || {}
  abort "Gleipnir: #{where}: \"ports\" must be an object, e.g. {\"editor\": 8080}." unless ports.is_a?(Hash)
  ports.each do |key, port|
    next if key.start_with?('_') # a comment
    unless port.is_a?(Integer) && port.between?(1, 65_535)
      abort "Gleipnir: #{where}: ports.#{key} must be a port number, like 8080 (not in quotes)."
    end
  end
  app_ports = {}
  if settings.key?('apps')
    apps = settings['apps']
    apps = apps.reject { |app, _| app.start_with?('_') } if apps.is_a?(Hash) # comments
    unless apps.is_a?(Hash) && !apps.empty?
      abort "Gleipnir: #{where}: \"apps\" must list at least one app, e.g. {\"frontend\": {\"port\": 5175}}."
    end
    apps.each do |app, app_settings|
      port = app_settings.is_a?(Hash) ? app_settings['port'] : nil
      unless port.is_a?(Integer) && port.between?(1024, 65_535) && !reserved_ports.include?(port)
        abort "Gleipnir: #{where}: apps.#{app}.port must be a number from 1024 to 65535, " \
              "and not #{reserved_ports.join(', ')}."
      end
      app_ports[app] = { guest: port, host: port }
    end
  else
    app_ports['app'] = { guest: 5173, host: ports.fetch('app', 5173) }
  end

  postgres = settings['postgres'] || {}
  {
    name: name,
    file: file,
    settings: settings,
    key: key,
    env_file: env_file,
    env_dir: env_dir,
    claude_file: claude_file,
    context_dir: context_dir,
    editor_port: ports.fetch('editor', 8080),
    app_ports: app_ports,
    db_port: postgres['enabled'] == true ? ports.fetch('db', 54320) : nil
  }
end

if machines.empty?
  abort 'Gleipnir: no machines yet. Copy machines/example.json.example to machines/<name>.json and fill it in.'
end

# --- Two VMs can't share a port on your computer, nor two uses in one VM ---------
owners = Hash.new { |hash, port| hash[port] = [] }
machines.each do |m|
  owners[m[:editor_port]] << "#{m[:name]} (editor)"
  m[:app_ports].each { |app, p| owners[p[:host]] << "#{m[:name]} (#{app == 'app' ? 'app' : "app #{app}"})" }
  owners[m[:db_port]] << "#{m[:name]} (database)" if m[:db_port]
end
clashes = owners.select { |_port, users| users.size > 1 }
unless clashes.empty?
  details = clashes.map { |port, users| "port #{port} is used by #{users.join(' and ')}" }.join('; ')
  abort "Gleipnir: #{details}. Give each its own port in the machine's config (\"ports\", or each app's \"port\")."
end

Vagrant.require_version '>= 2.4'

Vagrant.configure('2') do |config|
  config.vm.box = 'bento/ubuntu-24.04'
  config.vm.box_version = box_version

  # Nothing from your computer is shared into the VMs. Each project lives on its VM's own disk.
  config.vm.synced_folder '.', '/vagrant', disabled: true

  machines.each do |m|
    # autostart: false, so a bare `vagrant up` doesn't boot every machine at once
    config.vm.define m[:name], autostart: false do |machine|
      vm_settings = m[:settings]['vm'] || {}
      machine.vm.hostname = m[:name]

      # The editor, the apps and the database, reachable only from your computer's own localhost
      machine.vm.network 'forwarded_port', guest: 8080, host: m[:editor_port], host_ip: '127.0.0.1'
      m[:app_ports].each do |app, p|
        machine.vm.network 'forwarded_port', id: "app-#{app}", guest: p[:guest], host: p[:host], host_ip: '127.0.0.1'
      end
      if m[:db_port]
        machine.vm.network 'forwarded_port', guest: 5432, host: m[:db_port], host_ip: '127.0.0.1'
      end

      machine.vm.provider 'virtualbox' do |vb|
        vb.name = "gleipnir-#{m[:name]}"
        vb.memory = vm_settings.fetch('memory', 3072)
        vb.cpus = vm_settings.fetch('cpus', 2)
      end

      # Upload Gleipnir's scripts and this machine's config, key, .env files, starter CLAUDE.md and context
      machine.vm.provision 'shell', name: 'Gleipnir: preparing upload',
        inline: "rm -rf #{upload} && install -d -m 0700 -o vagrant -g vagrant #{upload}"
      machine.vm.provision 'file', source: File.join(root, 'install.sh'), destination: "#{upload}/install.sh"
      machine.vm.provision 'file', source: File.join(root, 'scripts'), destination: "#{upload}/scripts"
      machine.vm.provision 'file', source: File.join(root, 'claude-instructions.md'), destination: "#{upload}/claude-instructions.md"
      machine.vm.provision 'file', source: File.join(root, 'skills'), destination: "#{upload}/skills"
      machine.vm.provision 'file', source: m[:file], destination: "#{upload}/config.json"
      machine.vm.provision 'file', source: m[:key], destination: "#{upload}/deploy_key" if m[:key]
      machine.vm.provision 'file', source: m[:env_file], destination: "#{upload}/env" if m[:env_file]
      machine.vm.provision 'file', source: m[:env_dir], destination: "#{upload}/env-apps" if m[:env_dir]
      machine.vm.provision 'file', source: m[:claude_file], destination: "#{upload}/claude.md" if m[:claude_file]
      machine.vm.provision 'file', source: m[:context_dir], destination: "#{upload}/context" if m[:context_dir]

      # The same entry point as on a VPS. An empty argument means "none".
      install_args = [
        "#{upload}/config.json",
        m[:key] ? "#{upload}/deploy_key" : '',
        m[:env_file] ? "#{upload}/env" : '',
        m[:claude_file] ? "#{upload}/claude.md" : '',
        m[:context_dir] ? "#{upload}/context" : '',
        m[:env_dir] ? "#{upload}/env-apps" : ''
      ].map { |arg| "\"#{arg}\"" }.join(' ')
      machine.vm.provision 'shell', name: 'Gleipnir: install', inline: "bash #{upload}/install.sh #{install_args}"

      # Tidy up: the key and other files now live only where install.sh put them
      machine.vm.provision 'shell', name: 'Gleipnir: cleaning up', inline: "rm -rf #{upload}"

      # Copy just the .env files (and restart the dev servers), without a full provision.
      # These only run when asked for (the genv shortcut does this):
      #   vagrant provision my-project --provision-with env-upload,env-upload-apps,env
      if m[:env_file] || m[:env_dir]
        # A new name each run, so files left by an interrupted run can't get in the way
        staged = "/home/vagrant/.gleipnir-env-#{Time.now.to_i}"
        if m[:env_file]
          machine.vm.provision 'env-upload', type: 'file', run: 'never',
            source: m[:env_file], destination: "#{staged}/env"
        end
        if m[:env_dir]
          machine.vm.provision 'env-upload-apps', type: 'file', run: 'never',
            source: m[:env_dir], destination: "#{staged}/env-apps"
        end
        # An older genv shortcut doesn't upload env/<machine>/; say so rather than skip it quietly
        missing_apps_check = if m[:env_dir]
                               "[ -n \"$folder\" ] || echo 'Gleipnir: env/#{m[:name]}/ was not uploaded; " \
                                 "run ./install-shortcuts again to update genv' >&2"
                             else
                               ':'
                             end
        machine.vm.provision 'env', type: 'shell', run: 'never', inline: <<~SHELL
          set -e
          trap 'rm -rf #{staged}' EXIT
          file=""; folder=""
          [ -f #{staged}/env ] && file=#{staged}/env
          [ -d #{staged}/env-apps ] && folder=#{staged}/env-apps
          #{missing_apps_check}
          /usr/local/sbin/gleipnir-env "$file" "$folder"
          # Restart the dev servers that are running, so they pick up the change
          devserver try-restart 2>/dev/null || true
        SHELL
      end

      # Copy just the context folder, without a full provision. Only runs when asked for:
      #   vagrant provision my-project --provision-with context-upload,context
      if m[:context_dir]
        # A new name each run, so a folder left by an interrupted run can't get in the way
        staged = "/home/vagrant/.gleipnir-context-#{Time.now.to_i}"
        machine.vm.provision 'context-upload', type: 'file', run: 'never',
          source: m[:context_dir], destination: staged
        machine.vm.provision 'context', type: 'shell', run: 'never', inline: <<~SHELL
          set -e
          trap 'rm -rf #{staged}' EXIT
          /usr/local/sbin/gleipnir-context #{staged}
        SHELL
      end
    end
  end
end