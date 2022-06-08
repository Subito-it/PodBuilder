require 'pod_builder/core'
require 'set'

module PodBuilder
  module Command
    class Switch
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath
        
        argument_pods = ARGV.dup
        switch_all = argument_pods.first == "*"

        if switch_all
          pods = []
          podspecs = Dir.glob("#{PodBuilder::prebuiltpath}/**/*.podspec")
          podspecs.each do |podspec|
            spec = Pod::Specification.from_file(podspec)
            podname = spec.attributes_hash["name"]
            pods.push(podname)
          end
          argument_pods = pods
          if OPTIONS[:switch_mode] == "development"
              argument_pods.reject! { |pod_name| self.find_podspec(pod_name).nil? }
          end
        end

        unless argument_pods.count > 0 
          return -1
        end

        Configuration.pre_actions[:switch]&.execute()

        pods_not_found = []
        pod_names_to_switch = []
        argument_pods.each do |pod|
          pod_name_to_switch = pod
          pod_name_to_switch = Podfile::resolve_pod_names_from_podfile([pod_name_to_switch]).first

          if pod_name_to_switch.nil?
            raise "\n\n'#{pod}' not found in PodBuilder's Podfile.\n\nYou might need to explictly add:\n\n    pod '#{pod}'\n\nto #{PodBuilder::basepath("Podfile")}\n".red
          else
            check_not_building_subspec(pod_name_to_switch)  

            pod_names_to_switch.push(pod_name_to_switch)  
          end          
        end

        if OPTIONS[:resolve_parent_dependencies] == true
          install_update_repo = OPTIONS.fetch(:update_repos, false)
          installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)
  
          all_buildable_items = Analyze.podfile_items(installer, analyzer)

          pod_names_to_switch.each do |pod_name|
            if pod = (all_buildable_items.detect { |t| t.name == pod_name } || all_buildable_items.detect { |t| t.root_name == pod_name })
              dependencies = []
              all_buildable_items.each do |pod|
                if !(pod.dependency_names & pod_names_to_switch).empty?
                  dependencies.push(pod.root_name)
                end
              end
              pod_names_to_switch += dependencies
            end
          end

          pod_names_to_switch.uniq!
        end

        dep_pod_names_to_switch = []
        if OPTIONS[:resolve_child_dependencies] == true
          pod_names_to_switch.each do |pod|
            podspec_path = PodBuilder::prebuiltpath("#{pod}/#{pod}.podspec")
            unless File.exist?(podspec_path)
              next
            end

            podspec_content = File.read(podspec_path)

            regex = "p\\d\\.dependency ['|\"](.*)['|\"]"

            podspec_content.each_line do |line|
              matches = line.match(/#{regex}/)
      
              if matches&.size == 2
                dep_pod_names_to_switch.push(matches[1].split("/").first)
              end
            end
          end

          dep_pod_names_to_switch.uniq!
          dep_pod_names_to_switch.reverse.each do |dep_name|
            podspec_path = PodBuilder::prebuiltpath("#{dep_name}/#{dep_name}.podspec")
            if File.exist?(podspec_path)
              if pod = Podfile::resolve_pod_names_from_podfile([dep_name]).first
                pod_names_to_switch.push(pod)
                next
              end    
            end
            
            dep_pod_names_to_switch.delete(dep_name)
          end
          pod_names_to_switch = pod_names_to_switch.map { |t| t.split("/").first }.uniq
          dep_pod_names_to_switch.reject { |t| pod_names_to_switch.include?(t) } 
        end

        inhibit_warnings = inhibit_warnings_pods()
        
        pod_names_to_switch.each do |pod_name_to_switch|
          development_path = ""
          default_entry = nil

          case OPTIONS[:switch_mode]
          when "development"
            development_path = find_podspec(pod_name_to_switch)              
          when "prebuilt"
            podfile_path = PodBuilder::basepath("Podfile.restore")
            content = File.read(podfile_path)
            if !content.include?("pod '#{pod_name_to_switch}")
              raise "\n\n'#{pod_name_to_switch}' does not seem to be prebuit!".red
            end
          when "default"
            podfile_path = PodBuilder::basepath("Podfile")
            content = File.read(podfile_path)
              
            content.each_line do |line|    
              if (matches = line.match(/^\s*pod ['|"](.*?)['|"](.*)/)) && matches.size == 3
                if matches[1].split("/").first == pod_name_to_switch
                  default_entry = line
                end  
              end
            end
    
            raise "\n\n'#{pod_name_to_switch}' not found in PodBuilder's Podfile.\n\nYou might need to explictly add:\n\n    pod '#{pod_name_to_switch}'\n\nto #{podfile_path}\n".red if default_entry.nil?
          end

          if development_path.nil? 
            if dep_pod_names_to_switch.include?(pod_name_to_switch)
              next
            else
              raise "\n\nCouln't find `#{pod_name_to_switch}` sources in the following specified development pod paths:\n#{Configuration.development_pods_paths.join("\n")}\n".red
            end
          end

          podfile_path = PodBuilder::project_path("Podfile")
          content = File.read(podfile_path)
          
          lines = []
          content.each_line do |line|
            if (matches = line.match(/^\s*pod ['|"](.*?)['|"](.*)/)) && matches.size == 3
              if matches[1].split("/").first == pod_name_to_switch
                case OPTIONS[:switch_mode]
                when "prebuilt"
                  indentation = line.split("pod '").first
                  podspec_path = File.dirname(PodBuilder::prebuiltpath("#{pod_name_to_switch}/#{pod_name_to_switch}.podspec"))
                  rel_path = Pathname.new(podspec_path).relative_path_from(Pathname.new(PodBuilder::project_path)).to_s
                  prebuilt_line = "#{indentation}pod '#{matches[1]}', :path => '#{rel_path}'\n"
                  if line.include?("# pb<") && marker = line.split("# pb<").last
                    prebuilt_line = prebuilt_line.chomp("\n") + " # pb<#{marker}"
                  end
                  lines.append(prebuilt_line)
                  next
                when "development"
                  indentation = line.split("pod '").first
                  rel_path = Pathname.new(development_path).relative_path_from(Pathname.new(PodBuilder::project_path)).to_s
                  development_line = "#{indentation}pod '#{matches[1]}', :path => '#{rel_path}'\n"
                  if inhibit_warnings.include?(matches[1])
                    development_line = development_line.chomp("\n") + ", :inhibit_warnings => true\n"
                  end
                  if line.include?("# pb<") && marker = line.split("# pb<").last
                    development_line = development_line.chomp("\n") + " # pb<#{marker}"
                  end

                  lines.append(development_line)
                  next
                when "default"
                  if default_line = default_entry
                    # default_line is already extracted from PodBuilder's Podfile and already includes :inhibit_warnings 
                    if line.include?("# pb<") && marker = line.split("# pb<").last
                      default_line = default_line.chomp("\n") + " # pb<#{marker}"
                    end
                    if (path_match = default_line.match(/:path => '(.*?)'/)) && path_match&.size == 2
                      original_path = path_match[1]
                      if !is_absolute_path(original_path)
                        updated_path = Pathname.new(PodBuilder::basepath(original_path)).relative_path_from(Pathname.new(PodBuilder::project_path)).to_s
                        default_line.gsub!(":path => '#{original_path}'", ":path => '#{updated_path}'")
                      end
                    end

                    lines.append(default_line)
                    next
                  end
                else
                  raise "\n\nUnsupported mode '#{OPTIONS[:switch_mode]}'".red
                end
              end  
            end

            lines.append(line)
          end

          File.write(podfile_path, lines.join)
        end
        
        Dir.chdir(PodBuilder::project_path) do
          bundler_prefix = Configuration.use_bundler ? "bundle exec " : ""
          system("#{bundler_prefix}pod install;")  
        end

        Configuration.post_actions[:switch]&.execute()

        puts "\n\n🎉 done!\n".green

        return 0
      end
      
      private 

      def self.inhibit_warnings_pods
        ret = Set.new

        podfile_path = PodBuilder::basepath("Podfile")
        content = File.read(podfile_path)

        content.each_line do |line|
          unless (name_match = line.match(/^\s*pod ['|"](.*?)['|"](.*)/)) && name_match.size == 3
            next
          end

          if line.gsub(" ", "").include?(":inhibit_warnings=>true")
            pod_name = name_match[1]
            ret.add?(pod_name)
          end
        end

        return ret
      end
      
      def self.is_absolute_path(path)
        return ["~", "/"].any? { |t| path.start_with?(t) }
      end  

      def self.find_podspec(podname)
        unless Configuration.development_pods_paths.count > 0
          raise "\n\nPlease add the development pods path(s) in #{Configuration.dev_pods_configuration_filename} as per documentation\n".red
        end

        podspec_path = nil
        Configuration.development_pods_paths.each do |path|
          if Pathname.new(path).relative?
            path = PodBuilder::basepath(path)
          end
          podspec_paths = Dir.glob(File.expand_path("#{path}/**/#{podname}*.podspec*"))
          podspec_paths.select! { |t| !t.include?("/Local Podspecs/") }
          podspec_paths.select! { |t| Dir.glob(File.join(File.dirname(t), "*")).count > 1 } # exclude podspec folder (which has one file per folder)
          if podspec_paths.count > 1
            if match_name_path = podspec_paths.find{ |t| File.basename(t, ".*") == podname }
              podspec_path = Pathname.new(match_name_path).dirname.to_s
            else
              # Try parsing podspec
              podspec_paths.each do |path|
                content = File.read(path).gsub("\"", "'").gsub(" ", "")
                if content.include?("name='#{podname}'")
                  podspec_path = path                  
                end
                unless podspec_path.nil?
                  break
                end
              end  
            end

            break
          elsif podspec_paths.count == 1
            podspec_path = Pathname.new(podspec_paths.first).dirname.to_s
            break
          end
        end

        return podspec_path
      end
            
      def self.check_not_building_subspec(pod_to_switch)
        if pod_to_switch.include?("/")
          raise "\n\nCan't switch subspec #{pod_to_switch} refer to podspec name.\n\nUse `pod_builder switch #{pod_to_switch.split("/").first}` instead\n".red
        end
      end
    end
  end    
end