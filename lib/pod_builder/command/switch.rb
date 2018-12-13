require 'pod_builder/core'

module PodBuilder
  module Command
    class Switch
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath
        
        argument_pods = ARGV.dup
        
        unless argument_pods.count > 0 
          return -1
        end
        unless argument_pods.count == 1
          raise "\n\nSpecify a single pod to switch\n\n".red 
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
            return 0
          end
        end

        if options[:switch_mode] == "prebuilt"
          check_prebuilded(pod_name_to_switch)
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

            matches = line.match(/(#\s*pb<)(.*?)(>)/)
            if matches&.size == 4
              default_pod_name = matches[2]
            else
              puts "⚠️ Did not found pb<> entry, assigning default pod name #{pod_name}"
              default_pod_name = pod_name
            end

            unless podfile_item = all_buildable_items.detect { |x| x.name == default_pod_name }
              raise "\n\nPod `#{default_pod_name}` wasn't found in Podfile\n".red
            end
            podfile_item = podfile_item.dup

            indentation = line.detect_indentation

            case options[:switch_mode]
            when "prebuilt"
              line = indentation + podfile_item.prebuilt_entry + "\n"
            when "development"
              podfile_item.path = find_podspec(podfile_item)
              podfile_item.is_external = true

              line = indentation + podfile_item.entry + "\n"
            when "default"
              line = indentation + podfile_item.entry + "\n"
            else
              break
            end
          end

          pod_lines.push(line)
        end
        
        File.write(podfile_path, pod_lines.join)
        
        Dir.chdir(PodBuilder::project_path)
        system("pod install")

        return 0
      end
      
      private     

      def self.find_podspec(podfile_item)
        unless Configuration.development_pods_paths.count > 0
          raise "\n\nPlease add the development pods path(s) in #{Configuration.dev_pods_configuration_filename} as per documentation\n".red
        end

        podspec_path = nil
        Configuration.development_pods_paths.each do |path|
          podspec = Dir.glob(File.expand_path("#{path}/**/#{podfile_item.root_name}*.podspec*"))
          podspec.select! { |x| !x.include?("/Local Podspecs/") }
          podspec.select! { |x| Dir.glob(File.join(File.dirname(x), "*")).count > 1 } # exclude podspec folder (which has one file per folder)
          if podspec.count > 0
            podspec_path = Pathname.new(podspec.first).dirname.to_s
            break
          end
        end

        if podspec_path.nil?
          raise "\n\nCouln't find `#{podfile_item.root_name}` sources in the following specified development pod paths: #{Configuration.development_pods_paths.join("\n")}\n".red
        end

        return podspec_path
      end
      
      def self.request_switch_mode(pod_name, podfile_item)
        matches = podfile_item.entry.match(/(pod '.*?',)(.*)('.*')/)
        unless matches&.size == 4
          raise "\n\nFailed matching pod name\n".red
        end

        default_entry = matches[3].strip

        modes = ["prebuilt", "development", "default"]
        mode_indx = ask("\n\nSwitch #{pod_name} to:\n1) Prebuilt\n2) Development pod\n3) Default (#{default_entry})\n\n") { |x| x.limit = 1, x.validate = /[1-3]/ }
        
        return modes[mode_indx.to_i - 1]
      end
      
      def self.check_not_building_subspec(pod_to_switch)
        if pod_to_switch.include?("/")
          raise "\n\nCan't switch subspec #{pod_to_switch} refer to podspec name.\n\nUse `pod_builder switch #{pod_to_switch.split("/").first}` instead\n\n".red
        end
      end

      private

      def self.check_prebuilded(pod_name)
        if !Podspec.include?(pod_name)
          raise "\n\n#{pod_name} is not prebuilt.\n\nRun 'pod_builder build #{pod_name}'\n".red
        end
      end
    end
  end    
end