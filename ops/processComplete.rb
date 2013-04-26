# Setups report handler for ruby that 
# indicates the process has completed successfully
# usage:
# ChefReport::ProcessComplete.new
require 'rubygems'
require 'socket'

module ChefReport
   class ProcessComplete < Chef::Handler

      def initialize
        # noop
      end

      def report
        if run_status.success?
          host = Socket.gethostname
          system("printf \"#{host}\tchefSuccess\t0\tOK\n\" | /usr/sbin/send_nsca -c /etc/send_nsca.cfg -H monitor-s3 >/dev/null 2>&1")
        end
      end

   end
end
