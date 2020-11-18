require 'lxdev/system'
require 'lxdev/shared_folder'

module LxDev
  class Container
    attr_reader :user, :name, :state, :image

    @@default_boot_timeout = 30

    def initialize(name, image, user)
      @name, @image, @user = name, image, user
      refresh_state
    end

    def create
      System.exec(format('lxc init %s %s', @image, @name))
      System.exec(format('lxc config set %s boot.autostart false', @name))
      refresh_state
    end

    def destroy
      System.exec(format('lxc delete %s', @name)) if exist?
      refresh_state
    end

    def exec(command)
      System.exec(format('lxc exec %s -- %s', @name, command))
    end

    def exist?
      !@state.nil?
    end

    def ip
      @state&.
        dig('state','network','eth0','addresses')&.
        find{|ad| ad['family'] == 'inet'}&.
        fetch('address')
    end

    def provision(commands: [])
      raise("Machine was not started when trying to provision") unless running?
      provision_user

      STDOUT.sync = true
      commands&.each{|cmd| exec(cmd)}
      STDOUT.sync = false
    end

    def provisioned?
      exec(format('id -u %s 2> /dev/null', @user)).exitstatus == 0
    end

    def running?
      status == 'Running'
    end

    def status
      @state&.dig('status')
    end

    def start
      enforce_created
      case
      when running? then return
      when System.exec(format('lxc start %s', @name)).exitstatus == 0
        @@default_boot_timeout.times{|_| refresh_state; if ip then return else sleep 1 end}
        raise(format('Box "%s" timed out waiting for boot', @name))
      else
        raise(format('Box "%s" failed to start', @name))
      end
      refresh_state
    end

    def stop
      enforce_created
      if running? && !System.exec(format('lxc stop %s', @name)).exitstatus == 0
        raise('Box "%s" failed to stop', @name)
      end
      refresh_state
    end


    private
    def refresh_state
      @state = JSON.parse(System.exec(format('lxc ls --format json ^%s$', @name)).output).first
    end

    def enforce_created
      raise(format('Box "%s" has not been created yet', @name)) unless exist?
    end

    def provision_user
      move_user = lambda do |from_uid, to_uid, from_gid, to_gid|
        user = exec(format('id -un -- %d', from_uid))
        group = exec(format('id -gn -- %d', from_gid))

        if user.exitstatus == 0
          exec(format('usermod -u %d %s', to_uid, user.output.chomp))
        end

        if group.exitstatus == 0
          exec(format('groupmod -g %d %s', to_uid, group.output.chomp))
        end

        if user.exitstatus == 0 &&
           user.output.chomp == group.output.chomp
        then
          exec(format('chown -R %{user}:%{user} /home/%{user}', user: user.output.chomp))
        end
      end

      if (pair = SharedFolder.required_uid_gid)
        uid, gid = *pair.map(&:to_i)
        move_user.(uid, 1500, gid, 1500)
        exec(format('groupadd -g %d %s', gid, @user))
        exec(format('useradd  -m -s /bin/bash -g %{user} -u %{uid} %{user}', user: @user, uid: uid))
      else
        exec(format('useradd -m -s /bin/bash -U %s', @user))
      end

      exec(format('mkdir /home/%s/.ssh', @user))
      exec(format("tee /home/%s/.ssh/authorized_keys <<EOS\n%s\nEOS",
                               @user,
                               System.ssh_keys))
      exec(format('touch /home/%s/.hushlogin', @user))
      exec(format('chmod 0700 /home/%s/.ssh', @user))
      exec(format('chown -R %{user}:%{user} /home/%{user}', user: @user))
      exec(format("tee -a /etc/sudoers <<EOS\n%s ALL=(ALL) NOPASSWD: ALL\nEOS", @user))
      exec('chmod 0440 /etc/sudoers')
    end
  end
end
