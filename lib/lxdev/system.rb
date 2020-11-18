module LxDev
  class System
    @@use_sudo = false

    class Result
      attr_accessor :output
      attr_accessor :exitstatus
    end

    def self.use_sudo=(val)
      @@use_sudo = !!val
    end

    def self.use_sudo
      @@use_sudo
    end

    def self.cond_add_sudo(cmd)
      @@use_sudo ? format('sudo %s', cmd) : cmd
    end

    def self.exec(cmd)
      return_object            = Result.new
      return_object.output     = %x{#{self.cond_add_sudo(cmd)}}
      return_object.exitstatus = $?.exitstatus
      return_object
    end

    def self.spawn_exec(cmd, silent: false)
      cmd = System.cond_add_sudo(cmd)
      if silent
        spawn(cmd, [:out, :err] => "/dev/null")
      else
        spawn(cmd)
      end
    end

    def self.ssh_keys
      ssh_keys = System.exec("ssh-add -L").output
      ssh_keys[0..3] == 'ssh-' ? ssh_keys : nil
    end

    def self.lxd_service_name
      case
      when System.exec("systemctl status lxd.service").exitstatus == 0
        'lxd.service'
      when System.exec("systemctl status snap.lxd.daemon.service").exitstatus == 0
        'snap.lxd.daemon.service'
      else
        raise('There seems to be no LXD service on the system!')
      end
    end
  end
end
