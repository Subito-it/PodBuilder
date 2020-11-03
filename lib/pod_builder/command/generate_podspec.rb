require 'pod_builder/core'

module PodBuilder
  module Command
    class GeneratePodspec
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath

        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, false)
        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        install_using_frameworks = Podfile::install_using_frameworks(analyzer)

        Podspec::generate(all_buildable_items, analyzer, install_using_frameworks)

        puts "\n\n🎉 done!\n".green
        return 0
      end
    end
  end
end
