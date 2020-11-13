require 'pod_builder/core'
require 'digest'

module PodBuilder
  module Command
    class UpdateLldbInit
      def self.call
        Configuration.check_inited
        if Configuration.build_using_repo_paths
          raise "\n\nlldb shenanigans not supported when 'build_using_repo_paths' is enabled".red
        end
        
        arguments = ARGV.dup
        
        if arguments.count > 0
          source_path = arguments[0]
          if !is_absolute_path(source_path)
            source_path = PodBuilder::basepath(source_path)
          end
          source_path = File.expand_path(source_path)  
          
          raise "\n\nSpecified path does not exists" unless File.directory?(source_path)
        end
        
        base_path = PodBuilder::basepath
        app_podfile_content = File.read(PodBuilder::project_path("Podfile"))
        
        lldbinit_path = File.expand_path(PodBuilder::basepath(Configuration.lldbinit_name))
        
        puts "Extracting debug information".yellow

        FileUtils.mkdir_p(Configuration.build_path)
        compilation_base_path = Pathname.new(Configuration.build_path).realpath.to_s
                
        pods_mappings = Hash.new

        app_podfile_content.each_line do |line|
          unless (name_match = line.match(/^\s*pod ['|"](.*?)['|"](.*)/)) && name_match.size == 3
            next
          end
          
          pod_name = name_match[1].split("/").first
          
          source = nil
          destination = PodBuilder::basepath # puts some existing path, see lldbinit_content.reverse! comment
          if (path_match = line.match(/:path\s?=>\s?['|"](.*?)['|"]/)) && path_match.size == 2
            pod_path = path_match[1]
            if !is_absolute_path(pod_path)
              pod_path = File.expand_path("#{base_path}/#{pod_path}")              
            end

            is_prebuilt = pod_path.start_with?(PodBuilder::prebuiltpath(pod_name))
            if is_prebuilt
              source = "#{compilation_base_path}/Pods/#{pod_name}"
              destination = PodBuilder::prebuiltpath(pod_name)

              info_path = "#{pod_path}/#{Configuration.prebuilt_info_filename}"
              next unless File.exists?(info_path)
              data = JSON.parse(File.read(info_path))

              build_source_path_matches = data["entry"].match(/:path => '(.*?)'/)
              if build_source_path_matches&.size == 2
                build_source_path = build_source_path_matches[1]
                if !is_absolute_path(build_source_path)
                  build_source_path = PodBuilder::basepath(build_source_path)
                end
                destination = File.expand_path(build_source_path)  
              end
            elsif File.directory?(pod_path)
              source = pod_path
              destination = pod_path
            end
          else
            pod_path = PodBuilder::project_path("Pods/#{pod_name}")
            if File.directory?(pod_path)
              source = pod_path
              destination = pod_path
            end            
          end

          if !source.nil? && File.directory?(destination)
            pods_mappings[source] = destination
          end
        end

        prebuilt_source_map_entries = []
        other_source_map_entries = []
        pods_mappings.each do |source, destination| 
          if source.include?(compilation_base_path)         
            prebuilt_source_map_entries.push("settings append target.source-map '#{source}/' '#{destination}/'")
          else
            other_source_map_entries.push("settings append target.source-map '#{source}/' '#{destination}/'")
          end
        end

        # There is a bug/unexpected behavior related to the target.source-map command
        #
        # If I have debug symbols for the following files:
        # /tmp/pod_builder/Pods/SomeName/... which are now under /new/path/SomeName/
        # /tmp/pod_builder/Pods/SomeNameCommon/... which are now under /new/path/SomeNameCommon/
        #
        # adding a remap as follows
        # settings append '/tmp/pod_builder/Pods/SomeName/' '/new/path/SomeName/'
        #
        # causes breakpoints added to files under /new/path/SomeNameCommon/ to be incorrectly added to
        # /tmp/pod_builder/Pods/SomeName/Common/Somefile
        # 
        # LLDB evaluates remap in order so to workaround this issue we have to add a remap of
        # /tmp/pod_builder/Pods/SomeNameCommon/ before remapping /tmp/pod_builder/Pods/SomeName/
        # even if the remap isn't needed!
        lldbinit_content = other_source_map_entries.sort.reverse + prebuilt_source_map_entries.sort.reverse

        lldbinit_content.insert(0, "settings clear target.source-map\n")

        File.write(lldbinit_path, lldbinit_content.join("\n"))
        
        puts "\n\n🎉 done!\n".green
        return 0
      end
      
      private 
      
      def self.is_absolute_path(path)
        return ["~", "/"].any? { |t| path.start_with?(t) }
      end
    end
  end
end
