module LxDev
  class System
    class Result
      attr_accessor :output
      attr_accessor :exitstatus
    end

    def self.exec(cmd)
      return_object            = Result.new
      return_object.output     = %x{#{cmd}}
      return_object.exitstatus = $?.exitstatus
      return_object
    end

    def self.spawn_exec(cmd, silent: false)
      if silent
        spawn(cmd, [:out, :err] => "/dev/null")
      else
        spawn(cmd)
      end
    end
  end
end
