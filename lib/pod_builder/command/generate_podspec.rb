require 'pod_builder/core'

module PodBuilder
  module Command
    class GeneratePodspec
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath

        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, false)

        Podspec::generate(analyzer)

        puts "\n\n🎉 done!\n".green
        return 0
      end
    end
  end
end
