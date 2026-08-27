require "pod_builder/core"
require "json"

module PodBuilder
  module Actions
    def self.load(hash, step)
      actions = {}
      if json = hash["switch"]
        actions[:switch] = Item.new("switch", step, json)
      end
      if json = hash["install"]
        actions[:install] = Item.new("install", step, json)
      end
      if json = hash["build"]
        actions[:build] = Item.new("build", step, json)
      end

      return actions
    end

    class Item
      attr_reader :path
      attr_reader :quiet
      attr_reader :name

      def initialize(name, step, hash)
        @name = name
        @step = step
        @path = hash.fetch("path", "")
        @quiet = hash.fetch("quiet", false)

        raise "\n\nEmpty or missing #{step} #{name} action path\n".red if @path.empty?()
      end

      def execute(env = {})
        cmd = PodBuilder::basepath(path)
        unless File.exist?(cmd)
          raise "\n\n#{@step.capitalize} #{@name} action path '#{cmd}' does not exists!\n".red
        end

        if @quiet
          cmd += " > /dev/null 2>&1"
        end

        puts "Executing #{@step} #{@name} action".yellow

        previous_env = {}
        env.each do |key, value|
          previous_env[key] = ENV[key]
          ENV[key] = value.to_s
        end

        `#{cmd}`
      ensure
        previous_env&.each do |key, value|
          if value.nil?
            ENV.delete(key)
          else
            ENV[key] = value
          end
        end
      end
    end
  end
end
