require 'pod_builder/core'

module PodBuilder
  module Command
    class Switch
      def self.call(options)
        Configuration.check_inited

        argument_pods = ARGV.dup

        unless argument_pods.count > 0 
          return false
        end
        unless argument_pods.count == 1
          raise "\n\nSpecify a single pod to switch\n\n".red 
          return false
        end

        check_not_building_subspec(argument_pods.first)

        raise "FIXME: TODO"
      end

      private 

      def self.check_not_building_subspec(pod_to_switch)
        if pod_to_switch.include?("/")
          raise "\n\nCan't switch subspec #{pod_to_switch} refer to podspec name.\n\nUse `pod_builder switch #{pod_to_switch.split("/").first}` instead\n\n".red
        end
      end
    end
  end    
end