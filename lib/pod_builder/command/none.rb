require 'pod_builder/core'

module PodBuilder
  module Command
    class None
      def self.call
        unless !OPTIONS.has_key?(:version)
          puts VERSION
          return 0
        end

        return -1
      end
    end
  end
end
