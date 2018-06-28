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

    def self.spawn_exec(cmd)
      spawn(cmd)
    end

    def self.exit(exitcode = 0)
      Kernel.exit(exitcode)
    end
  end
end
