require 'pod_builder/core'

module PodBuilder
  module Command
    class BuildAll
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath

        ARGV << "*"
        return Command::Build::call
      end
    end
  end
end