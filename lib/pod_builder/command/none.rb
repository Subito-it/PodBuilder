require 'pod_builder/core'

module PodBuilder
  module Command
    class None
      def self.call(options)
        unless !options.has_key?(:version)
          puts VERSION
          return true
        end

        return false
      end
    end
  end
end
