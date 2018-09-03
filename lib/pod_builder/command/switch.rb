require 'pod_builder/core'

module PodBuilder
  module Command
    class Switch
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath
        
        argument_pods = ARGV.dup
        
        unless argument_pods.count > 0 
          return false
        end
        unless argument_pods.count == 1
          raise "\n\nSpecify a single pod to switch\n\n".red 
          return false
        end
        
        pod_name_to_switch = argument_pods.first
        
        check_not_building_subspec(pod_name_to_switch)

        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, false)
        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        raise "\n\nPod `#{pod_name_to_switch}` wasn't found in Podfile" unless all_buildable_items.map(&:root_name).include?(pod_name_to_switch)
        
        unless options.has_key?(:switch_mode)
          podfile_item = all_buildable_items.detect { |x| x.root_name == pod_name_to_switch }
          options[:switch_mode] = request_switch_mode(pod_name_to_switch, podfile_item)

          if options[:switch_mode].nil?
            return true
          end
        end

        podfile_path = PodBuilder::project_path("Podfile")
        podfile_content = File.read(podfile_path)

        pod_lines = []
        podfile_content.each_line do |line|
          if pod_name = Podfile.pod_definition_in(line, false)
            if pod_name.start_with?("PodBuilder/")
              pod_name = pod_name.split("PodBuilder/").last.gsub("_", "/")
            end

            unless pod_name.split("/").first == pod_name_to_switch
              pod_lines.push(line)
              next
            end

            if pod_name.include?("/")
              podfile_items = all_buildable_items.select { |x| x.name == pod_name }
            else
              podfile_items = all_buildable_items.select { |x| x.root_name == pod_name }
            end

            unless podfile_items.count > 0
              raise "\n\nPod `#{pod_name_to_switch}` wasn't found in Podfile\n".red
            end

            indentation = line.detect_indentation

            case options[:switch_mode]
            when "prebuilt"
              line = podfile_items.map { |x| "#{indentation}#{x.prebuilt_entry}" }.join("\n") + "\n"
            when "development"
              unless Configuration.development_pods_paths.count > 0
                raise "\n\nPlease add the `development_pods_paths` in #{Configuration.dev_pods_configuration_filename} as per documentation\n".red
              end

              podspec_path = nil
              Configuration.development_pods_paths.each do |path|
                podspec = Dir.glob("#{path}/**/#{podfile_item.root_name}*.podspec*")
                if podspec.count > 0
                  podspec_path = Pathname.new(podspec.first).basename.to_s
                end
              end

              if podspec_path.nil?
                raise "\n\nCouln't find `#{pod_name}` sources in the following specified development pod paths:#{Configuration.development_pods_paths.join("\n")}\n".red
              end

              line = podfile_items.map { |x| "#{indentation}pod '#{x.name}', :path => '#{podspec_path}'\n" }.join("\n") + "\n"
            when "default"
              line = podfile_items.map { |x| "#{indentation}#{x.entry}" }.join("\n") + "\n"
            else
              break
            end
          end

          pod_lines.push(line)
        end
        
        File.write(podfile_path, pod_lines.join)
        
        Dir.chdir(PodBuilder::project_path)
        system("pod install")
      end
      
      private
      
      def self.request_switch_mode(pod_name, podfile_item)
        matches = podfile_item.entry.match(/(pod '.*?',)(.*)/)
        unless matches&.size == 3 
          raise "\n\nFailed matching pod name\n".red
        end

        default_entry = matches[2].strip

        modes = ["prebuilt", "development", "default"]
        mode_indx = ask("\n\nSwitch #{pod_name} to:\n1) Prebuilt\n2) Development pod\n3) Default (#{default_entry})\n\n") { |x| x.limit = 1, x.validate = /[1-3]/ }
        
        return modes[mode_indx.to_i - 1]
      end
      
      def self.check_not_building_subspec(pod_to_switch)
        if pod_to_switch.include?("/")
          raise "\n\nCan't switch subspec #{pod_to_switch} refer to podspec name.\n\nUse `pod_builder switch #{pod_to_switch.split("/").first}` instead\n\n".red
        end
      end
    end
  end    
end