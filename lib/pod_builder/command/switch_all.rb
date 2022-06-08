require 'pod_builder/core'

module PodBuilder
  module Command
    class SwitchAll
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath

        ARGV << "*"
        return Command::Switch::call
      end
    end
  end
end