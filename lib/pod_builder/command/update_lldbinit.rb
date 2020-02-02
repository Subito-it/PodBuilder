require 'pod_builder/core'
require 'digest'

module PodBuilder
  module Command
    class UpdateLldbInit
      def self.call(options)
        Configuration.check_inited
        
        argument_pods = ARGV.dup
        
        unless argument_pods.count > 0 
          return -1
        end
        unless argument_pods.count == 1
          raise "\n\nSpecify a single PATH to the folder containing the prebuilt framework's source code\n\n".red 
        end
            
        base_path = PodBuilder::basepath("")

        podfile_restore_content = File.read(PodBuilder::basepath("Podfile.restore"))
        app_podfile_content = File.read(PodBuilder::project_path("Podfile"))

        lldbinit_path = File.expand_path('~/.lldbinit-Xcode')
        lldbinit_content = File.exists?(lldbinit_path) ? File.read(lldbinit_path) : ""
        status_hash = podfiles_status_hash(app_podfile_content, podfile_restore_content)
        if lldbinit_content.include?("# <pb_md5:#{base_path}:#{status_hash}")
          puts "\n\n🎉 already in sync!\n".green
          return 0
        end

        source_path = argument_pods[0]
        
        is_absolute = ["~", "/"].include?(source_path[0])
        if !is_absolute
          source_path = Pathname.new(File.join(base_path, source_path))
        end
        
        source_path = File.expand_path(source_path)
        
        framework_paths = Dir.glob("#{base_path}/**/*.framework")
        
        unless framework_paths.count > 0
          raise "\n\nNo prebuilt frameworks found in `#{framework_paths}`\n\n".red 
        end

        puts "Extracting debug information".yellow

        podspec_paths = Dir.glob("#{source_path}/**/*.podspec") + Dir.glob("#{source_path}/**/*.podspec.json")
        podspec_contents = podspec_paths.map { |t| File.read(t).gsub(/\s+/, "").gsub("\"", "'") }
        
        replace_paths = []
        
        framework_paths.each do |framework_path|
          name = File.basename(framework_path, File.extname(framework_path)) 
          executable_path = File.join(framework_path, name)

          podbuilder_plist = File.join(framework_path, Configuration.framework_plist_filename)

          plist = CFPropertyList::List.new(:file => podbuilder_plist)
          data = CFPropertyList.native_types(plist.value)

          original_compile_path = data["original_compile_path"]
          is_prebuilt = data.fetch("is_prebuilt", true)

          if original_compile_path.nil?
            puts "\n\n#{framework_path} was compiled with an older version of PodBuilder, please rebuild it to update `~/.lldbinit-Xcode`"
            next
          end
          
          if is_prebuilt
            next
          end

          if podspec_path = find_podspec_path_for(name, podspec_paths, podspec_contents)
            if !is_development_pod(podspec_path, app_podfile_content)
              replace_paths.push("#{original_compile_path}/Pods/#{name},#{File.dirname(podspec_path)}")
            else
              puts "#{name} is in development pod, skipping"
            end
          else
            puts "Failed to find podspec for #{name}, skipping".blue
          end   
        end
        
        replace_paths.uniq!

        source_map_lines = replace_paths.flat_map { |t| ["# <pb:#{base_path}>\n", "settings append target.source-map '#{t.split(",").first}' '#{t.split(",").last}'\n"] }
        rewrite_lldinit(source_map_lines, base_path, app_podfile_content, podfile_restore_content)
        
        puts "\n\n🎉 done!\n".green
        return 0
      end

      def self.is_development_pod(podspec_path, app_podfile_content)
        development_path = Pathname.new(podspec_path).relative_path_from(Pathname.new(PodBuilder::project_path)).parent.to_s

        return app_podfile_content.include?(":path => '#{development_path}'")
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

      def self.podfiles_status_hash(app_podfile_content, podfile_restore_content)
        # Change to either Podfile.restore (which presumely mean new prebuilds done)
        # or app's Podfile (which my occurr when pods are switched to development pod)
        # should force a regeneration of the status identifier
        Digest::MD5.hexdigest(podfile_restore_content + app_podfile_content)
      end

      def self.rewrite_lldinit(source_map_lines, base_path, app_podfile_content, podfile_restore_content)
        puts "Writing ~/.lldbinit-Xcode".yellow

        lldbinit_path = File.expand_path('~/.lldbinit-Xcode')
        FileUtils.touch(lldbinit_path)

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
              raise "\n\n~/.lldbinit-Xcode already includes a manual `settings set target.source-map`. This is unsupported and you'll have to manually remove that entry\n"
            end
            lldbinit_lines.push(line)
          end
        end

        status_hash = podfiles_status_hash(app_podfile_content, podfile_restore_content)

        source_map_lines.insert(0, "# <pb>\n")
        source_map_lines.insert(1, "settings clear target.source-map\n")
        source_map_lines.insert(2, "# <pb:#{base_path}>\n")
        source_map_lines.insert(3, "# <pb_md5:#{base_path}:#{status_hash}>\n")

        lldbinit_lines += source_map_lines
      
        File.write(lldbinit_path, lldbinit_lines.join())
      end
    end
  end
end
