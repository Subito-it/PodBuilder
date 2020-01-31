require 'pod_builder/core'
require 'digest'

module PodBuilder
  module Command
    class ClearLldbInit
      def self.call(options)
        lldbinit_path = File.expand_path('~/.lldbinit-Xcode')
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

        puts "\n\n🎉 done!\n".green
        return 0
      end
    end
  end
end
