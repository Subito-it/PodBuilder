require 'pod_builder/core'

module PodBuilder
  module Command
    class SynchPodfile
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath
        
        update_repo = options[:update_repos] || false
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, update_repo)

        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        Dir.chdir(PodBuilder::project_path)

        previous_podfile_content = File.read("Podfile")
        Podfile::write_prebuilt(all_buildable_items, analyzer)        
        updated_podfile_content = File.read("Podfile")

        if previous_podfile_content != updated_podfile_content
          system("pod install")
        end
        
        return true
      end
    end
  end
end
  