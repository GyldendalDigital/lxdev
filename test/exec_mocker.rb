module ExecMocker
  class << self
    attr_accessor :return_values
    attr_accessor :calls
    attr_accessor :exitstatus
  end

  def system_exec_mock(return_values = {})
    ExecMocker.return_values = return_values
    ExecMocker.calls = []
    ExecMocker.exitstatus = 0

    LxDev::System.instance_eval do
      alias :exec_original :exec
      def exec(cmd)
        ExecMocker.calls << cmd
        if ExecMocker.return_values[cmd].nil?
          raise "Undefined mock cmd: ###{cmd}##"
        else
          return_object            = LxDev::System::Result.new
          return_object.output     = ExecMocker.return_values[cmd][:result]
          return_object.exitstatus = ExecMocker.return_values[cmd][:exitstatus]
          return_object
        end
      end
    end

    # perform tests
    yield

    # cleanup
    LxDev::System.instance_eval do
      alias :exec :exec_original
    end
  end
end
