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
        # This is an euristic and quick way to check if the framework is in sync
        # In the call method will do 
        podfile_path = PodBuilder::basepath("Podfile.restore")
        podfile_content = File.read(podfile_path)
        
        pod_entries = []
        podfile_content.each_line do |line|
          if pod_entry = pod_entry_in(line)
            if line.match(/(pb<)(.*?)(>)/) # is not prebuilt
              pod_entries.push(pod_entry)
            end
          end
        end
        
        pod_entries.uniq!
        
        Dir.glob(PodBuilder::basepath("Rome/**/*.framework")) do |framework_path|
          framework_name = File.basename(framework_path)
          plist_filename = File.join(framework_path, Configuration.framework_plist_filename)
          unless File.exist?(plist_filename)
            raise "Unable to extract item info for framework #{framework_name}. Please rebuild the framework manually!\n".red
          end
          
          plist = CFPropertyList::List.new(:file => plist_filename)
          data = CFPropertyList.native_types(plist.value)

          matches = data['entry'].gsub(" ", "").match(/(^pod')(.*?)(')(.*)/)
          raise "Unexpected error\n".red if matches&.size != 5          
          delete_regex = matches[1] + matches[2].split("/").first + "(/.*)?" + matches[3]

          if data['is_prebuilt'] == false
            delete_regex += matches[4] 
          end

          pod_entries.select! { |x| x.match(delete_regex) == nil }
        end
        
        return pod_entries.count == 0
      end
      
      def self.pod_entry_in(line)
        stripped_line = line.gsub("\"", "'").gsub(" ", "").gsub("\t", "").gsub("\n", "")
        matches = stripped_line.match(/(^pod')(.*?)(')(.*)/)
        
        if matches&.size == 5
          entry = matches[1] + matches[2].split("/").first + matches[3] + matches[4]
          return entry.split("#pb<").first
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
