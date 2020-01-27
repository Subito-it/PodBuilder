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

        lldbinit_path = File.expand_path('~/.lldbinit-Xcode')
        lldbinit_content = File.exists?(lldbinit_path) ? File.read(lldbinit_path) : ""
        restore_hash = podfile_restore_hash()
        if lldbinit_content.include?("<pb_md5:#{base_path}:#{restore_hash}")
          puts "\n\n🎉 already in sync!\n".green
          return 0
        end

        path = argument_pods[0]
        
        is_absolute = ["~", "/"].include?(path[0])
        if !is_absolute
          path = Pathname.new(File.join(base_path, path))
        end
        
        path = File.expand_path(path)
        
        framework_paths = Dir.glob("#{base_path}/**/*.framework")
        
        unless framework_paths.count > 0
          raise "\n\nNo prebuilt frameworks found in `#{path}`\n\n".red 
        end

        puts "Extracting debug information".yellow

        podspec_paths = Dir.glob("#{path}/**/*.podspec") + Dir.glob("#{path}/**/*.podspec.json")
        podspec_contents = podspec_paths.map { |t| File.read(t).gsub(/\s+/, "").gsub("\"", "'") }
        
        replace_paths = []
        
        framework_paths.each do |framework_path|
          name = File.basename(framework_path, File.extname(framework_path)) 
          executable_path = File.join(framework_path, name)
          
          dwarf_dump_lib = `dwarfdump --debug-info #{executable_path} | grep '#{Configuration.build_base_path}' | head -n 1`.strip()          
          
          if (matches = dwarf_dump_lib.match(/#{Configuration.build_base_path}(.*)\/Pods/)) && matches.size == 2
            original_compile_path = "#{Configuration.build_base_path}#{matches[1]}/Pods/#{name}"
            
            if podspec_path = find_podspec_path_for(name, podspec_paths, podspec_contents)
              replace_paths.push("#{original_compile_path},#{File.dirname(podspec_path)}")
            else
              puts "Failed to find podspec for #{name}".blue
            end 
          else
            # Look for path in dSYM
            dsym_paths = Dir.glob("#{base_path}/**/iphonesimulator/#{name}.framework.dSYM")
            dsym_paths.each do |dsym_path|
              name = File.basename(dsym_path, ".framework.dSYM") 
              dsym_dwarf_path = File.join(dsym_path, "Contents/Resources/DWARF")
              dsym_dwarf_path = File.join(dsym_dwarf_path, name)
              
              dwarf_dump_lib = `dwarfdump --debug-info #{dsym_dwarf_path} | grep '#{Configuration.build_base_path}' | head -n 1`.strip()
              
              if (matches = dwarf_dump_lib.match(/#{Configuration.build_base_path}(.*)\/Pods/)) && matches.size == 2
                original_compile_path = "#{Configuration.build_base_path}#{matches[1]}/Pods/#{name}"

                if podspec_path = find_podspec_path_for(name, podspec_paths, podspec_contents)
                  replace_paths.push("#{original_compile_path},#{File.dirname(podspec_path)}")
                else
                  puts "Failed to find podspec for #{name}".blue
                end                
              end
            end    
          end
        end
        
        replace_paths.uniq!

        source_map_lines = replace_paths.flat_map { |t| ["# <pb:#{base_path}>", "settings append target.source-map '#{t.split(",").first}' '#{t.split(",").last}'"] }
        rewrite_lldinit(source_map_lines, base_path)
        
        puts "\n\n🎉 done!\n".green
        return 0
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

      def self.podfile_restore_hash()
        Digest::MD5.hexdigest(File.read(PodBuilder::basepath("Podfile.restore")))
      end

      def self.rewrite_lldinit(source_map_lines, base_path)
        puts "Writing ~/.lldbinit-Xcode".yellow

        lldbinit_path = File.expand_path('~/.lldbinit-Xcode')
        FileUtils.touch(lldbinit_path)

        lldbinit_lines = []
        skipNext = false
        File.read(lldbinit_path).each_line do |line|
          if line.include?("# <pb:#{base_path}>")
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

        restore_hash = podfile_restore_hash()
        source_map_lines.insert(0, "<pb_md5:#{base_path}:#{restore_hash}>")
        source_map_lines.insert(0, "<pb:#{base_path}>")

        lldbinit_lines += source_map_lines
      
        File.write(lldbinit_path, lldbinit_lines.join("\n"))
      end
    end
  end
end
