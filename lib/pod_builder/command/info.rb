require 'pod_builder/core'
require 'json'

module PodBuilder
  module Command
    class Info
      def self.call          
        Configuration.check_inited

        info = PodBuilder::Info.generate_info()
        
        puts JSON.pretty_generate(info)
        
        return true
      end      
    end
  end  
end
