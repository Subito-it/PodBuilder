require 'pod_builder/core'

module PodBuilder
  module Command
    class GeneratePodspec
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath

        Podspec::generate

        puts "\n\n🎉 done!\n".green
        return true
      end
    end
  end
end
