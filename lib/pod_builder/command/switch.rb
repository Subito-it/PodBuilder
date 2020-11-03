require 'pod_builder/core'

module PodBuilder
  module Command
    class Switch
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath
        
        argument_pods = ARGV.dup
        
        unless argument_pods.count > 0 
          return -1
        end

        pod_names_to_switch = []
        argument_pods.each do |pod|
          pod_name_to_switch = pod
          pod_name_to_switch = Podfile::resolve_pod_names_from_podfile([pod_name_to_switch]).first
          raise "\n\nDid not find pod '#{pod}'".red if pod_name_to_switch.nil?
          
          check_not_building_subspec(pod_name_to_switch)  

          pod_names_to_switch.push(pod_name_to_switch)
        end

        if OPTIONS[:resolve_parent_dependencies] == true
          install_update_repo = OPTIONS.fetch(:update_repos, true)
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

            regex = "p\\d\\.dependency '(.*)'"

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
        
        pod_names_to_switch.each do |pod_name_to_switch|
          development_path = ""
          default_entries = Hash.new

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
              
            current_section = ""
            content.each_line do |line|
              stripped_line = line.strip
              if stripped_line.start_with?("def ") || stripped_line.start_with?("target ")
                current_section = line.split(" ")[1]
                next
              end
    
              matches = line.gsub("\"", "'").match(/pod '(.*?)',(.*)/)
              if matches&.size == 3
                if matches[1].split("/").first == pod_name_to_switch
                  default_entries[current_section] = line
                end  
              end
            end
    
            raise "\n\n'#{pod_name_to_switch}' not found in #{podfile_path}".red if default_entries.keys.count == 0
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
          current_section = ""
          content.each_line do |line|
            stripped_line = line.strip
            if stripped_line.start_with?("def ") || stripped_line.start_with?("target ")
              current_section = line.split(" ")[1]
            end

            matches = line.gsub("\"", "'").match(/pod '(.*?)',(.*)/)
            if matches&.size == 3
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
                  if line.include?("# pb<") && marker = line.split("# pb<").last
                    development_line = development_line.chomp("\n") + " # pb<#{marker}"
                  end

                  lines.append(development_line)
                  next
                when "default"
                  if default_line = default_entries[current_section]
                    if line.include?("# pb<") && marker = line.split("# pb<").last
                      default_line = default_line.chomp("\n") + " # pb<#{marker}"
                    end
                    lines.append(default_line)
                    next
                  elsif
                    raise "\n\nLine for pod '#{matches[1]}' in section '#{current_section}' not found in PodBuilder's Podfile".red
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
        
        Dir.chdir(PodBuilder::project_path)
        bundler_prefix = Configuration.use_bundler ? "bundle exec " : ""
        system("#{bundler_prefix}pod install;")

        return 0
      end
      
      private     

      def self.find_podspec(podname)
        unless Configuration.development_pods_paths.count > 0
          raise "\n\nPlease add the development pods path(s) in #{Configuration.dev_pods_configuration_filename} as per documentation\n".red
        end

        podspec_path = nil
        Configuration.development_pods_paths.each do |path|
          if Pathname.new(path).relative?
            path = PodBuilder::basepath(path)
          end
          podspec = Dir.glob(File.expand_path("#{path}/**/#{podname}*.podspec*"))
          podspec.select! { |x| !x.include?("/Local Podspecs/") }
          podspec.select! { |x| Dir.glob(File.join(File.dirname(x), "*")).count > 1 } # exclude podspec folder (which has one file per folder)
          if podspec.count > 0
            podspec_path = Pathname.new(podspec.first).dirname.to_s
            break
          end
        end

        return podspec_path
      end
            
      def self.check_not_building_subspec(pod_to_switch)
        if pod_to_switch.include?("/")
          raise "\n\nCan't switch subspec #{pod_to_switch} refer to podspec name.\n\nUse `pod_builder switch #{pod_to_switch.split("/").first}` instead\n\n".red
        end
      end
    end
  end    
end