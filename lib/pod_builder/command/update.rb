require 'pod_builder/core'

module PodBuilder
  module Command
    class Update
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath

        info = PodBuilder::Info.generate_info()

        swift_version = PodBuilder::system_swift_version

        pods_to_update = []
        info.each do |pod_name, info|
          if info.dig(:restore_info, :version) != info.dig(:prebuilt_info, :version)
            pods_to_update.append(pod_name)
          end
          if (prebuilt_swift_version = info.dig(:prebuilt_info, :swift_version)) && prebuilt_swift_version != swift_version
            pods_to_update.append(pod_name)
          end
        end

        pods_to_update.map! { |x| x.split("/").first }.uniq!
        
        unless pods_to_update.count > 0
          puts "Prebuilt items in sync!\n".green
          return 0
        end
        if OPTIONS.has_key?(:dry_run)
          puts "`#{pods_to_update.join("`, `")}` need to be rebuilt!\n".red
          return -2
        end

        ARGV.clear
        pods_to_update.each { |x| ARGV << x }

        return PodBuilder::Command::Build.call
      end              
    end
  end
end
