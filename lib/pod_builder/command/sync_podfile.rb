require 'pod_builder/core'

module PodBuilder
  module Command
    class SyncPodfile
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath
        
        install_update_repo = OPTIONS.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)

        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        Dir.chdir(PodBuilder::project_path) do
          previous_podfile_content = File.read("Podfile")
          Podfile::write_prebuilt(all_buildable_items, analyzer)        
          updated_podfile_content = File.read("Podfile")
  
          Licenses::write([], all_buildable_items)
  
          if previous_podfile_content != updated_podfile_content
            bundler_prefix = Configuration.use_bundler ? "bundle exec " : ""
            system("#{bundler_prefix}pod install;")
          end  
        end
        
        puts "\n\n🎉 done!\n".green
        return 0
      end
    end
  end
end
  