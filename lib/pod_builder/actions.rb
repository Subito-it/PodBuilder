require 'pod_builder/core'
require 'json'

module PodBuilder
  module Actions
    def self.load(hash)
      actions = {}
      if json = hash["switch"]
        actions[:switch] = Item.new("switch", json)
      end
      if json = hash["install"]
        actions[:install] = Item.new("install", json)
      end
      if json = hash["build"]
        actions[:build] = Item.new("build", json)
      end
      
      return actions
    end

    class Item
      attr_reader :path
      attr_reader :quiet
      attr_reader :name
            
      def initialize(name, hash)
        @name = name
        @path = hash.fetch("path", "") 
        @quiet = hash.fetch("quiet", false) 

        raise "\n\nEmpty or missing post #{name} action path\n".red if @path.empty?()
      end     
      
      def execute()
        cmd = PodBuilder::basepath(path)
        unless File.exist?(cmd)
          raise "\n\nPost #{name} action path '#{cmd}' does not exists!\n".red
        end

        if @quiet
          cmd += " > /dev/null 2>&1"
        end

        puts "Executing post #{name} action".yellow
        `#{cmd}`
      end
    end
  end  
end
