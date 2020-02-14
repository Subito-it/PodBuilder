require 'pod_builder/core'
require 'digest'

module PodBuilder
  module Command
    class ClearLldbInit
      def self.call(options)

        argument_pods = ARGV.dup
        
        unless argument_pods.count > 0 
          return -1
        end
        unless argument_pods.count == 1
          raise "\n\nExpecting LLDBINIT_PATH\n\n".red 
        end
            
        lldbinit_path = File.expand_path(argument_pods[0])
        lldbinit_content = File.exists?(lldbinit_path) ? File.read(lldbinit_path) : ""

        lldbinit_lines = []
        skipNext = false
        File.read(lldbinit_path).each_line do |line|
          if line.include?("# <pb")
            skipNext = true
            next
          elsif skipNext
            skipNext = false
            next
          elsif line != "\n"
            lldbinit_lines.push(line)
          end
        end
      
        File.write(lldbinit_path, lldbinit_lines.join())

        if options.nil? == false
          puts "\n\n🎉 done!\n".green
        end
        return 0
      end
    end
  end
end
