require 'pod_builder/core'
require 'cfpropertylist'

module PodBuilder
  module Command
    class Update
      def self.call(options)          
        Configuration.check_inited
        PodBuilder::prepare_basepath

        if check_in_sync
          puts "Frameworks in sync!\n".green
          return true
        end
        
        install_update_repo = options.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)
        
        all_buildable_items = Analyze.podfile_items(installer, analyzer)
        
        pods_to_rebuild = []
        
        swift_version = PodBuilder::system_swift_version
        Dir.glob(PodBuilder::basepath("Rome/**/*.framework")) do |framework_path|
          framework_name = File.basename(framework_path)
          plist_filename = File.join(framework_path, Configuration.framework_plist_filename)
          unless File.exist?(plist_filename)
            raise "Unable to extract item info for framework #{framework_name}. Please rebuild the framework manually!\n".red
          end
          
          plist = CFPropertyList::List.new(:file => plist_filename)
          data = CFPropertyList.native_types(plist.value)
          
          pod_name = pod_definition_in(data['entry'])
          if podfile_item = all_buildable_items.detect { |x| x.name == pod_name }
            if !all_buildable_items.any? { |x| x.entry.start_with?(data['entry']) } && data['is_prebuilt'] == false
              pods_to_rebuild.push(podfile_item.root_name)
            end
          else
            puts "Skipping #{framework_name}. You may need to clean up your framework folder, run `podbuilder clean`\n".red
          end
        end

        pods_to_rebuild.uniq!
        
        # TODO: call build
        # TODO: add auto dependencies resolution
      end        
      
      private 

      def self.check_in_sync
        podfile_path = PodBuilder::basepath("Podfile.restore")
        podfile_content = File.read(podfile_path)

        pod_entries = []
        podfile_content.each_line do |line|
          if pod_entry = pod_entry_in(line)
            pod_entries.push(pod_entry)
          end
        end

        pod_entries.uniq!

        in_sync = true
        Dir.glob(PodBuilder::basepath("Rome/**/*.framework")) do |framework_path|
          framework_name = File.basename(framework_path)
          plist_filename = File.join(framework_path, Configuration.framework_plist_filename)
          unless File.exist?(plist_filename)
            raise "Unable to extract item info for framework #{framework_name}. Please rebuild the framework manually!\n".red
          end
          
          plist = CFPropertyList::List.new(:file => plist_filename)
          data = CFPropertyList.native_types(plist.value)

          unless data['is_prebuilt'] == false
            next
          end
          unless pod_entries.include?(data['entry'].gsub(" ", ""))
            in_sync = false
          end
        end

        return in_sync
      end

      def self.pod_entry_in(line)
        stripped_line = line.gsub("\"", "'").gsub(" ", "").gsub("\t", "").gsub("\n", "")
        matches = stripped_line.match(/(^pod')(.*?)(')/)
        
        if matches&.size == 4
          return stripped_line.split("#").first
        else
          return nil
        end
      end

      
      def self.pod_definition_in(entry)
        condensed_entry = entry.gsub(" ", "")
        matches = condensed_entry.match(/(^pod')(.*?)(')/)
        
        if matches&.size == 4
          return matches[2]
        else
          return nil
        end
      end
    end
  end
end
