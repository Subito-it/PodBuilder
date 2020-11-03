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
        podfile_hash = Digest::MD5.hexdigest(app_podfile_content)

        lldbinit_path = File.expand_path(PodBuilder::basepath(Configuration.lldbinit_name))
        lldbinit_content = File.exist?(lldbinit_path) ? File.read(lldbinit_path) : ""

        if lldbinit_content.include?("# <pb_md5:#{base_path}:#{podfile_hash}")
          puts "\n\n🎉 already in sync!\n".green
          return 0
        end

        puts "Extracting debug information".yellow

        unless source_path.nil?
          podspec_paths = Dir.glob("#{source_path}/**/*.podspec") + Dir.glob("#{source_path}/**/*.podspec.json")
          podspec_contents = podspec_paths.map { |t| File.read(t).gsub(/\s+/, "").gsub("\"", "'") }
        end

        source_map_lines = []
        Dir.glob("#{PodBuilder::prebuiltpath}/**/#{Configuration.prebuilt_info_filename}").each do |path|
          data = JSON.parse(File.read(path))
          next if data.fetch("is_prebuilt", true)

          # It would be much nicer if PodBuilder.json already contained this info in a custom key
          pod_name_matches = data["entry"].match(/pod '(.*?)'/)
          next unless pod_name_matches&.size == 2
          
          podspec_name = pod_name_matches[1]
          podspec_path = "#{File.dirname(path)}/#{podspec_name}.podspec"
          
          next unless File.exist?(podspec_path)

          build_source_path_matches = data["entry"].match(/:path => '(.*?)'/)
          if build_source_path_matches&.size == 2
            build_source_path = build_source_path_matches[1]
            
            if !is_absolute_path(build_source_path[0])
              build_source_path = PodBuilder::basepath(build_source_path)
            end
            build_source_path = File.expand_path(build_source_path)  
          elsif source_path.nil?
            next
          else
            # Find source code for podspec_name
            podspec_path = find_podspec_path_for(podspec_name, podspec_paths, podspec_contents)
            next if podspec_path.nil?
          end
          
          original_compile_path = data["original_compile_path"] + "/Pods/#{podspec_name}"
          if is_prebuilt_pod(podspec_path, app_podfile_content)
            unless source_map_lines.include?("settings append target.source-map '#{original_compile_path}'")
              source_map_lines.push("# <pb:#{base_path}>\n", "settings append target.source-map '#{original_compile_path}' '#{build_source_path}'\n")
            end
          end
        end

        rewrite_lldinit(lldbinit_path, source_map_lines, base_path, podfile_hash)
        
        puts "\n\n🎉 done!\n".green
        return 0
      end

      private 

      def self.is_absolute_path(path)
        return ["~", "/"].any? { |t| t.start_with?(t) }
      end

      def self.is_prebuilt_pod(podspec_path, app_podfile_content)
        development_path = Pathname.new(podspec_path).relative_path_from(Pathname.new(PodBuilder::project_path)).parent.to_s

        return app_podfile_content.include?(":path => '#{development_path}'")
      end

      def self.rewrite_lldinit(lldbinit_path, source_map_lines, base_path, podfile_hash)
        puts "Writing #{lldbinit_path}".yellow

        FileUtils.touch(lldbinit_path)
        raise "\n\nDestination file should be a file".red unless File.exist?(lldbinit_path)

        lldbinit_lines = []
        skipNext = false
        File.read(lldbinit_path).each_line do |line|
          if line.include?("# <pb:#{base_path}>") || line.include?("# <pb>")
            skipNext = true
            next
          elsif skipNext
            skipNext = false
            next
          elsif line != "\n"
            if line.include?("settings set target.source-map")
              raise "\n\n#{lldbinit_destination_path} already includes a manual `settings set target.source-map`. This is unsupported and you'll have to manually remove that entry\n".red
            end
            lldbinit_lines.push(line)
          end
        end

        source_map_lines.insert(0, "# <pb>\n")
        source_map_lines.insert(1, "settings clear target.source-map\n")
        source_map_lines.insert(2, "# <pb:#{base_path}>\n")
        source_map_lines.insert(3, "# <pb_md5:#{base_path}:#{podfile_hash}>\n")

        lldbinit_lines += source_map_lines
      
        File.write(lldbinit_path, lldbinit_lines.join())
      end

      def self.find_podspec_path_for(name, podspec_paths, podspec_contents)
        if (path = podspec_paths.detect { |t| File.basename(t, ".podspec") == name.gsub("_", "-") })
          return path
        elsif (path_index = podspec_contents.find_index { |t| t.include?(".module_name='#{name}'") })
          return podspec_paths[path_index]
        elsif (path_index = podspec_contents.find_index { |t| t.include?(".name='#{name}") }) # kind of optimistic,, but a last resort
          return podspec_paths[path_index]
        elsif (path_index = podspec_contents.find_index { |t| t.include?("'module_name':'#{name}'") }) # [json podspec]
          return podspec_paths[path_index]
        elsif (path_index = podspec_contents.find_index { |t| t.include?("'name':'#{name}") }) # [json podspec] kind of optimistic,, but a last resort
          return podspec_paths[path_index]
        else
          return nil
        end
      end
    end
  end
end
