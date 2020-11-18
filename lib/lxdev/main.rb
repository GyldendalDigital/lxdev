require 'yaml'
require 'json'
require 'terminal-table'
require 'lxdev/system'
require 'lxdev/container'
require 'lxdev/redir'
require 'lxdev/shared_folder'
require 'lxdev/version'
require 'tempfile'
require 'etc'

module LxDev
  class SystemNotReady < StandardError; end

  class Main
    REQUIRED_COMMANDS = ["lxc", "redir", "kill"]
    SHELLS            = ["bash", "zsh", "sh", "csh", "tcsh", "ash"]
    BOOT_TIMEOUT      = 30

    def initialize(config_file)
      @config = YAML.load_file(config_file)
      @container = Container.new(*@config['box'].fetch_values('name', 'image', 'user'))
      @redirs = @config.dig('box', 'ports')&.map{|a| Redir.new(*a, @container)} || []
      @folders = @config.dig('box', 'folders')&.map{|a| SharedFolder.new(*a, @container)} || []
    end

    def self.check_system
      case
      when !(mrc = self.missing_required_commands).empty?
        raise(SystemNotReady.new(format("The following commands are missing: %s", mrc.join(","))))
      when !self.lxd_initialized?
        raise(SystemNotReady.new("Please run 'lxd init' and configure LXD first"))
      when !System.ssh_keys
        raise(SystemNotReady.new(<<~EOS))
          No ssh keys detected.

          Make sure you have an ssh key, a running ssh-agent, and a key added in the agent.
          e.g. `$ ssh-add` will add the default ssh key from ~/.ssh
        EOS
      end
    end

    def self.user_in_lxd_group?
      if (group = Etc.getgrnam("lxd"))
        group.mem.include?(Etc.getlogin)
      else
        raise(SystemNotReady.new("There seems to be no 'lxd' group. Is LXD installed?"))
      end
    end

    def status
      if @container.exist?
        folders = @container.state['devices'].
                    select{|_,f| f['source']}.
                    map{|name, folders| [name, "#{folders['source']} => #{folders['path']}"]}

        table = Terminal::Table.new do |t|
          t.add_row ['Name', @container.state['name']]
          t.add_row ['Status', @container.state['status']]
          t.add_row ['IP', @container.ip]
          t.add_row ['Image', @container.image]
          t.add_separator
          folders.each do |folder|
            t.add_row folder
          end
          t.add_separator
          @redirs.each do |redir|
            t.add_row ['Forwarded port', "guest: #{redir.guest} host: #{redir.host}"]
          end
          if @container.state['snapshots'].any?
            t.add_separator
            t.add_row ['Snapshots', '']
          end
          @container.state['snapshots'].each do |snapshot|
            t.add_row [snapshot['name'], snapshot['created_at']]
          end
        end
        table.to_s
      else
        'Container does not exist. Run lxdev up to provision container.'
      end
    end

    def up
      @container.create unless @container.exist?
      @container.start
      @container.provision(commands: @config['box']['provisioning']) unless @container.provisioned?
      @redirs.each{|redir| redir.start}

      unless @folders.empty?
        @folders.first.system_setup unless @folders.first.system_setup?
        @folders.each{|folder| folder.link}
      end
      snapshot('provisioned') if @config['box']['auto_snapshots']
    end

    def halt
      @redirs.each{|redir| redir.stop}
      @container.stop
    end

    def destroy
      @redirs.each{|redir| redir.stop}
      @container.destroy
    end

    def ssh(args)
      if @container.running?
        if @container.ip
          exec(format("ssh -o StrictHostKeyChecking=no -t %s@%s %s",
                      @container.user,
                      @container.ip,
                      args.is_a?(Array) ? args.join(" ") : ''))
        else
          raise(SystemNotReady.
                  new("There was no IPv4 address for this box. Is the network configured properly?"))
        end
      else
        raise(SystemNotReady.new("Container is not running"))
      end
    end

    def execute(command, interactive: false)
      cmd = Main.user_in_lxd_group? ? 'lxc' : 'sudo lxc'
      if interactive
        # execution stops here and gives control to exec
        exec("#{cmd} exec #{@container.name} #{command}")
      else
        IO.popen("#{cmd} exec #{@container.name} -- /bin/sh -c '#{command}'", err: [:child, :out]) do |cmd_output|
          cmd_output.each do |line|
            puts line
          end
        end
      end
    end

    def snapshot(snapshot_name)
      puts "Creating snapshot #{snapshot_name}"
      System.exec("lxc snapshot #{@container.name} #{snapshot_name}")
    end

    def restore(snapshot_name)
      puts "Restoring snapshot #{snapshot_name}"
      exitstatus = System.exec("lxc restore #{@container.name} #{snapshot_name}").exitstatus
      exitstatus == 0
    end

    def rmsnapshot(snapshot_name)
      puts "Deleting snapshot #{snapshot_name}"
      exitstatus = System.exec("lxc delete #{@container.name}/#{snapshot_name}").exitstatus
      exitstatus == 0
    end

    def revert
      snapshot      = @container.state['snapshots'].last
      snapshot_name = snapshot['name']
      if restore(snapshot_name)
        puts "Reverted to snapshot #{snapshot_name}"
        puts "Deleting snapshot"
        rmsnapshot(snapshot_name)
      end
    end

    private

    def self.lxd_initialized?
      default = System.exec('lxc profile device ls default').output.split("\n").map(&:chomp)
      ['eth0', 'root'].all?{|i| default.any?{|x| x == i}}
    end

    def self.missing_required_commands
      REQUIRED_COMMANDS.select{|cmd| System.exec("which #{cmd}").exitstatus != 0}
    end
  end
end
