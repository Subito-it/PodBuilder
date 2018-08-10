require 'pod_builder/core'

module PodBuilder
  module Command
    class BuildAll
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath

        ARGV << "*"
        return Command::Build::call(options)
      end
    end
  end
end