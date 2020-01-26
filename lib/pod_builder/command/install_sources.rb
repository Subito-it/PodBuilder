require 'pod_builder/core'

module PodBuilder
  module Command
    class InstallSources
      def self.call(options)
        Configuration.check_inited
        PodBuilder::prepare_basepath

        install_update_repo = options.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)
        framework_items = Analyze.podfile_items(installer, analyzer).select { |x| !x.is_prebuilt }
        podspec_names = framework_items.map(&:podspec_name)

        base_path = PodBuilder::basepath("Rome")
        framework_files = Dir.glob("#{base_path}/**/*.framework")
        
        framework_files.each do |path|
          rel_path = Pathname.new(path).relative_path_from(Pathname.new(base_path)).to_s

          if framework_spec = framework_items.detect { |x| x.prebuilt_rel_path == rel_path }
            update_repo(framework_spec)
          end
        end

        Command::Clean::clean_sources()

        ARGV << PodBuilder::basepath("Sources")
        Command::UpdateLldbInit::call(options)

        puts "\n\n🎉 done!\n".green
        return 0
      end

      private

      def self.update_repo(spec)
        dest_path = PodBuilder::basepath("Sources")
        FileUtils.mkdir_p(dest_path)

        current_dir = Dir.pwd
        Dir.chdir(dest_path)

        repo_dir = File.join(dest_path, spec.podspec_name)
        if !File.directory?(repo_dir)
          raise "Failed cloning #{spec.name}" if !system("git clone #{spec.repo} #{spec.podspec_name}")
        end

        Dir.chdir(repo_dir)
        puts "Checking out #{spec.podspec_name}".yellow
        raise "Failed cheking out #{spec.name}" if !system(git_hard_checkout_cmd(spec))

        Dir.chdir(current_dir)
      end

      def self.git_hard_checkout_cmd(spec)
        prefix = "git fetch --all --tags --prune; git reset --hard"
        if @tag
          return "#{prefix} tags/#{spec.tag}"
        end
        if @commit
          return "#{prefix} #{spec.commit}"
        end
        if @branch
          return "#{prefix} origin/#{spec.branch}"
        end
  
        return nil
      end
    end
  end
end
