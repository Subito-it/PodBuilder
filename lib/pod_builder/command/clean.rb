require 'pod_builder/core'
require 'highline/import'

module PodBuilder
  module Command
    class Clean
      def self.call
        Configuration.check_inited
        PodBuilder::prepare_basepath

        install_update_repo = OPTIONS.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)
        all_buildable_items = Analyze.podfile_items(installer, analyzer)

        prebuilt_items(all_buildable_items)
        install_sources(all_buildable_items)

        puts "\n\n🎉 done!\n".green
        return 0
      end
      
      def self.prebuilt_items(buildable_items)
        puts "Cleaning prebuilt folder".yellow

        root_names = buildable_items.map(&:root_name).uniq
        Dir.glob(PodBuilder::prebuiltpath("*")).each do |path|
          basename = File.basename(path)
          unless root_names.include?(basename) 
            puts "Cleanining up `#{basename}`, no longer found among dependencies".blue
            PodBuilder::safe_rm_rf(path)
          end
        end

        puts "Cleaning dSYM folder".yellow
        module_names = buildable_items.map(&:module_name).uniq
        Dir.glob(File.join(PodBuilder::dsympath, "**/*.dSYM")).each do |path|
          dsym_basename = File.basename(path, ".*")
          dsym_basename.gsub!(/\.framework$/, "")
          unless module_names.include?(dsym_basename)
            puts "Cleanining up `#{dsym_basename}`, no longer found among dependencies".blue
            PodBuilder::safe_rm_rf(path)
          end
        end

      end

      def self.install_sources(buildable_items)        
        puts "Looking for unused sources".yellow

        podspec_names = buildable_items.map(&:root_name).uniq

        base_path = PodBuilder::basepath("Sources")

        paths_to_delete = []
        repo_paths = Dir.glob("#{base_path}/*")
        repo_paths.each do |path|
          podspec_name = File.basename(path)

          if podspec_names.include?(podspec_name)
            next
          end

          paths_to_delete.push(path)
        end

        paths_to_delete.flatten.each do |path|
          if OPTIONS.has_key?(:no_stdin_available)
            PodBuilder::safe_rm_rf(path)
            next
          end
          confirm = ask("#{path} unused.\nDelete it? [Y/N] ") { |yn| yn.limit = 1, yn.validate = /[yn]/i }
          if confirm.downcase == 'y' || OPTIONS.has_key?(:no_stdin_available)
            PodBuilder::safe_rm_rf(path)
          end
        end
      end
    end
  end
end
