require 'yaml'
require 'json'
require 'terminal-table'
require 'lxdev/system'
require 'tempfile'

module LxDev
  class Main
    WHITELISTED_SUDO_COMMANDS = ["lxc", "redir", "kill"]
    SHELLS                    = ["bash", "zsh", "sh", "csh", "tcsh", "ash"]
    BOOT_TIMEOUT              = 30
    VERSION                   = '0.1.6'

    def initialize(config_file, state_file)
      @state_file = format(".lxdev/%s", state_file)
      @uid    = System.exec("id -u").output.chomp
      @gid    = System.exec("id -g").output.chomp
      @config = YAML.load_file(config_file)
      @name   = @config['box']['name']
      @image  = @config['box']['image']
      @user   = @config['box']['user']
      @ports  = @config['box']['ports'] || {}
      Dir.mkdir('.lxdev') unless File.directory?('.lxdev')
      begin
        @state = YAML.load_file(@state_file)
      rescue
        @state = Hash.new
      end
    rescue Errno::ENOENT
      puts "#{config_file} not found"
      exit 1
    end

    def self.setup(config_file = 'lxdev.yml', state_file = 'state')
      self.check_requirements
      unless lxd_initialized?
        puts "Please run 'lxd init' and configure LXD first"
        return false
      end
      lxdev = Main.new(config_file, state_file)
      unless lxdev.set_ssh_keys
        puts "No ssh keys detected. Make sure you have an ssh key, a running agent, and the key added to the agent, e.g. with ssh-add."
        return false
      end
      return lxdev
    end

    def save_state
      File.open(@state_file, 'w') {|f| f.write @state.to_yaml} unless @state.empty?
    end

    def set_ssh_keys
      ssh_keys = System.exec("ssh-add -L").output
      if ssh_keys[0..3] == 'ssh-'
        @ssh_keys = ssh_keys
      else
        nil
      end
    end

    def status
      ensure_container_created

      container_status = get_container_status
      folders          = container_status.first['devices'].map {|name, folders| [name, "#{folders['source']} => #{folders['path']}"] if folders['source']}.compact
      table            = Terminal::Table.new do |t|
        t.add_row ['Name', container_status.first['name']]
        t.add_row ['Status', container_status.first['status']]
        t.add_row ['IP', get_container_ip]
        t.add_row ['Image', @image]
        t.add_separator
        folders.each do |folder|
          t.add_row folder
        end
        t.add_separator
        @ports.each do |guest, host|
          t.add_row ['Forwarded port', "guest: #{guest} host: #{host}"]
        end
        if container_status.first['snapshots'].any?
          t.add_separator
          t.add_row ['Snapshots', '']
        end
        container_status.first['snapshots'].each do |snapshot|
          t.add_row [snapshot['name'].partition('/').last, snapshot['created_at']]
        end
      end
      puts table
    end

    def up
      do_provision = false
      unless @state.empty?
        puts "Container state #{@state_file} exists, is it running? If not it might have stopped unexpectedly. Please remove the file before starting."
        exit 1
      end
      if get_container_status.empty?
        create_container
        do_provision = true
      else
        if get_container_status.first['status'] == 'Running'
          puts "#{@name} is already running!"
          exit 1
        else
          start_container
        end
      end
      puts "Waiting for boot..."
      wait_for_boot
      @state['status'] = 'running'
      puts "Forwarding ports..."
      forward_ports(@ports)
      provision if do_provision
    end

    def halt
      ensure_container_created
      System.exec("sudo lxc stop #{@name}")
      cleanup_forwarded_ports
      remove_state
    end

    def destroy
      ensure_container_created
      System.exec("sudo lxc delete #{@name}")
    end

    def ssh(args)
      ensure_container_created
      host = get_container_ip
      if host.nil?
        puts "#{@name} doesn't seem to be running."
        exit 1
      end
      ssh_command = "ssh -o StrictHostKeyChecking=no -t #{@user}@#{get_container_ip} #{args.empty? ? '' : "'#{args.join(' ')}'"}"
      exec ssh_command
    end

    def execute(command, interactive: false)
      if interactive
        exec("sudo lxc exec #{@name} #{command}") # execution stops here and gives control to exec
      end
      IO.popen("sudo lxc exec #{@name} -- /bin/sh -c '#{command}'", err: [:child, :out]) do |cmd_output|
        cmd_output.each do |line|
          puts line
        end
      end
    end

    def provision
      ensure_container_created
      if get_container_status.first['status'] != 'Running'
        puts "#{@name} is not running!"
        exit 1
      end
      provisioning = @config['box']['provisioning']
      if provisioning.nil?
        puts "Nothing to do"
        return
      end
      if @config['box']['auto_snapshots']
        snapshot_name = "provision_#{Time.now.to_i}"
        snapshot(snapshot_name)
      end
      puts "Provisioning #{@name}..."
      STDOUT.sync = true
      provisioning.each do |cmd|
        execute cmd
      end
      STDOUT.sync = false
    end

    def snapshot(snapshot_name)
      puts "Creating snapshot #{snapshot_name}"
      System.exec("sudo lxc snapshot #{@name} #{snapshot_name}")
    end

    def restore(snapshot_name)
      puts "Restoring snapshot #{snapshot_name}"
      exitstatus = System.exec("sudo lxc restore #{@name} #{snapshot_name}").exitstatus
      exitstatus == 0
    end

    def rmsnapshot(snapshot_name)
      puts "Deleting snapshot #{snapshot_name}"
      exitstatus = System.exec("sudo lxc delete #{@name}/#{snapshot_name}").exitstatus
      exitstatus == 0
    end

    def revert
      snapshot      = get_container_status.first['snapshots'].last
      snapshot_name = snapshot['name'].partition('/').last
      if restore(snapshot_name)
        puts "Reverted to snapshot #{snapshot_name}"
        puts "Deleting snapshot"
        rmsnapshot(snapshot_name)
      end
    end

    private

    def self.lxd_initialized?
      exitstatus = System.exec("sudo lxc info | grep 'lxd init'").exitstatus
      exitstatus != 0
    end

    def ensure_container_created
      container_status = get_container_status
      unless container_status.size > 0
        puts "Container not created yet. Run lxdev up"
        exit(0)
      end
    end

    def remove_state
      File.delete(@state_file) if File.exists?(@state_file)
      @state = {}
    end

    def create_container
      add_subuid_and_subgid
      puts "Launching #{@name}..."
      System.exec("sudo lxc init #{@image} #{@name}")
      System.exec(%{printf "uid #{@uid} 1001\ngid #{@gid} 1001"| sudo lxc config set #{@name} raw.idmap -})
      System.exec("sudo lxc start #{@name}")
      puts "Creating user #{@user}..."
      create_container_user(@user)
      puts "Mapping folders.."
      map_folders(@config['box']['folders'])
    end

    def start_container
      puts "Starting #{@name}..."
      System.exec("sudo lxc start #{@name}")
    end

    def get_container_status
      return @status unless @status.nil?
      command_result = System.exec("sudo lxc list ^#{@name}$ --format=json")
      @status = JSON.parse(command_result.output)
    end

    def get_container_ip
      get_container_status.first['state']['network']['eth0']['addresses'].select {|addr| addr['family'] == 'inet'}.first['address']
    rescue
      nil
    end

    def add_subuid_and_subgid
      need_restart = false
      if System.exec("grep -q 'root:#{@uid}:1' /etc/subuid").exitstatus != 0
        System.exec("echo 'root:#{@uid}:1' | sudo tee -a /etc/subuid")
        need_restart = true
      end
      if System.exec("grep -q 'root:#{@gid}:1' /etc/subgid").exitstatus != 0
        System.exec("echo 'root:#{@gid}:1' | sudo tee -a /etc/subgid")
        need_restart = true
      end
      if need_restart
        begin
          System.exec("sudo systemctl restart #{lxd_service_name}")
        rescue
          puts "The LXD service needs to be restarted, but the service name cannot be detected. Please restart it manually."
        end
      end
    end

    def create_container_user(user)
      System.exec("sudo lxc exec #{@name} -- groupadd --gid 1001 #{user}")
      System.exec("sudo lxc exec #{@name} -- useradd --uid 1001 --gid 1001 -s /bin/bash -m #{user}")
      System.exec("sudo lxc exec #{@name} -- mkdir /home/#{user}/.ssh")
      System.exec("sudo lxc exec #{@name} -- chmod 0700 /home/#{user}/.ssh")
      System.exec("printf '#{@ssh_keys}' | sudo lxc exec #{@name} tee /home/#{user}/.ssh/authorized_keys")
      System.exec("sudo lxc exec #{@name} -- chown -R #{user} /home/#{user}/.ssh")
      System.exec("sudo lxc exec #{@name} -- touch /home/#{@user}/.hushlogin")
      System.exec("sudo lxc exec #{@name} -- chown #{user} /home/#{user}/.hushlogin")
      System.exec(%{printf "#{user} ALL=(ALL) NOPASSWD: ALL\n" | sudo lxc exec #{@name} -- tee -a /etc/sudoers})
      System.exec("sudo lxc exec #{@name} -- chmod 0440 /etc/sudoers")
    end

    def wait_for_boot
      BOOT_TIMEOUT.times do |t|
        @status = nil # reset status for each iteration to refresh IP
        break if get_container_ip
        abort_boot if t == (BOOT_TIMEOUT - 1)
        sleep 1
      end
    end

    def forward_ports(ports)
      redir_pids = []
      ports.each do |guest, host|
        puts "Forwarding #{get_container_ip}:#{guest} to local port #{host}"
        pid = System.spawn_exec("sudo redir --caddr=#{get_container_ip} --cport=#{guest} --lport=#{host}")
        redir_pids << pid
        Process.detach(pid)
      end
      @state['redir_pids'] = redir_pids
    end

    def cleanup_forwarded_ports
      if @state.empty?
        return
      end
      @state['redir_pids'].each do |pid|
        System.exec("sudo kill #{pid}")
      end
    end

    def map_folders(folders)
      counter = 0
      folders.each do |host, guest|
        counter = counter + 1
        puts "Mounting #{host} in #{guest}"
        absolute_path = System.exec("readlink -f #{host}").output.chomp
        System.exec("sudo lxc config device add #{@name} shared_folder_#{counter} disk source=#{absolute_path} path=#{guest}")
      end
    end

    def get_snapshots
      snapshots = []
      get_container_status.first['snapshots'].each do |snapshot|
        result         = {}
        result['name'] = snapshot['name']
        result['date'] = snapshot['created_at']
        snapshots << result
      end
      snapshots
    end

    def abort_boot
      puts "Timeout waiting for container to boot"
      exit 1
    end

    def lxd_service_name
      if System.exec("sudo systemctl status lxd.service").exitstatus == 0
        'lxd.service'
      elsif System.exec("sudo systemctl status snap.lxd.daemon.service").exitstatus == 0
        'snap.lxd.daemon.service'
      else
        raise 'There seems to be no LXD service on the system!'
      end
    end

    def self.check_requirements
      WHITELISTED_SUDO_COMMANDS.each do |cmd|
        unless System.exec("which #{cmd}").exitstatus == 0
          puts "The command '#{cmd}' is not installed or not available."
          puts "Please install it before continuing."
          exit 1
        end
      end
    end

    def self.create_sudoers_file
      self.check_requirements
      user = System.exec("whoami").output.chomp
      content = []
      content << "# Created by lxdev #{Time.now}"
      WHITELISTED_SUDO_COMMANDS.each do |cmd|
        cmd_with_path = System.exec("which #{cmd}").output.chomp
        content << "#{user} ALL=(root) NOPASSWD: #{cmd_with_path}"
      end
      content << "\n"
      puts <<-EOS
!! WARNING !!
This will create a file, /etc/sudoers.d/lxdev,
which will give your user #{user} access to running
the following commands :
 #{WHITELISTED_SUDO_COMMANDS.join(" ")}
with superuser privileges. If you do not know what you're
doing, this can be dangerous and insecure.

      EOS
      puts "The following content will be created in /etc/sudoers.d/lxdev :"
      puts
      puts content
      puts "\nIf you want to do this, type 'yesplease'"
      action = STDIN.gets.chomp
      unless action == 'yesplease'
        puts "Not creating sudoers file"
        return
      end
      temp_file = Tempfile.create('lxdev-sudoers')
      temp_file.write(content.join("\n"))
      temp_file_name = temp_file.to_path
      temp_file.close
      unless System.exec("visudo -c -f #{temp_file_name}").exitstatus == 0
        puts "Generated sudoers file contains errors, aborting."
        exit 1
      end
      System.exec("sudo chown root:root #{temp_file_name}")
      System.exec("sudo chmod 0440 #{temp_file_name}")
      System.exec("sudo mv #{temp_file_name} /etc/sudoers.d/lxdev")
      puts "Created sudoers file."
    end
  end
end
